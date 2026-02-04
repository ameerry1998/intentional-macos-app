//
//  MainWindow.swift
//  Intentional
//
//  Main application window showing status and recent events
//

import Cocoa
import SwiftUI

class MainWindow: NSWindowController {

    convenience init() {
        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Initialize controller FIRST
        self.init(window: window)

        // Configure window AFTER init
        window.title = "Intentional - System Monitor"
        window.center()
        window.setFrameAutosaveName("MainWindow")

        // Set content view
        window.contentView = NSHostingView(rootView: MainView())

        // Force window visible
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

// SwiftUI Main View
struct MainView: View {
    @State private var events: [SystemEvent] = []
    @State private var logs: [LogEntry] = []
    @State private var deviceId: String = ""
    @State private var isMonitoring: Bool = true
    @State private var missingPermissions: [String] = []
    @State private var unprotectedBrowsers: [UnprotectedBrowser] = []
    @State private var selectedTab: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)

                VStack(alignment: .leading) {
                    Text("Intentional System Monitor")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Monitoring system events and browser status")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Circle()
                    .fill(isMonitoring ? Color.green : Color.red)
                    .frame(width: 12, height: 12)

                Text(isMonitoring ? "Active" : "Inactive")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Device Info
            HStack {
                Label("Device ID:", systemImage: "desktopcomputer")
                    .foregroundColor(.secondary)

                Text(deviceId.isEmpty ? "Loading..." : String(deviceId.prefix(16)) + "...")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Spacer()

                Label("Backend:", systemImage: "network")
                    .foregroundColor(.secondary)

                Text("api.intentional.social")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Tabs
            TabView(selection: $selectedTab) {
                // Monitor Tab
                MonitorTabView(events: $events, logs: $logs)
                    .tabItem {
                        Label("Monitor", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .tag(0)

                // Settings Tab
                SettingsTabView(
                    missingPermissions: $missingPermissions,
                    unprotectedBrowsers: $unprotectedBrowsers,
                    openSystemPreferencesForPermission: openSystemPreferencesForPermission
                )
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(1)
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            loadDeviceId()
            startListeningForEvents()
        }
    }

    private func loadDeviceId() {
        if let stored = UserDefaults.standard.string(forKey: "deviceId") {
            deviceId = stored
        }
    }

    private func startListeningForEvents() {
        // Listen for event notifications
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SystemEventOccurred"),
            object: nil,
            queue: .main
        ) { [self] notification in
            if let eventType = notification.userInfo?["type"] as? String {
                addEvent(type: eventType)

                // Track browser status for unprotected browsers
                if eventType == "browser_started",
                   let details = notification.userInfo?["details"] as? [String: Any],
                   let browserName = details["browser"] as? String,
                   let hasExtension = details["has_extension"] as? Bool {

                    if !hasExtension {
                        // Add to unprotected browsers if not already there
                        if !unprotectedBrowsers.contains(where: { $0.name == browserName }) {
                            unprotectedBrowsers.append(UnprotectedBrowser(
                                name: browserName,
                                lastDetected: Date()
                            ))
                        } else {
                            // Update last detected time
                            if let index = unprotectedBrowsers.firstIndex(where: { $0.name == browserName }) {
                                unprotectedBrowsers[index].lastDetected = Date()
                            }
                        }
                    } else {
                        // Remove from unprotected browsers if present
                        unprotectedBrowsers.removeAll(where: { $0.name == browserName })
                    }
                }
            }
        }

        // Listen for log notifications
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppLogMessage"),
            object: nil,
            queue: .main
        ) { notification in
            if let message = notification.userInfo?["message"] as? String {
                addLog(message: message)
            }
        }

        // Listen for permission status updates
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PermissionStatusUpdated"),
            object: nil,
            queue: .main
        ) { notification in
            if let missing = notification.userInfo?["missing"] as? [String] {
                missingPermissions = missing
            }
        }

        // Check permissions immediately
        checkPermissions()
    }

    private func checkPermissions() {
        // Request permission status from AppDelegate
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            missingPermissions = appDelegate.permissionManager?.getMissingPermissions() ?? []
        }
    }

