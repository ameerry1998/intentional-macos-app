// Intentional/BedtimeLockLoop.swift
// Triggers macOS's native Lock Screen on a 10-second cadence while
// active. Replaces the legacy full-screen `BedtimeOverlayView` blanket.
//
// Lock mechanism: dlopen → SACLockScreenImmediate from login.framework.
// This is the same primitive Apple's "Lock Screen" menu item uses, and
// it ALWAYS forces password re-entry — independent of the user's
// "Require password X after sleep" Lock Screen setting. The previous
// implementation used `tell application "System Events" to keystroke
// "q" using {command down, control down}` which (a) requires
// Accessibility permission, (b) is interpreted as "Sleep Display" not
// "Lock Screen" on machines where the password-after-sleep delay is
// not "Immediately", and (c) cannot deliver keystrokes to a
// loginwindow-locked context (so subsequent ticks no-op'd silently).
//
// Apps that use the same `SACLockScreenImmediate` primitive: Alfred,
// Bartender, various macOS lock utilities. It's a private API but
// stable — Apple has not deprecated it across macOS versions and it
// passes Developer ID notarization.
//
// Self-stops when `BedtimeEnforcer.state` transitions away from `.locked`.
// Timer reads state on every fire; any other state invalidates the
// timer so the lock loop can't outlive bedtime.

import Foundation
import AppKit

@MainActor
final class BedtimeLockLoop {
    static let shared = BedtimeLockLoop()

    private var timer: Timer?
    private weak var enforcer: BedtimeEnforcer?
    weak var appDelegate: AppDelegate?

    /// 10-second lock cadence. Fast enough to be uncomfortable, slow
    /// enough to type a 6-digit partner code without re-locking mid-keystroke.
    static let cadence: TimeInterval = 10.0

    var isActive: Bool { timer != nil }

    /// Cached function pointer to `SACLockScreenImmediate`. Loaded once
    /// at first invocation; subsequent ticks reuse it (zero overhead).
    /// nil if dlopen/dlsym failed — we fall back to AppleScript.
    private static var cachedLockFn: (@convention(c) () -> Void)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
            RTLD_NOW
        ) else { return nil }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> Void).self)
    }()

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
        let primitive = Self.cachedLockFn != nil ? "SACLockScreenImmediate" : "AppleScript fallback"
        appDelegate?.postLog("🌙 BedtimeLockLoop: starting (\(Int(Self.cadence))s cadence, \(primitive))")
        invokeLock()

        let t = Timer(timeInterval: Self.cadence, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Tight tolerance — macOS aggressively coalesces low-power timers
        // and can drift by 10%+ otherwise. We want 10s, not 11s+.
        t.tolerance = 0.5
        // .common mode so the timer fires even if a modal panel or
        // tracking-mode UI is up (e.g. menu bar dropdown). Default mode
        // alone gets paused during certain UI operations.
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
        // the screen even after bedtime ended.
        if let enforcer, enforcer.state != .locked {
            stop()
            return
        }
        invokeLock()
    }

    /// Force the macOS lock screen. Always requires password on wake.
    /// Logs to AppDelegate so cadence is verifiable in Console.app.
    private func invokeLock() {
        if let fn = Self.cachedLockFn {
            fn()
            appDelegate?.postLog("🌙 BedtimeLockLoop: tick — locked via SACLockScreenImmediate")
            return
        }

        // Fallback: AppleScript keystroke. Less reliable (depends on
        // Accessibility permission + Lock Screen settings) but better
        // than nothing if dlopen fails on a future macOS.
        let source = """
        tell application "System Events"
            keystroke "q" using {command down, control down}
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            appDelegate?.postLog("🌙 BedtimeLockLoop: tick — failed to build NSAppleScript")
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            appDelegate?.postLog("🌙 BedtimeLockLoop: tick — AppleScript fallback failed: \(error)")
        } else {
            appDelegate?.postLog("🌙 BedtimeLockLoop: tick — locked via AppleScript fallback")
        }
    }
}
