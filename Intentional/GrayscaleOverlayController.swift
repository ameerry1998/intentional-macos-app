import Cocoa

/// Manages screen desaturation as a focus enforcement tool.
///
/// Uses the private `UAGrayscaleSetEnabled` API (UniversalAccess framework) to toggle
/// the macOS Accessibility "Use grayscale" at the compositor level — true system-wide desaturation.
///
/// - `startDesaturation()`: Enables system grayscale
/// - `restoreSaturation()`: Disables system grayscale
/// - `dismiss()`: Same as restoreSaturation
class GrayscaleOverlayController {

    /// Whether we turned on system grayscale (so we only turn it off if we turned it on)
    private var systemGrayscaleEnabled = false

    /// Cached framework handle (opened once, kept alive)
    private var uaHandle: UnsafeMutableRawPointer?
    private var uaSetEnabled: (@convention(c) (Bool) -> Void)?
    private var uaIsEnabled: (@convention(c) () -> Bool)?

    /// Whether the effect is currently active
    var isActive: Bool { systemGrayscaleEnabled }

    init() {
        loadFramework()
    }

    // MARK: - Static Cleanup (safe to call from signal handlers or startup)

    /// Restore saturation without needing an instance. Safe to call from signal handlers or startup.
    static func forceRestoreSaturation() {
        let path = "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess"
        guard let handle = dlopen(path, RTLD_LAZY),
              let sym = dlsym(handle, "UAGrayscaleSetEnabled") else { return }
        let setEnabled = unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
        setEnabled(false)
        NSLog("🌫️ forceRestoreSaturation: grayscale OFF")
    }

    // MARK: - Public API

    /// Enable system grayscale.
    func startDesaturation() {
        guard !systemGrayscaleEnabled else { return }

        // Ensure we have Accessibility permission (needed for UniversalAccess)
        if !AXIsProcessTrusted() {
            NSLog("🌫️ Accessibility permission required for grayscale — prompting user")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }

        // Check if user already has grayscale on (don't claim ownership)
        if let isEnabled = uaIsEnabled, isEnabled() {
            NSLog("🌫️ System grayscale already enabled by user — not taking ownership")
            return
        }

        setSystemGrayscale(true)
    }

    /// Disable system grayscale (if we enabled it).
    func restoreSaturation() {
        guard systemGrayscaleEnabled else { return }
        setSystemGrayscale(false)
    }

    /// Same as restoreSaturation — disable grayscale if we enabled it.
    func dismiss() {
        restoreSaturation()
    }

    // MARK: - UniversalAccess Private Framework

    private func loadFramework() {
        let frameworkPath = "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            NSLog("🌫️ WARNING: Could not load UniversalAccess framework — grayscale unavailable")
            return
        }
        uaHandle = handle

        if let sym = dlsym(handle, "UAGrayscaleSetEnabled") {
            uaSetEnabled = unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
        } else {
            NSLog("🌫️ WARNING: UAGrayscaleSetEnabled not found")
        }

        if let sym = dlsym(handle, "UAGrayscaleIsEnabled") {
            uaIsEnabled = unsafeBitCast(sym, to: (@convention(c) () -> Bool).self)
        } else {
            NSLog("🌫️ WARNING: UAGrayscaleIsEnabled not found")
        }
    }

    private func setSystemGrayscale(_ enabled: Bool) {
        guard let setEnabled = uaSetEnabled else {
            NSLog("🌫️ WARNING: Cannot toggle grayscale — framework not loaded")
            return
        }
        setEnabled(enabled)
        systemGrayscaleEnabled = enabled
        NSLog("🌫️ System grayscale \(enabled ? "ON" : "OFF")")
    }

    deinit {
        dismiss()
        if let handle = uaHandle {
            dlclose(handle)
        }
    }
}
