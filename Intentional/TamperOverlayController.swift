//
//  TamperOverlayController.swift
//  Intentional
//
//  Full-screen overlay shown when the EnforcementReconciler force-corrects
//  local state. Matches the pattern used by SwitchOverlayController (one
//  window per screen, screenSaver level).
//

import Cocoa
import SwiftUI

final class TamperOverlayController {

    private var windows: [NSWindow] = []

    func show(violations: [(String, Any)]) {
        dismiss()

        let headline: String
        if violations.count == 1 && violations[0].0 == "content_safety.enabled" {
            headline = "Content Safety was turned off outside the dashboard."
        } else if violations.count == 1 {
            headline = "A partner-locked setting was changed outside the dashboard."
        } else {
            headline = "Partner-locked settings were changed outside the dashboard."
        }

        let formatted = violations.map { format(key: $0.0, correction: $0.1) }
        let view = TamperOverlayView(
            headline: headline,
            bullets: formatted,
            dismiss: { [weak self] in self?.dismiss() }
        )

        for (i, screen) in NSScreen.screens.enumerated() {
            let host = NSHostingView(rootView: view)
            host.frame = screen.frame
            let w = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.level = .screenSaver
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            if i == 0 { w.makeKeyAndOrderFront(nil) } else { w.orderFront(nil) }
            windows.append(w)
        }

        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    func dismiss() {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
    }

    var isShowing: Bool { !windows.isEmpty }

    private func format(key: String, correction: Any) -> String {
        switch key {
        case "content_safety.enabled":
            return "Content Safety: re-enabled"
        case "distracting_sites":
            let items = (correction as? [String]) ?? []
            return "Distracting sites: restored \(items.count) site(s)"
        default:
            if key.hasSuffix(".enabled") {
                return "\(key): re-enabled"
            }
            if key.hasSuffix(".threshold"), let v = correction as? Double {
                return "\(key): raised back to \(Int(v))"
            }
            return "\(key): corrected"
        }
    }
}

struct TamperOverlayView: View {
    let headline: String
    let bullets: [String]
    let dismiss: () -> Void
    @State private var breathing = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 28) {
                Text(headline)
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text("It has been re-enabled. Caity has been notified.")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.6))
                if !bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(bullets, id: \.self) { b in
                            HStack(alignment: .top) {
                                Text("•").foregroundColor(.white.opacity(0.45))
                                Text(b).foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }.padding(.top, 8)
                }
                Button(action: dismiss) {
                    Text("Got it — keep working")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 13)
                        .background(Color.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(40)
            .frame(maxWidth: 600)
        }
        .opacity(breathing ? 1.0 : 0.96)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
    }
}