    private func openSystemPreferencesForPermission(_ permission: String) {
        var urlString: String

        if permission.contains("Notifications") {
            // Open Notifications settings
            urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        } else if permission.contains("AppleEvents") {
            // Open Privacy & Security → Automation
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        } else {
            // Fallback to general Privacy & Security
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func addEvent(type: String) {
        let event = SystemEvent(type: type, timestamp: Date())
        events.append(event)

        // Keep only last 50 events
        if events.count > 50 {
            events.removeFirst()
        }
    }

    private func addLog(message: String) {
        let log = LogEntry(message: message, timestamp: Date())
        logs.append(log)

        // Keep only last 200 logs
        if logs.count > 200 {
            logs.removeFirst()
        }
    }
}

// Log Entry Model
struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let timestamp: Date

    var icon: String {
        if message.contains("✅") { return "checkmark.circle.fill" }
        if message.contains("❌") { return "xmark.circle.fill" }
        if message.contains("⚠️") { return "exclamationmark.triangle.fill" }
        if message.contains("📱") { return "iphone" }
        if message.contains("💤") { return "moon.fill" }
        if message.contains("👁️") { return "eye.fill" }
        if message.contains("🔒") { return "lock.fill" }
        if message.contains("🔓") { return "lock.open.fill" }
        if message.contains("🌐") { return "safari.fill" }
        if message.contains("🚫") { return "xmark.circle.fill" }
        return "circle.fill"
    }

    var color: Color {
        if message.contains("✅") { return .green }
        if message.contains("❌") { return .red }
        if message.contains("⚠️") { return .orange }
        return .primary
    }
}

struct LogRow: View {
    let log: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(log.timestamp, style: .time)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            Image(systemName: log.icon)
                .font(.system(size: 10))
                .foregroundColor(log.color)
                .frame(width: 16)

            Text(log.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }
}

struct EventRow: View {
    let event: SystemEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.icon)
                .font(.system(size: 20))
                .foregroundColor(event.color)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayName)
                    .font(.system(.body, design: .default))

                Text(event.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(event.timestamp, style: .time)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
}

// Event Model
struct SystemEvent: Identifiable {
    let id = UUID()
    let type: String
    let timestamp: Date

