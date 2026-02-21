import Cocoa
import Foundation

/// Unix Domain Socket server that accepts relay connections from duplicate processes.
///
/// When Chrome launches a new Intentional process for Native Messaging and an instance
/// is already running, the new process connects to this socket and relays Chrome's
/// stdin/stdout through it. This server accepts those connections and creates a
/// NativeMessagingHost for each one, allowing the existing app to handle messages
/// from multiple browser extension connections simultaneously.
class SocketRelayServer {

    weak var appDelegate: AppDelegate?

    private var serverFd: Int32 = -1
    private var isListening = false
    private let acceptQueue = DispatchQueue(label: "com.intentional.socket.accept", qos: .userInitiated)

    // Active connections: fd -> NativeMessagingHost
    private var activeConnections: [Int32: NativeMessagingHost] = [:]
    private let connectionsLock = NSLock()
    private var connectionCounter = 0

    /// Number of currently active extension connections
    var connectionCount: Int {
        connectionsLock.lock()
        let count = activeConnections.count
        connectionsLock.unlock()
        return count
    }

    /// Get bundle IDs of browsers that currently have active socket connections.
    /// Used by BrowserMonitor to treat connected browsers as protected — a live socket
    /// connection is definitive proof the extension is installed and running.
    func getConnectedBrowserBundleIds() -> Set<String> {
        connectionsLock.lock()
        let ids = Set(activeConnections.values.compactMap { $0.detectedBrowserBundleId })
        connectionsLock.unlock()
        return ids
    }

