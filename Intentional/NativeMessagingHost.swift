import Foundation

/// Handles Native Messaging protocol for Chrome/Firefox extension communication
/// Protocol: 4-byte little-endian length prefix + JSON message
///
/// Supports two modes:
/// 1. stdin/stdout mode: Direct connection from Chrome (original)
/// 2. Socket mode: Connection relayed through Unix Domain Socket from a relay process
class NativeMessagingHost {

    weak var appDelegate: AppDelegate?
    weak var timeTracker: TimeTracker?

    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var socketFd: Int32 = -1  // Track socket fd for cleanup
    private(set) var isRunning = false

    /// Whether this handler is actively processing messages
    var isActive: Bool { isRunning }
    private let messageQueue: DispatchQueue
    private let connectionLabel: String  // For logging
    private let writeLock = NSLock()  // Protects outputHandle writes (length + body must be atomic)

    /// OS-detected browser name (set by SocketRelayServer via process tree lookup).
    /// When set, overrides the extension's self-reported browser name in heartbeat logs.
    var detectedBrowser: String?

    /// OS-detected browser bundle ID (set by SocketRelayServer via process tree lookup).
    /// Used by BrowserMonitor to treat browsers with active socket connections as protected.
    var detectedBrowserBundleId: String?

    init(appDelegate: AppDelegate?, label: String = "stdin") {
        self.appDelegate = appDelegate
        self.connectionLabel = label
        self.messageQueue = DispatchQueue(label: "com.intentional.nativemessaging.\(label)", qos: .userInitiated)
    }

    /// Start listening for messages via stdin/stdout (original mode)
    func start() {
        guard !isRunning else {
            appDelegate?.postLog("⚠️ Native Messaging host (\(connectionLabel)) already running")
            return
        }
        isRunning = true

        inputHandle = FileHandle.standardInput
        outputHandle = FileHandle.standardOutput

        messageQueue.async { [weak self] in
            self?.readLoop()
        }

        let stdinIsPipe = isatty(STDIN_FILENO) == 0
        appDelegate?.postLog("🔌 Native Messaging host started via stdin (pipe: \(stdinIsPipe))")
    }

    /// Start listening for messages via a socket file descriptor (relay mode)
    func startWithFileDescriptor(_ fd: Int32) {
        guard !isRunning else {
            appDelegate?.postLog("⚠️ Native Messaging host (\(connectionLabel)) already running")
            return
        }
        isRunning = true
        socketFd = fd

        inputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        outputHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)

        messageQueue.async { [weak self] in
            self?.readLoop()
        }

