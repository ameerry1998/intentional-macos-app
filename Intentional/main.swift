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
try? "main.swift executed at \(Date())\n".write(toFile: logPath, atomically: true, encoding: .utf8)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

print("=== APP DELEGATE SET ===")
try? "AppDelegate set at \(Date())\n".appendLine(to: logPath)

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

// Helper to append to log file
extension String {
    func appendLine(to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let data = self.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        }
    }
}