    let socketPath: String

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        let uid = getuid()
        self.socketPath = NSTemporaryDirectory() + "intentional-native-messaging-\(uid).sock"
    }

    /// Start the socket server. Returns true on success.
    func start() -> Bool {
        cleanupStaleSocket()

        // Create Unix Domain Socket
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            appDelegate?.postLog("Socket server: Failed to create socket: \(String(cString: strerror(errno)))")
            return false
        }

        // Bind to socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for i in 0..<min(pathBytes.count, rawBuf.count - 1) {
                rawBuf[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            appDelegate?.postLog("Socket server: Failed to bind: \(String(cString: strerror(errno)))")
            Darwin.close(serverFd)
            serverFd = -1
            return false
        }

        // Listen with backlog of 5
        guard listen(serverFd, 5) == 0 else {
            appDelegate?.postLog("Socket server: Failed to listen: \(String(cString: strerror(errno)))")
            Darwin.close(serverFd)
            serverFd = -1
            return false
        }

        isListening = true
        appDelegate?.postLog("🔌 Socket relay server listening on \(socketPath)")

        // Accept connections in background
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }

        return true
    }

    /// Stop the server and close all connections
    func stop() {
        isListening = false

        // Close server socket (unblocks accept())
        if serverFd >= 0 {
            Darwin.close(serverFd)
            serverFd = -1
        }

        // Stop all active connection handlers
        connectionsLock.lock()
        for (_, handler) in activeConnections {
            handler.stop()
        }
        activeConnections.removeAll()
        connectionsLock.unlock()

        // Remove socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        appDelegate?.postLog("🔌 Socket relay server stopped")
    }

    /// Send a message to all active connections
    func broadcastToAll(_ message: [String: Any]) {
        connectionsLock.lock()
        let handlers = Array(activeConnections.values)
        connectionsLock.unlock()

        for handler in handlers {
            handler.sendMessage(message)
        }
    }

    /// Broadcast SESSION_SYNC to all connected browsers.
    /// Called when session state changes in TimeTracker (via onSessionChanged callback).
    func broadcastSessionSync() {
        guard let tracker = appDelegate?.timeTracker else { return }
        let message = tracker.getSessionSyncPayload()
        broadcastToAll(message)

        appDelegate?.postLog("🌐 SESSION_SYNC broadcast to \(activeConnections.count) connection(s)")
    }

    /// Broadcast SCHEDULE_SYNC to all connected browsers.
    /// Called when schedule state changes in ScheduleManager (via onBlockChanged callback).
    func broadcastScheduleSync() {
        guard let manager = appDelegate?.scheduleManager else { return }
        let message = manager.getScheduleSyncPayload()
        broadcastToAll(message)

        appDelegate?.postLog("📋 SCHEDULE_SYNC broadcast to \(activeConnections.count) connection(s)")
    }

    /// Broadcast SHOW_FOCUS_OVERLAY to all connected browsers.
    /// The extension's background.js forwards this to the active tab only.
    func broadcastFocusOverlay(intention: String, reason: String, enforcement: String, isRevisit: Bool, focusDurationMinutes: Int) {
        let message: [String: Any] = [
            "type": "SHOW_FOCUS_OVERLAY",
            "intention": intention,
            "reason": reason,
            "enforcement": enforcement,
            "isRevisit": isRevisit,
            "focusDurationMinutes": focusDurationMinutes
        ]
        broadcastToAll(message)
        appDelegate?.postLog("🌑 SHOW_FOCUS_OVERLAY broadcast to \(activeConnections.count) connection(s)")
    }

    /// Broadcast HIDE_FOCUS_OVERLAY to all connected browsers.
    func broadcastHideFocusOverlay() {
        broadcastToAll(["type": "HIDE_FOCUS_OVERLAY"])
    }

    private func acceptLoop() {
        while isListening {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFd, sockPtr, &clientAddrLen)
                }
            }

            guard clientFd >= 0 else {
                if isListening {
                    appDelegate?.postLog("Socket server: Accept error: \(String(cString: strerror(errno)))")
                }
                break
            }

            connectionCounter += 1
            let connLabel = "relay-\(connectionCounter)"

            // Detect browser BEFORE dispatching to main queue (sysctl is safe off-main)
            let detectedBrowserInfo = self.detectBrowser(forSocketFd: clientFd)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    Darwin.close(clientFd)
                    return
                }

                let browserLabel = detectedBrowserInfo?.name ?? "unknown browser"
                self.appDelegate?.postLog("🔌 Socket relay: New connection (\(connLabel), fd: \(clientFd), browser: \(browserLabel))")

                // Create a NativeMessagingHost for this socket connection
                let handler = NativeMessagingHost(appDelegate: self.appDelegate, label: connLabel)
                handler.timeTracker = self.appDelegate?.timeTracker
                handler.scheduleManager = self.appDelegate?.scheduleManager
                handler.relevanceScorer = self.appDelegate?.relevanceScorer
                handler.detectedBrowser = detectedBrowserInfo?.name
                handler.detectedBrowserBundleId = detectedBrowserInfo?.bundleId

                // Register handler BEFORE rechecking protection, so that
                // getConnectedBrowserBundleIds() includes this new connection
                self.connectionsLock.lock()
                self.activeConnections[clientFd] = handler
                self.connectionsLock.unlock()

                handler.startWithFileDescriptor(clientFd)

                // Now recheck protection status — this browser will be treated as
                // protected because it has an active socket connection
                NativeMessagingSetup.shared.autoDiscoverExtensions()
                self.appDelegate?.browserMonitor?.recheckBrowserProtection()

                // Monitor for disconnection in background
                DispatchQueue.global(qos: .utility).async { [weak self, weak handler] in
                    // Wait until handler stops running (readLoop exits on disconnect)
                    while handler?.isActive == true {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                    self?.connectionsLock.lock()
                    self?.activeConnections.removeValue(forKey: clientFd)
                    self?.connectionsLock.unlock()
                    DispatchQueue.main.async {
                        self?.appDelegate?.postLog("🔌 Socket relay: Disconnected (\(connLabel))")
                        // Refresh file-based extension status (may detect disable_reasons change)
                        NativeMessagingSetup.shared.autoDiscoverExtensions()
                        // Recheck protection
                        self?.appDelegate?.browserMonitor?.recheckBrowserProtection()

                        // Schedule a delayed rescan to catch disk-write delays.
                        // When an extension is disabled, Chrome may not flush
                        // disable_reasons to Preferences immediately. This second
                        // rescan catches that within ~5 seconds instead of waiting
                        // for the 60-second periodic rescan.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                            NativeMessagingSetup.shared.autoDiscoverExtensions()
                            self?.appDelegate?.browserMonitor?.recheckBrowserProtection()
                        }
                    }
                }
            }
        }
    }

    /// Detect which browser spawned the relay process connected on this socket fd.
    ///
    /// Process tree: Browser → relay process → socket connection
    /// We use LOCAL_PEERPID to get the relay PID, then sysctl to get its parent PID (the browser),
    /// then NSRunningApplication to get the human-readable app name and bundle ID.
    private func detectBrowser(forSocketFd fd: Int32) -> (name: String, bundleId: String?)? {
        // Step 1: Get the PID of the relay process on the other end of the socket
        var peerPid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        // LOCAL_PEERPID = 0x002 on macOS
        guard getsockopt(fd, SOL_LOCAL, 0x002, &peerPid, &pidSize) == 0, peerPid > 0 else {
            appDelegate?.postLog("Socket relay: Could not get peer PID: \(String(cString: strerror(errno)))")
            return nil
        }

        // Step 2: Get the parent PID of the relay process using sysctl
        let parentPid = getParentPid(of: peerPid)
        guard parentPid > 0 else {
            appDelegate?.postLog("Socket relay: Could not get parent PID of relay \(peerPid)")
            return nil
        }

        // Step 3: Look up the app name via NSRunningApplication
        if let app = NSRunningApplication(processIdentifier: parentPid) {
            let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(parentPid)"
            appDelegate?.postLog("🔍 Browser detected: \(name) (relay PID: \(peerPid), browser PID: \(parentPid))")
            return (name: name, bundleId: app.bundleIdentifier)
        }

        // Fallback: walk further up the tree (some browsers have helper processes in between)
        let grandparentPid = getParentPid(of: parentPid)
        if grandparentPid > 0, let app = NSRunningApplication(processIdentifier: grandparentPid) {
            let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(grandparentPid)"
            appDelegate?.postLog("🔍 Browser detected (grandparent): \(name) (relay PID: \(peerPid), parent: \(parentPid), browser PID: \(grandparentPid))")
            return (name: name, bundleId: app.bundleIdentifier)
        }

        appDelegate?.postLog("Socket relay: Could not identify browser for relay PID \(peerPid) (parent: \(parentPid))")
        return nil
    }

    /// Get the parent PID of a process using sysctl
    private func getParentPid(of pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return 0 }

        return info.kp_eproc.e_ppid
    }

    private func cleanupStaleSocket() {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        // Try connecting to see if another server is listening
        let testFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard testFd >= 0 else {
            try? FileManager.default.removeItem(atPath: socketPath)
            return
        }
        defer { Darwin.close(testFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            for i in 0..<min(pathBytes.count, rawBuf.count - 1) {
                rawBuf[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(testFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult != 0 {
            // No one listening, safe to remove stale socket
            try? FileManager.default.removeItem(atPath: socketPath)
            appDelegate?.postLog("Socket server: Removed stale socket file")
        }
    }

    deinit {
        stop()
    }
}
