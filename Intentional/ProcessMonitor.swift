//
//  ProcessMonitor.swift
//  Intentional
//
//  Monitors if Chrome browser is running
//

import Foundation
import Cocoa

class ProcessMonitor {

    private let backendClient: BackendClient
    private var monitorTimer: Timer?
    private var wasChromeRunning: Bool = false

    init(backendClient: BackendClient) {
        self.backendClient = backendClient
    }

    func startMonitoring() {
        // Check every 30 seconds
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkBrowserStatus()
        }

        // Check immediately on start
        checkBrowserStatus()

        print("✅ Process monitoring started")
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func checkBrowserStatus() {
        let chromeRunning = isChromeRunning()

        // Detect state changes
        if chromeRunning != wasChromeRunning {
            handleBrowserStateChange(isRunning: chromeRunning)
            wasChromeRunning = chromeRunning
        }
    }

    private func isChromeRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications

        return runningApps.contains { app in
            app.bundleIdentifier == "com.google.Chrome" ||
            app.bundleIdentifier == "com.google.Chrome.beta" ||
            app.bundleIdentifier == "com.google.Chrome.dev" ||
            app.bundleIdentifier == "com.google.Chrome.canary"
        }
    }

    private func handleBrowserStateChange(isRunning: Bool) {
        if isRunning {
            print("🌐 Chrome started")

            Task {
                await backendClient.sendEvent(type: "chrome_started", details: [:])
            }

            // Notify UI
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.postEventNotification(type: "chrome_started")
            }
        } else {
            print("🚫 Chrome closed")

            Task {
                await backendClient.sendEvent(type: "chrome_closed", details: [:])
            }

            // Notify UI
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.postEventNotification(type: "chrome_closed")
            }
        }
    }

    deinit {
        stopMonitoring()
    }
}
