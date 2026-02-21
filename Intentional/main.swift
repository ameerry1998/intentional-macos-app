import Cocoa
import Foundation

// === CRITICAL: USE NSLOG SO WE CAN SEE OUTPUT IN CONSOLE.APP ===
NSLog("🚀🚀🚀 MAIN.SWIFT EXECUTING - PID: \(ProcessInfo.processInfo.processIdentifier)")
NSLog("📁 NSTemporaryDirectory: \(NSTemporaryDirectory())")

// === DIAGNOSTIC LOGGING - FIRST THING, BEFORE ANY LOGIC ===
let diagnosticLogPath = NSTemporaryDirectory() + "intentional-launches.log"
let launchTime = Date()
let myPID = ProcessInfo.processInfo.processIdentifier
// Detect Chrome/Firefox native messaging launch by checking command line arguments.
// Chrome passes "chrome-extension://extensionId/" and Firefox passes the extension path.
// IMPORTANT: Do NOT use `isatty(STDIN_FILENO) == 0` — that's also true for NSWorkspace.open(),
// Finder launch, and any non-terminal context, causing false positives.
let launchedViaExtension = CommandLine.arguments.contains { arg in
    arg.hasPrefix("chrome-extension://") || arg.hasPrefix("moz-extension://")
}

NSLog("🔍 Diagnostic log path: \(diagnosticLogPath)")
NSLog("⏰ Launch time: \(launchTime)")
NSLog("🆔 PID: \(myPID)")
NSLog("📡 Launched via extension: \(launchedViaExtension)")

let initialLog = """
===== LAUNCH ATTEMPT =====
Time: \(launchTime)
PID: \(myPID)
Args: \(CommandLine.arguments.joined(separator: " "))
isatty(STDIN): \(isatty(STDIN_FILENO))
isatty(STDOUT): \(isatty(STDOUT_FILENO))
Launched via extension: \(launchedViaExtension)

"""
// Rotate launch log if it exceeds 10MB
if let attrs = try? FileManager.default.attributesOfItem(atPath: diagnosticLogPath),
   let size = attrs[FileAttributeKey.size] as? Int,
   size > 10_000_000 {
    try? FileManager.default.removeItem(atPath: diagnosticLogPath)
}

if let existingLog = try? String(contentsOfFile: diagnosticLogPath, encoding: .utf8) {
    try? (existingLog + initialLog).write(toFile: diagnosticLogPath, atomically: true, encoding: .utf8)
} else {
    try? initialLog.write(toFile: diagnosticLogPath, atomically: true, encoding: .utf8)
}

// === SINGLE-INSTANCE ENFORCEMENT ===
let lockFilePath = NSTemporaryDirectory() + "intentional-app.lock"
let fileManager = FileManager.default

func appendLog(_ message: String) {
    let entry = message + "\n"
    if let existingLog = try? String(contentsOfFile: diagnosticLogPath, encoding: .utf8) {
        try? (existingLog + entry).write(toFile: diagnosticLogPath, atomically: true, encoding: .utf8)
    }
}

// === SIGTERM HANDLER: Prevent relaunch loop ===
// When Xcode or Force Quit terminates the app, SIGTERM is sent before SIGKILL.
// We write a marker file so extension-launched processes know not to restart the app.
//
// With the relay architecture, the primary process is ALWAYS manually launched
// (from Finder/Dock/Xcode), never by Chrome. Extension-launched processes are
// thin relays that exit via dispatchMain() before reaching the primary path.
let noRelaunchMarkerPath = NSTemporaryDirectory() + "intentional-no-relaunch"
var isPrimaryProcess = false

signal(SIGPIPE, SIG_IGN) // Ignore broken pipe — writes to closed pipes return EPIPE instead of killing the process
signal(SIGTERM, SIG_IGN) // Disable default SIGTERM so GCD source can handle it
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInteractive))
sigtermSource.setEventHandler {
    if isPrimaryProcess {
        // Check if strict mode is active — if so, do NOT write the no-relaunch marker.
        // This lets the watchdog LaunchAgent relaunch the app after force-quit.
        let strictFlagPath = NSHomeDirectory() + "/Library/Application Support/Intentional/strict-mode"
        let strictMode = FileManager.default.fileExists(atPath: strictFlagPath)

        // Detect Xcode debug launches — Xcode sets this env var when running from IDE.
        // During development we always want the app to stay dead after Xcode stops it.
        let isXcodeLaunch = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil

        if !strictMode || isXcodeLaunch {
            // Normal mode (or Xcode dev): block relaunch for 30 seconds
            FileManager.default.createFile(atPath: noRelaunchMarkerPath, contents: "1".data(using: .utf8))
            appendLog("SIGTERM [PRIMARY] - No-relaunch marker written (strict=\(strictMode), xcode=\(isXcodeLaunch))")
        } else {
            appendLog("SIGTERM [PRIMARY] - Strict mode ON, skipping no-relaunch marker (watchdog will relaunch)")
        }

        // Always remove lock file so the relaunched instance can become primary
        try? FileManager.default.removeItem(atPath: lockFilePath)
        _exit(0)
    } else {
        // Relay process — just exit quietly
        _exit(0)
    }
}
sigtermSource.resume()

