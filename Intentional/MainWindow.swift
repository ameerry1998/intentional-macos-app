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

            // Events List
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent System Events")
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
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)

                            Text("No events yet")
                                .foregroundColor(.secondary)

                            Text("Events will appear here as they occur")
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
        // Listen for notifications from AppDelegate
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SystemEventOccurred"),
            object: nil,
            queue: .main
        ) { notification in
            if let eventType = notification.userInfo?["type"] as? String {
                addEvent(type: eventType)
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