        appDelegate?.postLog("🔌 Native Messaging host started via socket (fd: \(fd), label: \(connectionLabel))")
    }

    /// Stop the messaging host safely
    /// Uses shutdown() on sockets to unblock any in-progress readData() call
    /// without triggering an NSException (which close() on an active FileHandle would cause)
    func stop() {
        guard isRunning else { return }
        isRunning = false

        if socketFd >= 0 {
            // shutdown() unblocks any blocked readData() by causing it to return 0 bytes (EOF)
            // This is safe — unlike close(), it doesn't invalidate the fd while FileHandle is using it
            Darwin.shutdown(socketFd, SHUT_RDWR)
        }

        // Schedule cleanup on messageQueue — runs after readLoop exits (same serial queue)
        messageQueue.async { [weak self] in
            self?.cleanup()
        }
    }

    /// Clean up file handles and socket fd after readLoop exits
    private func cleanup() {
        writeLock.lock()
        inputHandle = nil
        outputHandle = nil
        writeLock.unlock()

        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }
    }

    /// Main read loop - reads messages until EOF or stop
    /// readData() blocks when the connection is alive and idle (no CPU used).
    /// readData() returns 0 bytes on EOF (connection closed) — this is the exit signal.
    private func readLoop() {
        while isRunning {
            guard let message = readMessage() else {
                // readData returned 0 bytes = EOF (peer disconnected)
                // This is NOT a transient condition — EOF is permanent
                break
            }

            handleMessage(message)
        }

        isRunning = false
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.appDelegate?.postLog("🔌 Native Messaging (\(self.connectionLabel)): Connection closed")
        }
        cleanup()
    }

    /// Read a single message from stdin using Native Messaging protocol
    private func readMessage() -> [String: Any]? {
        guard let inputHandle = inputHandle else { return nil }

        // Read 4-byte length prefix (little-endian)
        let lengthData = inputHandle.readData(ofLength: 4)
        guard lengthData.count == 4 else { return nil }

        let length = lengthData.withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).littleEndian
        }

        // Sanity check - messages shouldn't be huge
        guard length > 0 && length < 1_000_000 else { return nil }

        // Read the JSON message
        let jsonData = inputHandle.readData(ofLength: Int(length))
        guard jsonData.count == Int(length) else { return nil }

        // Parse JSON
        do {
            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                return json
            }
        } catch {
            appDelegate?.postLog("❌ Native Messaging: Failed to parse JSON: \(error)")
        }

        return nil
    }

    /// Send a message to the extension via the output handle (stdout or socket)
    /// Thread-safe: uses writeLock to ensure length prefix + body are written atomically
    ///
    /// Uses raw Darwin.write() instead of FileHandle.write() because FileHandle
    /// throws an uncatchable ObjC NSException when the fd is a closed pipe.
    /// Darwin.write() returns -1 (EPIPE) which we handle gracefully.
    func sendMessage(_ message: [String: Any]) {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard let outputHandle = outputHandle else { return }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: message)

            // Write 4-byte length prefix (little-endian) + body atomically
            var length = UInt32(jsonData.count).littleEndian
            let lengthData = Data(bytes: &length, count: 4)

            let fd = outputHandle.fileDescriptor
            let lengthWritten = lengthData.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!, ptr.count)
            }
            guard lengthWritten == 4 else {
                // Broken pipe (Chrome closed connection) — stop this host
                DispatchQueue.main.async { [weak self] in
                    self?.appDelegate?.postLog("⚠️ Native Messaging (\(self?.connectionLabel ?? "?")):  Write failed — pipe closed")
                }
                isRunning = false
                return
            }

            let dataWritten = jsonData.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!, ptr.count)
            }
            if dataWritten != jsonData.count {
                DispatchQueue.main.async { [weak self] in
                    self?.appDelegate?.postLog("⚠️ Native Messaging (\(self?.connectionLabel ?? "?")):  Write failed — pipe closed")
                }
                isRunning = false
            }

        } catch {
            appDelegate?.postLog("❌ Native Messaging (\(connectionLabel)): Failed to serialize: \(error)")
        }
    }

    /// Handle incoming message from extension
    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else {
            appDelegate?.postLog("⚠️ Native Messaging: Message missing type")
            return
        }

        switch type {
        case "PING":
            // Simple ping/pong for connection testing
            sendMessage(["type": "PONG", "timestamp": Date().timeIntervalSince1970])
            // Send current state immediately so extension has authoritative numbers on connect
            sendStateSync()
            sendSessionSync()
            // Push onboarding settings so fresh extensions skip onboarding
            sendOnboardingSync()

        case "SESSION_START":
            // Extension starting a session — sets canonical PlatformSession
            handleSessionStart(message)

        case "SESSION_END":
            // Extension ending a session — clears canonical PlatformSession
            handleSessionEnd(message)

        case "SESSION_UPDATE":
            // Extension updating session timer (e.g. extend duration)
            handleSessionUpdate(message)

        case "GET_STATUS":
            // Extension requesting current status
            sendStatus()

        case "USAGE_HEARTBEAT":
            // Extension reporting active usage (tab visible OR audio playing)
            handleUsageHeartbeat(message)

        case "GET_USAGE":
            // Extension querying current usage (for cross-browser sync)
            sendUsageResponse()

        default:
            appDelegate?.postLog("⚠️ Native Messaging: Unknown message type: \(type)")
        }
    }

    /// Handle session start from extension.
    /// Creates both a per-browser BrowserSession (for time tracking) and
    /// a canonical PlatformSession (for cross-browser sync).
    /// First-writer-wins: if a session is already active, sends SESSION_SYNC with existing session.
    private func handleSessionStart(_ message: [String: Any]) {
        guard let platform = message["platform"] as? String,
              let reportedBrowser = message["browser"] as? String else { return }

        let browser = detectedBrowser ?? reportedBrowser
        let intent = message["intent"] as? String
        let categories = message["categories"] as? [String]
        let durationMinutes = message["durationMinutes"] as? Int ?? 0
        let startedAt = message["startedAt"] as? Double ?? (Date().timeIntervalSince1970 * 1000)

        // Calculate endsAt from duration (0 = unlimited)
        let endsAt: Double? = durationMinutes > 0
            ? startedAt + Double(durationMinutes * 60 * 1000)
            : nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Start per-browser session (time tracking)
            self.timeTracker?.startSession(platform: platform, browser: browser, intent: intent)

            // Set canonical platform session (cross-browser sync)
            // setPlatformSession returns false if session already active (first-writer-wins)
            let session = TimeTracker.PlatformSession(
                active: true,
                intent: intent,
                categories: categories,
                startedAt: startedAt,
                endsAt: endsAt,
                durationMinutes: durationMinutes
            )
            let wasSet = self.timeTracker?.setPlatformSession(for: platform, session: session) ?? false

            if !wasSet {
                // Session already active — send SESSION_SYNC with existing state so browser corrects itself
                self.appDelegate?.postLog("🔒 \(platform) session already active, sending correction to \(browser)")
                self.sendSessionSync()
            }
            // If wasSet == true, onSessionChanged fires → SocketRelayServer broadcasts to ALL
        }
    }

    /// Handle session end from extension.
    /// Clears both the per-browser BrowserSession and the canonical PlatformSession.
    /// clearPlatformSession triggers onSessionChanged → broadcasts SESSION_SYNC(inactive) to all browsers.
    private func handleSessionEnd(_ message: [String: Any]) {
        guard let platform = message["platform"] as? String,
              let reportedBrowser = message["browser"] as? String else { return }

        let browser = detectedBrowser ?? reportedBrowser

        DispatchQueue.main.async { [weak self] in
            self?.timeTracker?.endSession(platform: platform, browser: browser)
            self?.timeTracker?.clearPlatformSession(for: platform)
            self?.appDelegate?.postLog("🛑 Session ended: \(platform) on \(browser)")
        }
    }

    /// Handle session update from extension (e.g. extend timer)
    private func handleSessionUpdate(_ message: [String: Any]) {
        guard let platform = message["platform"] as? String else { return }

        let endsAt = message["endsAt"] as? Double
        let durationMinutes = message["durationMinutes"] as? Int

        DispatchQueue.main.async { [weak self] in
            self?.timeTracker?.updatePlatformSession(
                for: platform,
                endsAt: endsAt,
                durationMinutes: durationMinutes
            )
        }
    }

    /// Send current status to extension
    private func sendStatus() {
        guard let tracker = timeTracker else { return }

        sendMessage([
            "type": "STATUS",
            "youtube": [
                "minutesUsed": tracker.getMinutesUsed(for: "youtube"),
                "budgetMinutes": tracker.getBudget(for: "youtube"),
                "isExceeded": tracker.isBudgetExceeded(for: "youtube")
            ],
            "instagram": [
                "minutesUsed": tracker.getMinutesUsed(for: "instagram"),
                "budgetMinutes": tracker.getBudget(for: "instagram"),
                "isExceeded": tracker.isBudgetExceeded(for: "instagram")
            ],
            "timestamp": Date().timeIntervalSince1970
        ])
    }

    /// Handle usage heartbeat from extension (new cross-browser tracking)
    private func handleUsageHeartbeat(_ message: [String: Any]) {
        guard let platform = message["platform"] as? String,
              let seconds = message["seconds"] as? Int else {
            appDelegate?.postLog("⚠️ Native Messaging: Invalid USAGE_HEARTBEAT message")
            return
        }

        let reportedBrowser = message["browser"] as? String ?? "Unknown"
        let browser = detectedBrowser ?? reportedBrowser
        let timestamp = message["timestamp"] as? Double ?? Date().timeIntervalSince1970

        // Forward to TimeTracker (use OS-detected browser name if available)
        DispatchQueue.main.async { [weak self] in
            self?.timeTracker?.recordUsageHeartbeat(
                platform: platform,
                browser: browser,
                seconds: seconds,
                timestamp: timestamp
            )

            // Check if budget exceeded and notify extension
            if let tracker = self?.timeTracker, tracker.isBudgetExceeded(for: platform) {
                self?.sendMessage([
                    "type": "BUDGET_EXCEEDED",
                    "platform": platform,
                    "minutesUsed": tracker.getMinutesUsed(for: platform),
                    "budgetMinutes": tracker.getBudget(for: platform)
                ])
            }

            // Push authoritative state back to this browser's extension
            self?.sendStateSync()
        }
    }

    /// Send current usage data to extension (for cross-browser sync)
    private func sendUsageResponse() {
        guard let tracker = timeTracker else {
            // No tracker available - send empty response
            sendMessage([
                "type": "USAGE_RESPONSE",
                "usage": [
                    "date": nil,
                    "minutesUsed": 0
                ]
            ])
            return
        }

        // Get aggregated usage across all platforms
        let youtubeMins = tracker.getMinutesUsed(for: "youtube")
        let instagramMins = tracker.getMinutesUsed(for: "instagram")
        let totalMins = youtubeMins + instagramMins

        // Get current date for tracking
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        sendMessage([
            "type": "USAGE_RESPONSE",
            "usage": [
                "date": today,
                "minutesUsed": totalMins,
                "youtube": youtubeMins,
                "instagram": instagramMins
            ]
        ])

        appDelegate?.postLog("📊 Sent usage response: \(totalMins) min total")
    }

    /// Push canonical session state to this browser's extension via SESSION_SYNC.
    /// Called on PING (initial connect) so the extension picks up any active session.
    private func sendSessionSync() {
        guard let tracker = timeTracker else { return }
        sendMessage(tracker.getSessionSyncPayload())
    }

    /// Push saved onboarding settings so fresh extensions skip onboarding.
    /// Reads from ~/Library/Application Support/Intentional/onboarding_settings.json
    private func sendOnboardingSync() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let settingsURL = appSupport.appendingPathComponent("Intentional/onboarding_settings.json")

        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              settings["completedAt"] != nil else {
            // No onboarding data saved yet — nothing to push
            return
        }

        let platforms = settings["platforms"] as? [String: Any] ?? [:]
        let ytSettings = platforms["youtube"] as? [String: Any] ?? [:]
        let igSettings = platforms["instagram"] as? [String: Any] ?? [:]
        let fbSettings = platforms["facebook"] as? [String: Any] ?? [:]

        let message: [String: Any] = [
            "type": "ONBOARDING_SYNC",
            "platforms": platforms,
            "dailyBudgetMinutes": ytSettings["budget"] as? Int ?? 30,
            "maxPerPeriod": ytSettings["maxPerPeriod"] ?? [
                "enabled": false,
                "minutes": 20,
                "periodHours": 1
            ],
            "blockedCategories": ytSettings["blockedCategories"] ?? [],
            "partnerEmail": settings["partnerEmail"] ?? NSNull(),
            "partnerName": settings["partnerName"] ?? NSNull(),
            "lockMode": settings["lockMode"] ?? "none",
            "settingsLocked": (settings["lockMode"] as? String ?? "none") != "none",
            "youtube": [
                "onboardingComplete": true,
                "enabled": ytSettings["enabled"] ?? true,
                "blockShorts": ytSettings["blockShorts"] ?? true,
                "blockMode": ytSettings["blockMode"] ?? "hide"
            ],
            "instagram": [
                "onboardingComplete": true,
                "enabled": igSettings["enabled"] ?? true,
                "blockReels": igSettings["blockReels"] ?? true,
                "blockExplore": igSettings["blockExplore"] ?? true,
                "nsfwFilter": igSettings["nsfwFilter"] ?? true
            ],
            "facebook": [
                "onboardingComplete": true,
                "enabled": fbSettings["enabled"] ?? true,
                "blockWatch": fbSettings["blockWatch"] ?? true,
                "blockReels": fbSettings["blockReels"] ?? true,
                "blockMarketplace": fbSettings["blockMarketplace"] ?? false,
                "hideAds": fbSettings["hideAds"] ?? true
            ]
        ]

        sendMessage(message)
        appDelegate?.postLog("🌐 ONBOARDING_SYNC sent to extension on connect")
    }

    /// Push authoritative time tracking state to the extension via STATE_SYNC.
    /// Called after each heartbeat and on initial connect (PING), so the extension
    /// always has the app's numbers in chrome.storage.local.
    private func sendStateSync() {
        guard let tracker = timeTracker else { return }

        var dailyUsage: [String: Any] = [:]
        for (platform, usage) in tracker.getDailyUsage() {
            dailyUsage[platform] = [
                "date": usage.date,
                "minutesUsed": usage.minutesUsed
            ]
        }

        var budgets: [String: Int] = [:]
        for platform in ["youtube", "instagram"] {
            budgets[platform] = tracker.getBudget(for: platform)
        }

        let budgetExceeded = ["youtube", "instagram"].contains { platform in
            tracker.isBudgetExceeded(for: platform)
        }

        sendMessage([
            "type": "STATE_SYNC",
            "dailyUsage": dailyUsage,
            "budgets": budgets,
            "budgetExceeded": budgetExceeded
        ])
    }
}