// === SINGLE-INSTANCE CHECK (for manually-launched duplicates only) ===
// Extension-launched processes skip this — they go straight to the relay block below.
if !launchedViaExtension {
    let isXcodeLaunch = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil

    if fileManager.fileExists(atPath: lockFilePath) {
        if let existingPIDStr = try? String(contentsOfFile: lockFilePath, encoding: .utf8),
           let existingPID = Int32(existingPIDStr.trimmingCharacters(in: .whitespacesAndNewlines)) {

            if kill(existingPID, 0) == 0 {
                if isXcodeLaunch {
                    // Xcode debug launch: terminate the existing (watchdog-launched) process
                    // so the debugger can attach to this new instance instead.
                    appendLog("XCODE LAUNCH - Terminating existing PID \(existingPID) to allow debug session")
                    kill(existingPID, SIGTERM)
                    // Wait briefly for the old process to exit and release the lock
                    for _ in 0..<20 {
                        usleep(100_000) // 100ms
                        if kill(existingPID, 0) != 0 { break }
                    }
                    try? fileManager.removeItem(atPath: lockFilePath)
                    // Remove no-relaunch marker the old process may have written
                    try? fileManager.removeItem(atPath: noRelaunchMarkerPath)
                } else {
                    // Normal duplicate launch — activate existing window and exit
                    appendLog("DUPLICATE DETECTED - Existing PID: \(existingPID) is alive, activating window")
                    let runningApps = NSWorkspace.shared.runningApplications
                    if let existing = runningApps.first(where: { $0.processIdentifier == existingPID }) {
                        existing.activate(options: .activateIgnoringOtherApps)
                    }
                    exit(0)
                }
            } else {
                appendLog("STALE LOCK FILE - PID \(existingPID) is dead, removing lock")
                try? fileManager.removeItem(atPath: lockFilePath)
            }
        }
    }
}

