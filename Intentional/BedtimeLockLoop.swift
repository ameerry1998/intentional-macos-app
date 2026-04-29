// Intentional/BedtimeLockLoop.swift
// Triggers macOS's native Lock Screen on a 10-second cadence while
// active. Replaces the legacy full-screen `BedtimeOverlayView` blanket.
//
// Mechanism: AppleScript invocation of the system Lock Screen shortcut
// (Cmd+Ctrl+Q). Cheaper than `pmset` (which slept the entire system),
// keeps apps + downloads + music running, lets the user re-enter via
// password / Touch ID. The 10s cadence creates real friction without
// risking lock-mid-keystroke during partner-code entry (a 6-digit code
// can be typed in <5s; even a slow typer has half a window before re-lock).
//
// Self-stops when `BedtimeEnforcer.state` transitions away from `.locked`.
// The timer reads state on every fire; any other state invalidates the
// timer so the lock loop can't outlive bedtime.

import Foundation
import AppKit

@MainActor
final class BedtimeLockLoop {
    static let shared = BedtimeLockLoop()

    private var timer: Timer?
    private weak var enforcer: BedtimeEnforcer?
    weak var appDelegate: AppDelegate?

    /// 10-second lock cadence. See header comment for rationale.
    static let cadence: TimeInterval = 10.0

    var isActive: Bool { timer != nil }

    /// Bind to the enforcer so the loop can self-cancel on state change.
    /// AppDelegate calls this once at init, after bedtimeEnforcer is created.
    func bind(to enforcer: BedtimeEnforcer) {
        self.enforcer = enforcer
        self.appDelegate = enforcer.appDelegate
    }

    /// Start the lock loop. Idempotent: a second call while active is a no-op.
    /// Fires one immediate lock invocation, then every `cadence` seconds.
    func start() {
        guard timer == nil else { return }
        appDelegate?.postLog("🌙 BedtimeLockLoop: starting (\(Int(Self.cadence))s cadence)")
        invokeLock()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.cadence,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stop the lock loop. Idempotent.
    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        appDelegate?.postLog("🌙 BedtimeLockLoop: stopped")
    }

    private func tick() {
        // Self-cancel if the enforcer transitioned away from .locked while
        // we were sleeping. Without this guard the timer would keep locking
        // the screen even after bedtime ended (Risk R10 in the plan).
        if let enforcer, enforcer.state != .lockedOut {
            stop()
            return
        }
        invokeLock()
    }

    /// Trigger Apple's Lock Screen via AppleScript. We use the standard
    /// keyboard shortcut rather than private APIs so this survives macOS
    /// upgrades. If AppleScript / Accessibility is denied (TCC), log + skip;
    /// bedtime is still soft-blocked via the pill but won't lock the screen.
    private func invokeLock() {
        let source = """
        tell application "System Events"
            keystroke "q" using {command down, control down}
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            appDelegate?.postLog("🌙 BedtimeLockLoop: failed to build NSAppleScript")
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            appDelegate?.postLog("🌙 BedtimeLockLoop: AppleScript lock failed: \(error)")
        }
    }
}
