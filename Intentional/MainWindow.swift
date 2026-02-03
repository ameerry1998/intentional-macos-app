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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Intentional - System Monitor"
        window.center()
        window.setFrameAutosaveName("MainWindow")

        // Set content view
        let contentView = MainView()
        window.contentView = NSHostingView(rootView: contentView)

        self.init(window: window)
    }
}

// SwiftUI Main View
struct MainView: View {
    @State private var events: [SystemEvent] = []
    @State private var logs: [LogEntry] = []
    @State private var deviceId: String = ""
    @State private var isMonitoring: Bool = true

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

                    Text("Monitoring system events and Chrome status")
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
        ) { notification in
            if let eventType = notification.userInfo?["type"] as? String {
                addEvent(type: eventType)
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

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