// === EXTENSION-LAUNCHED: ALWAYS RELAY, NEVER PRIMARY ===
// Chrome owns the process it spawns via native messaging. When the extension
// reconnects (e.g., browser reload, extension update), Chrome SIGTERMs the old
// host, waits ~2s, then SIGKILLs it. SIGKILL is uncatchable — if this process
// IS the app, the app dies silently.
//
// Solution: Extension-launched processes are ALWAYS thin relays. If no primary
// app is running, we launch it independently via NSWorkspace (so Chrome doesn't
// own it), wait for its socket server, then relay stdin/stdout ↔ socket.
if launchedViaExtension {
    // Check 1: UserDefaults flag (set to false in applicationWillTerminate during normal quit)
    let allowAutoLaunch = UserDefaults.standard.bool(forKey: "allowAutoLaunchFromExtension")
    if !allowAutoLaunch {
        appendLog("BLOCKED - Auto-launch disabled (user quit the app normally)")
        exit(0)
    }

    // Check 2: No-relaunch marker file (written by SIGTERM handler during force-termination)
    // This catches Xcode Stop and Force Quit, where applicationWillTerminate never runs
    if fileManager.fileExists(atPath: noRelaunchMarkerPath) {
        if let attrs = try? fileManager.attributesOfItem(atPath: noRelaunchMarkerPath),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < 30 {
            appendLog("BLOCKED - App was force-terminated \(Int(Date().timeIntervalSince(modDate)))s ago")
            exit(0)
        } else {
            // Marker is stale (> 30 seconds old), safe to remove and allow relaunch
            try? fileManager.removeItem(atPath: noRelaunchMarkerPath)
            appendLog("Removed stale no-relaunch marker")
        }
    }

    // No primary running? Launch the app independently so Chrome doesn't own it.
    // We resolve the app bundle from our own executable path:
    //   .../Intentional.app/Contents/MacOS/Intentional → .../Intentional.app
    let executablePath = CommandLine.arguments[0]
    let macosDir = (executablePath as NSString).deletingLastPathComponent  // .../Contents/MacOS
    let contentsDir = (macosDir as NSString).deletingLastPathComponent     // .../Contents
    let bundlePath = (contentsDir as NSString).deletingLastPathComponent   // .../Intentional.app

    if !fileManager.fileExists(atPath: lockFilePath) ||
       {
           // Lock file exists but process is dead — stale lock
           if let pidStr = try? String(contentsOfFile: lockFilePath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
               return kill(pid, 0) != 0  // true if process is dead
           }
           return true  // Can't read lock file, treat as stale
       }() {
        // No primary app running — launch it independently
        appendLog("RELAY: No primary running, launching app independently via NSWorkspace")

        // Remove stale lock file so the new process can claim it
        try? fileManager.removeItem(atPath: lockFilePath)

        let bundleURL = URL(fileURLWithPath: bundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false  // Don't steal focus — launch in background

        let launchSemaphore = DispatchSemaphore(value: 0)
        var launchSucceeded = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
            if let error = error {
                appendLog("RELAY: Failed to launch app: \(error)")
            } else {
                launchSucceeded = true
                appendLog("RELAY: App launched with PID \(app?.processIdentifier ?? -1)")
            }
            launchSemaphore.signal()
        }
        // Wait up to 5 seconds for launch
        _ = launchSemaphore.wait(timeout: .now() + 5.0)

        guard launchSucceeded else {
            appendLog("RELAY: App launch failed, exiting")
            exit(1)
        }
    }

    // Connect to the primary app's socket server (may need to wait for it to start)
    appendLog("RELAY: Connecting to primary app socket...")
    let uid = getuid()
    let socketPath = NSTemporaryDirectory() + "intentional-native-messaging-\(uid).sock"

    let sockFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sockFd >= 0 else {
        appendLog("RELAY FAILED - Cannot create socket: \(String(cString: strerror(errno)))")
        exit(1)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
        for i in 0..<min(pathBytes.count, rawBuf.count - 1) {
            rawBuf[i] = UInt8(bitPattern: pathBytes[i])
        }
    }

    // Retry connection — the app we just launched may need time to start its socket server
    var connected = false
    for attempt in 1...15 {
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sockFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult == 0 {
            connected = true
            appendLog("RELAY CONNECTED on attempt \(attempt)")
            break
        }
        if attempt <= 3 {
            appendLog("RELAY connect attempt \(attempt) failed: \(String(cString: strerror(errno)))")
        }
        usleep(500_000) // 500ms between attempts (15 × 500ms = 7.5s max wait)
    }

    guard connected else {
        appendLog("RELAY FAILED - Cannot connect after 15 attempts")
        close(sockFd)
        exit(1)
    }

    // Bidirectional relay: stdin (Chrome) ↔ socket (primary app)
    let stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global(qos: .userInitiated))
    let socketSource = DispatchSource.makeReadSource(fileDescriptor: sockFd, queue: .global(qos: .userInitiated))

    stdinSource.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(STDIN_FILENO, &buf, buf.count)
        if bytesRead <= 0 {
            close(sockFd)
            exit(0)
        }
        buf.withUnsafeBufferPointer { ptr in
            var offset = 0
            while offset < bytesRead {
                let written = write(sockFd, ptr.baseAddress! + offset, bytesRead - offset)
                if written <= 0 { exit(0) }
                offset += written
            }
        }
    }

    socketSource.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(sockFd, &buf, buf.count)
        if bytesRead <= 0 {
            // Primary died — write marker to prevent immediate relaunch loop
            FileManager.default.createFile(
                atPath: noRelaunchMarkerPath,
                contents: "1".data(using: .utf8))
            appendLog("RELAY: Primary died, wrote no-relaunch marker")
            exit(0)
        }
        buf.withUnsafeBufferPointer { ptr in
            var offset = 0
            while offset < bytesRead {
                let written = write(STDOUT_FILENO, ptr.baseAddress! + offset, bytesRead - offset)
                if written <= 0 { exit(0) }
                offset += written
            }
        }
    }

    stdinSource.setCancelHandler {
        close(sockFd)
        exit(0)
    }
    socketSource.setCancelHandler {
        exit(0)
    }

    stdinSource.resume()
    socketSource.resume()

    // Block forever — GCD sources handle all I/O.
    // Chrome can SIGTERM/SIGKILL this process freely; the real app is unaffected.
    appendLog("RELAY: Active, forwarding stdin ↔ socket (Chrome can kill this safely)")
    dispatchMain()
    // Never reaches here
}

// === PRIMARY APP PATH (manually launched from Finder/Dock/Xcode) ===

// Create lock file
try? "\(myPID)".write(toFile: lockFilePath, atomically: true, encoding: .utf8)
isPrimaryProcess = true
appendLog("LOCK CREATED - This is the primary instance (PID: \(myPID))")

// Clean up any stale no-relaunch marker (we're starting successfully, future relaunches are OK)
try? fileManager.removeItem(atPath: noRelaunchMarkerPath)

// Register cleanup handler
atexit {
    let cleanupLog = "CLEANUP - Removing lock file for PID: \(myPID)\n"
    if let existingLog = try? String(contentsOfFile: diagnosticLogPath, encoding: .utf8) {
        try? (existingLog + cleanupLog).write(toFile: diagnosticLogPath, atomically: true, encoding: .utf8)
    }
    try? FileManager.default.removeItem(atPath: lockFilePath)
}

appendLog("CONTINUING TO NSApplicationMain...")

// Set up NSApplication with AppDelegate
NSLog("🏗️ Creating NSApplication and AppDelegate...")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
NSLog("✅ AppDelegate assigned, calling NSApplicationMain...")

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

NSLog("❌ NSApplicationMain returned - this should never happen")
