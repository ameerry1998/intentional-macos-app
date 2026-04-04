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

        // Use launchctl kickstart to launch the app's LaunchAgent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(consoleUID)/com.intentional.agent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                log("App relaunched via launchctl kickstart (uid=\(consoleUID))")
            } else {
                // Fallback: try open command
                log("launchctl kickstart failed, trying open -a")
                launchViaOpen()
            }
        } catch {
            log("Failed to relaunch via launchctl: \(error.localizedDescription)")
            launchViaOpen()
        }
    }

    private func launchViaOpen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            log("App relaunched via open -a (exit=\(process.terminationStatus))")
        } catch {
            log("Failed to relaunch via open: \(error.localizedDescription)")
        }
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
