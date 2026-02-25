import Cocoa
import QuartzCore

/// Manages screen desaturation as a focus enforcement tool.
///
/// Uses a transparent fullscreen NSWindow with a CIColorControls backgroundFilter
/// to desaturate everything visible behind the window. This avoids the system
/// "Color Filter On/Off" notification triggered by the old UAGrayscale approach.
///
/// - `startDesaturation()`: Shows the overlay window with saturation=0
/// - `restoreSaturation()`: Closes the overlay window
/// - `dismiss()`: Same as restoreSaturation
///
/// **Fallback note**: If `backgroundFilters` doesn't work on a particular macOS version,
/// uncomment the old UAGrayscale code below and comment out the CIFilter approach.
class GrayscaleOverlayController {

    /// The transparent overlay window that applies the desaturation filter
    private var overlayWindow: NSWindow?

    /// Static reference for forceRestoreSaturation (called from SIGTERM handler and startup)
    private static var sharedOverlayWindow: NSWindow?

    /// Whether the effect is currently active
    var isActive: Bool { overlayWindow != nil }

    init() {}

    // MARK: - Static Cleanup (safe to call from signal handlers or startup)

    /// Restore saturation without needing an instance. Safe to call from signal handlers or startup.
    static func forceRestoreSaturation() {
        // Close the CIFilter overlay window if it exists
        if let window = sharedOverlayWindow {
            window.orderOut(nil)
            sharedOverlayWindow = nil
            NSLog("🌫️ forceRestoreSaturation: overlay window closed")
        }

        // Also restore UAGrayscale in case it was left on by a previous version
        let path = "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess"
        if let handle = dlopen(path, RTLD_LAZY),
           let sym = dlsym(handle, "UAGrayscaleSetEnabled") {
            let setEnabled = unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
            setEnabled(false)
            NSLog("🌫️ forceRestoreSaturation: UAGrayscale OFF (legacy cleanup)")
        }
    }

    // MARK: - Public API

    /// Enable screen desaturation via CIFilter overlay window.
    func startDesaturation() {
        guard overlayWindow == nil else { return }

        // Create overlay window covering all screens
        let screenFrame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }

        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false

        // Set up the content view with a CIColorControls backgroundFilter (saturation = 0)
        let contentView = NSView(frame: screenFrame)
        contentView.wantsLayer = true
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setDefaults()
            filter.setValue(0.0, forKey: "inputSaturation")
            contentView.layer?.backgroundFilters = [filter]
        } else {
            NSLog("🌫️ WARNING: CIColorControls filter not available")
        }

        window.contentView = contentView
        window.orderFrontRegardless()

        overlayWindow = window
        GrayscaleOverlayController.sharedOverlayWindow = window
        NSLog("🌫️ Grayscale overlay ON (CIFilter)")
    }

    /// Disable screen desaturation (close the overlay window).
    func restoreSaturation() {
        guard let window = overlayWindow else { return }
        window.orderOut(nil)
        overlayWindow = nil
        GrayscaleOverlayController.sharedOverlayWindow = nil
        NSLog("🌫️ Grayscale overlay OFF")
    }

    /// Same as restoreSaturation — close the overlay if active.
    func dismiss() {
        restoreSaturation()
    }

    deinit {
        dismiss()
    }
}

// MARK: - Old UAGrayscale Implementation (commented out)
//
// The code below uses the private UAGrayscaleSetEnabled API from the UniversalAccess
// framework. This works but triggers the macOS "Color Filter On/Off" system notification.
// Kept here as a fallback in case the CIFilter backgroundFilters approach doesn't work
// on a particular macOS version.
//
// To revert: uncomment the code below, comment out the CIFilter implementation above,
// and restore the old class body.
//
// ---- OLD IMPLEMENTATION START ----
//
// class GrayscaleOverlayController {
//
//     /// Whether we turned on system grayscale (so we only turn it off if we turned it on)
//     private var systemGrayscaleEnabled = false
//
//     /// Cached framework handle (opened once, kept alive)
//     private var uaHandle: UnsafeMutableRawPointer?
//     private var uaSetEnabled: (@convention(c) (Bool) -> Void)?
//     private var uaIsEnabled: (@convention(c) () -> Bool)?
//
//     /// Whether the effect is currently active
//     var isActive: Bool { systemGrayscaleEnabled }
//
//     init() {
//         loadFramework()
//     }
//
//     // MARK: - Static Cleanup (safe to call from signal handlers or startup)
//
//     /// Restore saturation without needing an instance. Safe to call from signal handlers or startup.
//     static func forceRestoreSaturation() {
//         let path = "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess"
//         guard let handle = dlopen(path, RTLD_LAZY),
//               let sym = dlsym(handle, "UAGrayscaleSetEnabled") else { return }
//         let setEnabled = unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
//         setEnabled(false)
//         NSLog("🌫️ forceRestoreSaturation: grayscale OFF")
//     }
//
//     // MARK: - Public API
//
//     /// Enable system grayscale.
//     func startDesaturation() {
//         guard !systemGrayscaleEnabled else { return }
//
//         // Ensure we have Accessibility permission (needed for UniversalAccess)
//         if !AXIsProcessTrusted() {
//             NSLog("🌫️ Accessibility permission required for grayscale — prompting user")
//             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
//             AXIsProcessTrustedWithOptions(options)
//             return
//         }
//
//         // Check if user already has grayscale on (don't claim ownership)
//         if let isEnabled = uaIsEnabled, isEnabled() {
//             NSLog("🌫️ System grayscale already enabled by user — not taking ownership")
//             return
//         }
//
//         setSystemGrayscale(true)
//     }
//
//     /// Disable system grayscale (if we enabled it).
//     func restoreSaturation() {
//         guard systemGrayscaleEnabled else { return }
//         setSystemGrayscale(false)
//     }
//
//     /// Same as restoreSaturation — disable grayscale if we enabled it.
//     func dismiss() {
//         restoreSaturation()
//     }
//
//     // MARK: - UniversalAccess Private Framework
//
//     private func loadFramework() {
//         let frameworkPath = "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess"
//         guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
//             NSLog("🌫️ WARNING: Could not load UniversalAccess framework — grayscale unavailable")
//             return
//         }
//         uaHandle = handle
//
//         if let sym = dlsym(handle, "UAGrayscaleSetEnabled") {
//             uaSetEnabled = unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
//         } else {
//             NSLog("🌫️ WARNING: UAGrayscaleSetEnabled not found")
//         }
//
//         if let sym = dlsym(handle, "UAGrayscaleIsEnabled") {
//             uaIsEnabled = unsafeBitCast(sym, to: (@convention(c) () -> Bool).self)
//         } else {
//             NSLog("🌫️ WARNING: UAGrayscaleIsEnabled not found")
//         }
//     }
//
//     private func setSystemGrayscale(_ enabled: Bool) {
//         guard let setEnabled = uaSetEnabled else {
//             NSLog("🌫️ WARNING: Cannot toggle grayscale — framework not loaded")
//             return
//         }
//         setEnabled(enabled)
//         systemGrayscaleEnabled = enabled
//         NSLog("🌫️ System grayscale \(enabled ? "ON" : "OFF")")
//     }
//
//     deinit {
//         dismiss()
//         if let handle = uaHandle {
//             dlclose(handle)
//         }
//     }
// }
//
// ---- OLD IMPLEMENTATION END ----
