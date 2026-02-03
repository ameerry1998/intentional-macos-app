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

    init(backendClient: BackendClient) {
        self.backendClient = backendClient
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

        print("✅ Sleep/wake notifications registered")
    }

    // MARK: - Event Handlers

    private func computerWillSleep() {
        print("💤 Computer going to sleep")

        Task {
            await backendClient.sendEvent(type: "computer_sleeping", details: [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }

        // Notify UI
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.postEventNotification(type: "computer_sleeping")
        }
    }

    private func computerDidWake() {
        print("👁️ Computer woke up")

        Task {
            await backendClient.sendEvent(type: "computer_waking", details: [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }

        // Notify UI
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.postEventNotification(type: "computer_waking")
        }
    }

    private func screenDidLock() {
        print("🔒 Screen locked")

        Task {
            await backendClient.sendEvent(type: "screen_locked", details: [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }

        // Notify UI
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.postEventNotification(type: "screen_locked")
        }
    }

    private func screenDidUnlock() {
        print("🔓 Screen unlocked")

        Task {
            await backendClient.sendEvent(type: "screen_unlocked", details: [
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        }

        // Notify UI
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.postEventNotification(type: "screen_unlocked")
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
