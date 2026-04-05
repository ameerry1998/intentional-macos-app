//
//  AppWatchdog.swift
//  IntentionalDaemon
//
//  Monitors whether Intentional.app is running. If strict mode is enabled
//  and the app is not running, relaunches it via launchctl.
//

import Foundation

class AppWatchdog {

    private let config: ConfigManager
    private let heartbeat: HeartbeatService
    private var timer: DispatchSourceTimer?
    private let checkInterval: TimeInterval = 5  // Check every 5 seconds
    private let appPath = "/Applications/Intentional.app"
    private let appBundleId = "com.arayan.intentional"

    init(config: ConfigManager, heartbeat: HeartbeatService) {
        self.config = config
        self.heartbeat = heartbeat
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: checkInterval)  // Wait 10s on boot before first check
        timer.setEventHandler { [weak self] in
            self?.checkApp()
        }
        timer.resume()
        self.timer = timer
        log("App watchdog started (checking every \(Int(checkInterval))s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func checkApp() {
        guard config.strictModeEnabled else { return }

        // Check if app binary still exists
        guard FileManager.default.fileExists(atPath: appPath) else {
            log("TAMPER: Intentional.app has been deleted!")
            heartbeat.reportTamper(eventType: "app_deleted", detail: "Intentional.app removed from /Applications")
            return
        }

        // Check if app process is running
        let isRunning = isAppRunning()
        if !isRunning {
            log("App not running while strict mode is ON — relaunching")
            relaunchApp()
        }
    }

    private func isAppRunning() -> Bool {
        // Use pgrep to check for the process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Intentional"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func relaunchApp() {
        // Find the console user's UID to launch in their GUI session
        guard let consoleUID = getConsoleUserUID() else {
            log("Cannot relaunch: no console user found")
            return
        }

        // Try method 1: launchctl kickstart
        let kickstart = Process()
        kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kickstart.arguments = ["kickstart", "-k", "gui/\(consoleUID)/com.intentional.agent"]
        kickstart.standardOutput = FileHandle.nullDevice
        kickstart.standardError = FileHandle.nullDevice
        try? kickstart.run()
        kickstart.waitUntilExit()

        // Verify the app actually started (kickstart can return 0 but fail to spawn)
        Thread.sleep(forTimeInterval: 2.0)
        if isAppRunning() {
            log("App relaunched via launchctl kickstart (uid=\(consoleUID))")
            return
        }

        // Try method 2: open -a
        log("launchctl kickstart didn't work, trying open -a")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appPath]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()

        Thread.sleep(forTimeInterval: 2.0)
        if isAppRunning() {
            log("App relaunched via open -a")
            return
        }

        // Try method 3: launch binary directly as the console user
        log("open -a didn't work, trying direct binary launch")
        let direct = Process()
        direct.executableURL = URL(fileURLWithPath: "/usr/bin/su")
        direct.arguments = ["-l", getConsoleUserName() ?? "arayan", "-c", "\(appPath)/Contents/MacOS/Intentional &"]
        direct.standardOutput = FileHandle.nullDevice
        direct.standardError = FileHandle.nullDevice
        try? direct.run()
        direct.waitUntilExit()

        Thread.sleep(forTimeInterval: 2.0)
        if isAppRunning() {
            log("App relaunched via direct binary launch")
        } else {
            log("ALL relaunch methods failed — app could not be started")
        }
    }

    private func getConsoleUserName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        process.arguments = ["-f", "%Su", "/dev/console"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    private func getConsoleUserUID() -> uid_t? {
        // Get the UID of the user logged into the console (GUI session)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        process.arguments = ["-f", "%u", "/dev/console"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let uid = uid_t(str) {
                return uid
            }
        } catch {}
        return nil
    }
}
