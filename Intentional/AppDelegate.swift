//
//  AppDelegate.swift
//  Intentional
//
//  Main application delegate - entry point for the app
//

import Cocoa
import Foundation

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    // Menu bar icon
    var statusBarItem: NSStatusItem?

    // Monitoring components
    var sleepWakeMonitor: SleepWakeMonitor?
    var processMonitor: ProcessMonitor?
    var backendClient: BackendClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ Intentional app launched")

        // Initialize backend client
        backendClient = BackendClient(baseURL: "https://api.intentional.social")

        // Create menu bar icon
        setupMenuBar()

        // Start sleep/wake monitoring
        sleepWakeMonitor = SleepWakeMonitor(backendClient: backendClient!)

        // Start process monitoring
        processMonitor = ProcessMonitor(backendClient: backendClient!)
        processMonitor?.startMonitoring()

        // Send startup event
        Task {
            await backendClient?.sendEvent(type: "app_started", details: [:])
        }

        print("✅ All monitors initialized")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("⚠️ App terminating")

        // Send shutdown event before quitting
        Task {
            await backendClient?.sendEvent(type: "app_quit", details: [:])
        }
    }

    // MARK: - Menu Bar Setup

    func setupMenuBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusBarItem?.button {
            // Use SF Symbol
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "eye.circle.fill", accessibilityDescription: "Intentional")
            } else {
                button.title = "👁️"
            }
        }

        // Create menu
        let menu = NSMenu()

        // Status item
        let statusItem = NSMenuItem(title: "Status: Active ✓", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Dashboard
        menu.addItem(NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d"))

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit Intentional", action: #selector(quitApp), keyEquivalent: "q"))

        statusBarItem?.menu = menu
    }

    @objc func openDashboard() {
        // Open web dashboard
        if let url = URL(string: "https://intentional.social/dashboard") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }
}
