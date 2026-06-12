//
//  SleepWakeMonitor.swift
//  Intentional
//
//  Monitors system sleep/wake events
//

import Foundation
import Cocoa

class SleepWakeMonitor {

    private let backendClient: BackendClient
    private weak var appDelegate: AppDelegate?
    var onWake: (() -> Void)?
    /// Timestamp of the most recent willSleep notification. Read by
    /// FocusMonitor's wake handler (Task 8 idle/away clean end) to compute the
    /// sleep gap — nil until the first sleep of this app run.
    private(set) var lastWillSleepAt: Date?

    init(backendClient: BackendClient, appDelegate: AppDelegate) {
        self.backendClient = backendClient
        self.appDelegate = appDelegate
        registerForNotifications()
    }

    private func registerForNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        // Computer will sleep
        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.computerWillSleep()
        }

        // Computer did wake
        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.computerDidWake()
        }

        // Screens did sleep (screen locked)
        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenDidLock()
        }

        // Screens did wake (screen unlocked)
        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenDidUnlock()
        }

        // Logged by AppDelegate
    }

    // MARK: - Event Handlers

    private func computerWillSleep() {
        lastWillSleepAt = Date()
        appDelegate?.postLog("💤 Computer going to sleep")

        Task {
            await backendClient.sendEvent(type: "computer_sleeping", details: [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }

        appDelegate?.postEventNotification(type: "computer_sleeping")
        appDelegate?.contentSafetyMonitor?.onSleep()
    }

    private func computerDidWake() {
        appDelegate?.postLog("👁️ Computer woke up")

        Task {
            await backendClient.sendEvent(type: "computer_waking", details: [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }

        appDelegate?.postEventNotification(type: "computer_waking")
        appDelegate?.contentSafetyMonitor?.onWake()
        onWake?()
    }

    private func screenDidLock() {
        appDelegate?.postLog("🔒 Screen locked")

        Task {
            await backendClient.sendEvent(type: "screen_locked", details: [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }

        appDelegate?.postEventNotification(type: "screen_locked")
    }

    private func screenDidUnlock() {
        appDelegate?.postLog("🔓 Screen unlocked")

        Task {
            await backendClient.sendEvent(type: "screen_unlocked", details: [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }

        appDelegate?.postEventNotification(type: "screen_unlocked")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
