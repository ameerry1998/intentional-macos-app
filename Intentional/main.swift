//
//  main.swift
//  Intentional
//
//  Explicit app entry point - bypasses @main to ensure initialization
//

import Cocoa

// Print to console AND file to diagnose execution
let logPath = NSTemporaryDirectory() + "intentional-debug.log"
print("=== MAIN.SWIFT EXECUTING ===")

// Create initial log file
try? "main.swift executed at \(Date())\nAppDelegate set at \(Date())\n".write(toFile: logPath, atomically: true, encoding: .utf8)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

print("=== APP DELEGATE SET ===")

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
