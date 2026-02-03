//
//  SimpleTest.swift
//  Simple test to verify window can appear at all
//

import Cocoa
import SwiftUI

// COMMENT OUT @main in AppDelegate.swift first!
// Then uncomment the @main below

/*
@main
class SimpleTestApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("=== SIMPLE TEST: App launched ===")

        // Create a basic window
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Set a bright red background so we KNOW if it appears
        let redView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        redView.wantsLayer = true
        redView.layer?.backgroundColor = NSColor.red.cgColor
        window.contentView = redView

        window.title = "SIMPLE TEST - RED WINDOW"
        window.center()

        NSLog("=== Window created, showing now ===")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        NSApp.activate(ignoringOtherApps: true)

        NSLog("=== Window should be visible ===")
    }
}
*/