    var displayName: String {
        switch type {
        case "app_started": return "App Started"
        case "app_quit": return "App Quit"
        case "computer_sleeping": return "Computer Sleeping"
        case "computer_waking": return "Computer Woke Up"
        case "screen_locked": return "Screen Locked"
        case "screen_unlocked": return "Screen Unlocked"
        case "chrome_started": return "Chrome Started"
        case "chrome_closed": return "Chrome Closed"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var icon: String {
        switch type {
        case "app_started": return "play.circle.fill"
        case "app_quit": return "stop.circle.fill"
        case "computer_sleeping": return "moon.fill"
        case "computer_waking": return "sun.max.fill"
        case "screen_locked": return "lock.fill"
        case "screen_unlocked": return "lock.open.fill"
        case "chrome_started": return "safari.fill"
        case "chrome_closed": return "xmark.circle.fill"
        default: return "circle.fill"
        }
    }

    var color: Color {
        switch type {
        case "app_started", "computer_waking", "screen_unlocked", "chrome_started":
            return .green
        case "app_quit", "computer_sleeping", "screen_locked", "chrome_closed":
            return .orange
        default:
            return .blue
        }
    }
}

// Unprotected Browser Model
struct UnprotectedBrowser: Identifiable {
    let id = UUID()
    let name: String
    var lastDetected: Date
}

// Monitor Tab View
struct MonitorTabView: View {
    @Binding var events: [SystemEvent]
    @Binding var logs: [LogEntry]

    var body: some View {
        VStack(spacing: 0) {
            // Split view: Events on left, Console on right
            HSplitView {
                // Events List
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("System Events")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        Spacer()

                        Button(action: {
                            events.removeAll()
                        }) {
                            Label("Clear", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }

                    ScrollView {
                        if events.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary)

                                Text("No events yet")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                        } else {
                            LazyVStack(spacing: 1) {
                                ForEach(events.reversed()) { event in
                                    EventRow(event: event)
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 250)

                Divider()

                // Console Log
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Console Log")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        Spacer()

                        Button(action: {
                            logs.removeAll()
                        }) {
                            Label("Clear", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(logs) { log in
                                    LogRow(log: log)
                                        .id(log.id)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: logs.count) { _ in
                            if let lastLog = logs.last {
                                withAnimation {
                                    proxy.scrollTo(lastLog.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 300)
                .background(Color(NSColor.textBackgroundColor))
            }

            Divider()

            // Footer
            HStack {
                Text("Monitoring active - events sent to backend automatically")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Open Dashboard") {
                    if let url = URL(string: "https://intentional.social/dashboard") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

// Settings Tab View
struct SettingsTabView: View {
    @Binding var missingPermissions: [String]
    @Binding var unprotectedBrowsers: [UnprotectedBrowser]
    let openSystemPreferencesForPermission: (String) -> Void

    @State private var registeredExtensionIds: [String] = []
    @State private var newExtensionId: String = ""
    @State private var extensionIdError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Extension Setup Section
                ExtensionSetupSection(
                    registeredExtensionIds: $registeredExtensionIds,
                    newExtensionId: $newExtensionId,
                    extensionIdError: $extensionIdError
                )

                Divider()
                // Permissions Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions")
                        .font(.title2)
                        .fontWeight(.bold)

                    if missingPermissions.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("All permissions granted")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Missing Permissions")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                            }

                            ForEach(missingPermissions, id: \.self) { permission in
                                HStack(spacing: 8) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.red)

                                    Text(permission)
                                        .font(.body)
                                        .foregroundColor(.secondary)

                                    Spacer()

                                    Button("Grant") {
                                        openSystemPreferencesForPermission(permission)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                }

                Divider()

                // Unprotected Browsers Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Browser Status")
                        .font(.title2)
                        .fontWeight(.bold)

                    if unprotectedBrowsers.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                            Text("No unprotected browsers detected")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundColor(.orange)
                                Text("Browsers Without Extension")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                            }

                            Text("The following browsers are running without the Intentional extension. Install the extension to enable accountability on all browsers.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom, 4)

                            ForEach(unprotectedBrowsers) { browser in
                                HStack(spacing: 12) {
                                    Image(systemName: "safari")
                                        .font(.system(size: 20))
                                        .foregroundColor(.orange)
                                        .frame(width: 30)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(browser.name)
                                            .font(.body)
                                            .fontWeight(.medium)

                                        Text("Last detected: \(browser.lastDetected, style: .relative)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            refreshExtensionIds()
        }
    }

    private func refreshExtensionIds() {
        registeredExtensionIds = NativeMessagingSetup.shared.getRegisteredIds()
    }
}

// Extension Setup Section
struct ExtensionSetupSection: View {
    @Binding var registeredExtensionIds: [String]
    @Binding var newExtensionId: String
    @Binding var extensionIdError: String?

    @State private var browserStatus: [BrowserExtensionStatus] = []
    @State private var isScanning: Bool = false
    @State private var lastScanMessage: String? = nil
    @State private var showManualEntry: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Browser Extensions")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button(action: scanForExtensions) {
                    HStack(spacing: 4) {
                        if isScanning {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isScanning ? "Scanning..." : "Scan")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)
            }

            Text("Install the Intentional extension in each browser you want to track. The app automatically detects installed extensions.")
                .font(.caption)
                .foregroundColor(.secondary)

            if let message = lastScanMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.green)
            }

            // Browser list with status
            if browserStatus.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                            .foregroundColor(.secondary)
                        Text("No Chromium browsers detected")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }

                    Text("Install Chrome, Brave, Arc, Edge, or another Chromium-based browser.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(browserStatus) { browser in
                        BrowserStatusRow(browser: browser, onOpenBrowser: {
                            NativeMessagingSetup.shared.openExtensionsPage(bundleId: browser.bundleId)
                        })

                        if browser.id != browserStatus.last?.id {
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }

            // Summary
            let connectedCount = browserStatus.filter { $0.hasExtension }.count
            let totalCount = browserStatus.count

            if totalCount > 0 {
                HStack(spacing: 6) {
                    if connectedCount == totalCount {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("All browsers connected")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if connectedCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("\(connectedCount)/\(totalCount) browsers connected - install extension in remaining browsers for complete tracking")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("No extensions detected - click 'Install' to open each browser")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.top, 4)
            }

            // Manual Entry (collapsed by default)
            DisclosureGroup("Manual Entry", isExpanded: $showManualEntry) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If auto-discovery doesn't find your extension, you can add it manually.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Extension ID (32 characters)", text: $newExtensionId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))

                        Button("Add") {
                            addExtension()
                        }
                        .disabled(newExtensionId.isEmpty)
                    }

                    if let error = extensionIdError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Text("Find your extension ID at chrome://extensions with Developer mode enabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
        }
        .onAppear {
            refreshStatus()
        }
    }

    private func refreshStatus() {
        browserStatus = NativeMessagingSetup.shared.getBrowserStatus()
        registeredExtensionIds = NativeMessagingSetup.shared.getRegisteredIds()
    }

    private func scanForExtensions() {
        isScanning = true
        lastScanMessage = nil

        // Run scan in background
        DispatchQueue.global(qos: .userInitiated).async {
            let found = NativeMessagingSetup.shared.autoDiscoverExtensions()

            DispatchQueue.main.async {
                isScanning = false
                refreshStatus()

                if found > 0 {
                    lastScanMessage = "Found \(found) new extension(s)!"
                } else {
                    let connectedCount = browserStatus.filter { $0.hasExtension }.count
                    if connectedCount > 0 {
                        lastScanMessage = "Scan complete."
                    } else {
                        lastScanMessage = nil
                    }
                }
            }
        }
    }

    private func addExtension() {
        let trimmed = newExtensionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.isEmpty {
            extensionIdError = "Please enter an extension ID"
            return
        }

        let allIds = NativeMessagingSetup.shared.getAllExtensionIds()
        if allIds.contains(trimmed) {
            extensionIdError = "This extension is already registered"
            return
        }

        if NativeMessagingSetup.shared.registerExtensionId(trimmed) {
            refreshStatus()
            newExtensionId = ""
            extensionIdError = nil
        } else {
            extensionIdError = "Invalid extension ID format. Must be 32 lowercase letters (a-p)."
        }
    }
}

// Individual browser row showing status
struct BrowserStatusRow: View {
    let browser: BrowserExtensionStatus
    let onOpenBrowser: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Browser icon
            Image(systemName: browserIcon(for: browser.name))
                .font(.system(size: 20))
                .foregroundColor(.primary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(browser.name)
                    .font(.headline)

                if let extensionId = browser.extensionId {
                    Text(extensionId)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Extension not installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if browser.hasExtension {
                if browser.isEnabled {
                    // Extension installed and enabled
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Connected")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } else {
                    // Extension installed but disabled
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Disabled")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            } else {
                // Install button
                Button(action: onOpenBrowser) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Install")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func browserIcon(for name: String) -> String {
        switch name.lowercased() {
        case let n where n.contains("chrome"):
            return "globe"
        case let n where n.contains("brave"):
            return "shield.fill"
        case let n where n.contains("edge"):
            return "globe.americas.fill"
        case let n where n.contains("arc"):
            return "rainbow"
        case let n where n.contains("opera"):
            return "music.note"
        case let n where n.contains("vivaldi"):
            return "music.quarternote.3"
        case let n where n.contains("safari"):
            return "safari.fill"
        default:
            return "globe"
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
