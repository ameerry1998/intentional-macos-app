import Cocoa
import Foundation

// === CRITICAL: USE NSLOG SO WE CAN SEE OUTPUT IN CONSOLE.APP ===
NSLog("🚀🚀🚀 MAIN.SWIFT EXECUTING - PID: \(ProcessInfo.processInfo.processIdentifier)")
NSLog("📁 NSTemporaryDirectory: \(NSTemporaryDirectory())")

// === DIAGNOSTIC LOGGING - FIRST THING, BEFORE ANY LOGIC ===
let diagnosticLogPath = NSTemporaryDirectory() + "intentional-launches.log"
let launchTime = Date()
let myPID = ProcessInfo.processInfo.processIdentifier

NSLog("🔍 Diagnostic log path: \(diagnosticLogPath)")
NSLog("⏰ Launch time: \(launchTime)")
NSLog("🆔 PID: \(myPID)")

let initialLog = """
===== LAUNCH ATTEMPT =====
Time: \(launchTime)
PID: \(myPID)
Args: \(CommandLine.arguments.joined(separator: " "))
isatty(STDIN): \(isatty(STDIN_FILENO))
isatty(STDOUT): \(isatty(STDOUT_FILENO))

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
// The marker file blocks the watchdog from immediately respawning us during dev /
// force-quit windows.
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
        // Restore red shift before hard exit (cleanup won't run after _exit)
        RedShiftController.forceRestoreColor()
        _exit(0)
    } else {
        // Relay process — just exit quietly
        _exit(0)
    }
}
sigtermSource.resume()

// === SINGLE-INSTANCE CHECK ===
do {
    let isXcodeLaunch = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil

    if fileManager.fileExists(atPath: lockFilePath) {
        if let existingPIDStr = try? String(contentsOfFile: lockFilePath, encoding: .utf8),
           let existingPID = Int32(existingPIDStr.trimmingCharacters(in: .whitespacesAndNewlines)) {

            if kill(existingPID, 0) == 0 {
                if isXcodeLaunch {
                    // Xcode debug launch: terminate the existing (watchdog-launched) process
                    // so the debugger can attach to this new instance instead.
                    appendLog("XCODE LAUNCH - Terminating existing PID \(existingPID) to allow debug session")

                    // Disable ALL persistence mechanisms FIRST so launchd won't relaunch
                    // the PKG after we kill it.
                    // 1. KeepAlive LaunchAgent (installed by PKG)
                    let agentTask = Process()
                    agentTask.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    agentTask.arguments = ["bootout", "gui/\(getuid())/com.intentional.agent"]
                    agentTask.standardOutput = FileHandle.nullDevice
                    agentTask.standardError = FileHandle.nullDevice
                    try? agentTask.run()
                    agentTask.waitUntilExit()

                    // 2. Login Item (SMAppService — auto-relaunches on macOS 14+)
                    let findPipe = Pipe()
                    let findTask = Process()
                    findTask.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    findTask.arguments = ["list"]
                    findTask.standardOutput = findPipe
                    findTask.standardError = FileHandle.nullDevice
                    try? findTask.run()
                    findTask.waitUntilExit()
                    if let output = String(data: findPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                        for line in output.components(separatedBy: "\n") {
                            if line.contains("application.com.arayan.intentional") ||
                               line.contains("com.intentional.") {
                                let parts = line.components(separatedBy: "\t")
                                if let label = parts.last?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
                                    let bootTask = Process()
                                    bootTask.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                                    bootTask.arguments = ["bootout", "gui/\(getuid())/\(label)"]
                                    bootTask.standardOutput = FileHandle.nullDevice
                                    bootTask.standardError = FileHandle.nullDevice
                                    try? bootTask.run()
                                    bootTask.waitUntilExit()
                                    appendLog("XCODE LAUNCH - Disabled: \(label)")
                                }
                            }
                        }
                    }
                    appendLog("XCODE LAUNCH - Disabled all persistence mechanisms")

                    // Now kill the old process. Its SIGTERM handler will remove the lock file.
                    kill(existingPID, SIGTERM)
                    for _ in 0..<20 {
                        usleep(100_000) // 100ms
                        if kill(existingPID, 0) != 0 { break }
                    }

                    // Re-write lock file AFTER old process exits (its SIGTERM handler deletes it)
                    try? "\(myPID)".write(toFile: lockFilePath, atomically: true, encoding: .utf8)
                    // Remove no-relaunch marker the old process may have written
                    try? fileManager.removeItem(atPath: noRelaunchMarkerPath)
                } else {
                    // Normal duplicate launch — silently exit without stealing focus.
                    // KeepAlive LaunchAgent respawns every ~10s, so calling activate()
                    // here would pop the app to the front every 10 seconds.
                    appendLog("DUPLICATE DETECTED - Existing PID: \(existingPID) is alive, exiting silently")
                    exit(0)
                }
            } else {
                appendLog("STALE LOCK FILE - PID \(existingPID) is dead, removing lock")
                try? fileManager.removeItem(atPath: lockFilePath)
            }
        }
    }
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
