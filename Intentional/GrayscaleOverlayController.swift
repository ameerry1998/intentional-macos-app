import Cocoa
import QuartzCore

/// Manages screen red shift + atmospheric vignette as a focus enforcement tool.
///
/// **Gamma Red Shift** — `CGSetDisplayTransferByTable` reduces green/blue channels,
/// giving the entire screen a red/warm tint. Public API, no notification, smooth animation.
///
/// **Atmospheric Vignette** — Full-screen click-through NSWindow with a radial gradient
/// overlay. Ultra-soft warm orange-red from edges, max opacity 0.20. Creates a subtle
/// "warmth closing in" feel that complements the gamma red shift.
///
/// Previous failed grayscale approaches (kept as comments, NEVER delete):
/// - CGDisplayForceToGray — NO-OP on macOS 15
/// - CABackdropLayer + CAFilter("colorSaturate") — zero visual effect on macOS 15
/// - CABackdropLayer + CIFilter — zero visual effect
/// - Gamma tables for grayscale — GREEN or FOGGY (per-channel can't mix)
/// - CGSNewCIFilterByName — error 1006 / crash
/// - CIFilter backgroundFilters — no visual effect on macOS 15
/// - UAGrayscaleSetEnabled — works but shows notification (kept as fallback)
/// - Damage vignette overlay — too aggressive combined with red shift (kept as comment)
/// - Vignette A/B/C variants — tested Gentle Radial, Edge Bars, Corner Bloom; Atmospheric won
///
/// NEVER delete ANY commented-out approach. They are preserved for reference.
class GrayscaleOverlayController {

    // MARK: - Configuration

    /// How much green/blue channels are reduced at max intensity (gamma shift)
    /// 0.0 = fully removed, 1.0 = untouched. Lower = more red/sickly.
    private static let greenFloor: CGGammaValue = 0.45
    private static let blueFloor: CGGammaValue = 0.35

    /// Gamma table resolution
    private static let tableSize: Int = 256

    // MARK: - Animation Config

    /// Duration to reach full red shift (seconds)
    private let desaturationDuration: TimeInterval = 30.0

    /// Duration to restore normal (seconds)
    private let restoreDuration: TimeInterval = 3.0

    /// Animation tick interval (~60fps)
    private let animationInterval: TimeInterval = 1.0 / 60.0

    // MARK: - UAGrayscale Fallback (kept available)

    private static let uaHandle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess"
        return dlopen(path, RTLD_LAZY)
    }()

    private static let uaSetEnabled: (@convention(c) (Bool) -> Void)? = {
        guard let h = uaHandle, let sym = dlsym(h, "UAGrayscaleSetEnabled") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Bool) -> Void).self)
    }()

    // MARK: - Instance State

    /// Current effect intensity: 0.0 = normal, 1.0 = full red shift
    private var currentIntensity: CGGammaValue = 0.0

    /// Animation timer
    private var animationTimer: Timer?

    /// Whether the effect is active
    private var grayscaleEnabled = false

    /// Full-screen click-through window for vignette overlay
    private var vignetteWindow: NSWindow?

    /// The gradient layer rendering the atmospheric vignette
    private var vignetteLayer: CAGradientLayer?

    // MARK: - Public Properties

    var isActive: Bool { grayscaleEnabled }

    init() {
        NSLog("🌫️ [INIT] GrayscaleOverlayController created — red shift mode")
    }

    // MARK: - Static Cleanup

    static func forceRestoreSaturation() {
        NSLog("🌫️ [FORCE] forceRestoreSaturation called")
        uaSetEnabled?(false)
        CGDisplayRestoreColorSyncSettings()
        NSLog("🌫️ [FORCE] ✅ All restored")
    }

    // MARK: - Public API

    /// Begin red shift + atmospheric vignette over 30 seconds.
    func startDesaturation() {
        NSLog("🌫️ [START] startDesaturation() — isActive=\(isActive), intensity=\(currentIntensity)")

        guard !grayscaleEnabled else {
            NSLog("🌫️ [START] ⚠️ Already active, skipping")
            return
        }

        grayscaleEnabled = true
        setupVignetteWindow()
        setupVignette()
        animateIntensity(to: 1.0, duration: desaturationDuration)
        NSLog("🌫️ [START] ✅ Starting \(desaturationDuration)s red shift + atmospheric vignette")
    }

    /// Restore normal over 3 seconds.
    func restoreSaturation() {
        NSLog("🌫️ [RESTORE] restoreSaturation() — isActive=\(isActive), intensity=\(currentIntensity)")

        guard grayscaleEnabled else {
            NSLog("🌫️ [RESTORE] ⚠️ Not active, nothing to restore")
            return
        }

        animateIntensity(to: 0.0, duration: restoreDuration) { [weak self] in
            self?.grayscaleEnabled = false
            self?.teardownVignette()
            CGDisplayRestoreColorSyncSettings()
            NSLog("🌫️ [RESTORE] ✅ Fully restored")
        }
    }

    func dismiss() {
        NSLog("🌫️ [DISMISS] dismiss() — isActive=\(isActive)")
        restoreSaturation()
    }

    // MARK: - Vignette Window

    private func setupVignetteWindow() {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostView = NSView(frame: screen.frame)
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostView

        window.orderFrontRegardless()
        vignetteWindow = window
        NSLog("🌫️ [VIGNETTE] Window created \(Int(screen.frame.width))x\(Int(screen.frame.height))")
    }

    private func teardownVignette() {
        vignetteLayer = nil
        vignetteWindow?.orderOut(nil)
        vignetteWindow = nil
        NSLog("🌫️ [VIGNETTE] Torn down")
    }

    // MARK: - Atmospheric Vignette

    private func setupVignette() {
        guard let layer = vignetteWindow?.contentView?.layer,
              let frame = vignetteWindow?.frame else { return }

        let grad = CAGradientLayer()
        grad.type = .radial
        grad.frame = CGRect(origin: .zero, size: frame.size)
        grad.startPoint = CGPoint(x: 0.5, y: 0.5)
        grad.endPoint = CGPoint(x: 1.0, y: 1.0)
        // Warm orange-red tones, very low opacity
        grad.colors = [
            NSColor(red: 1.0, green: 0.35, blue: 0.1, alpha: 0.0).cgColor,
            NSColor(red: 1.0, green: 0.3, blue: 0.08, alpha: 0.0).cgColor,
            NSColor(red: 0.95, green: 0.25, blue: 0.05, alpha: 0.05).cgColor,
            NSColor(red: 0.9, green: 0.2, blue: 0.05, alpha: 0.12).cgColor,
            NSColor(red: 0.85, green: 0.15, blue: 0.05, alpha: 0.20).cgColor,
        ]
        // Barely perceptible start, wide coverage
        grad.locations = [0.0, 0.25, 0.45, 0.7, 1.0]
        grad.opacity = 0.0

        layer.addSublayer(grad)
        vignetteLayer = grad
        NSLog("🌫️ [VIGNETTE] Atmospheric setup — warm orange-red, max 0.20")
    }

    /// Update vignette layer opacity to match current intensity.
    private func applyVignette(_ intensity: CGGammaValue) {
        vignetteLayer?.opacity = Float(intensity)
    }

    deinit {
        animationTimer?.invalidate()
        if grayscaleEnabled {
            teardownVignette()
            CGDisplayRestoreColorSyncSettings()
            NSLog("🌫️ [DEINIT] Force-restored")
        }
    }

    // MARK: - Apply Red Shift

    /// Apply gamma red shift to all displays.
    private func applyRedShift(_ intensity: CGGammaValue) {
        let tableSize = Self.tableSize
        let t = intensity

        let gGain: CGGammaValue = 1.0 - t * (1.0 - Self.greenFloor)
        let bGain: CGGammaValue = 1.0 - t * (1.0 - Self.blueFloor)

        var redTable = [CGGammaValue](repeating: 0, count: tableSize)
        var greenTable = [CGGammaValue](repeating: 0, count: tableSize)
        var blueTable = [CGGammaValue](repeating: 0, count: tableSize)

        for i in 0..<tableSize {
            let v = CGGammaValue(i) / CGGammaValue(tableSize - 1)
            redTable[i]   = v
            greenTable[i] = v * gGain
            blueTable[i]  = v * bGain
        }

        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        for display in displays {
            CGSetDisplayTransferByTable(display, UInt32(tableSize), &redTable, &greenTable, &blueTable)
        }
    }

    // MARK: - Animation

    private func animateIntensity(to target: CGGammaValue, duration: TimeInterval, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()
        animationTimer = nil

        let start = currentIntensity
        let delta = target - start

        if abs(delta) < 0.001 {
            completion?()
            return
        }

        let startTime = CACurrentMediaTime()
        let totalSteps = Int(duration / animationInterval)
        var stepCount = 0

        NSLog("🌫️ [ANIM] Intensity \(String(format: "%.2f", start)) → \(String(format: "%.2f", target)) over \(duration)s")

        animationTimer = Timer.scheduledTimer(withTimeInterval: animationInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(CGGammaValue(elapsed / duration), 1.0)

            let eased = progress < 0.5
                ? 2.0 * progress * progress
                : 1.0 - pow(-2.0 * progress + 2.0, 2) / 2.0

            let newIntensity = start + delta * eased
            self.currentIntensity = newIntensity
            self.applyRedShift(newIntensity)
            self.applyVignette(newIntensity)

            stepCount += 1

            let logInterval = max(totalSteps / max(Int(duration / 5.0), 1), 1)
            if stepCount % logInterval == 0 || progress >= 1.0 {
                NSLog("🌫️ [ANIM] intensity=\(String(format: "%.3f", newIntensity)) progress=\(String(format: "%.1f%%", progress * 100))")
            }

            if progress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.currentIntensity = target
                self.applyRedShift(target)
                self.applyVignette(target)
                NSLog("🌫️ [ANIM] ✅ Complete — intensity=\(String(format: "%.2f", target))")
                completion?()
            }
        }
    }
}

// MARK: - Failed: Damage Vignette Overlay (too aggressive with red shift)
//
// Full-screen transparent click-through NSWindow with CAGradientLayer radial type.
// Transparent center → deep red edges that creep inward as intensity increases.
// Combined with gamma red shift it was too aggressive visually.
//
// ---- DAMAGE VIGNETTE IMPLEMENTATION START ----
// NSWindow(level: .screenSaver, ignoresMouseEvents: true, backgroundColor: .clear)
// CAGradientLayer(type: .radial, startPoint: center, endPoint: corner)
// Colors: clear → dark red (0.6,0,0,0) → (0.5,0,0,0.7) → (0.3,0,0,1.0)
// Locations shift inward with intensity: [0,0.6,0.8,1.0] → [0,0.3,0.5,0.75]
// Max opacity: 0.85, max encroachment: 0.3
// ---- DAMAGE VIGNETTE IMPLEMENTATION END ----

// MARK: - Fallback: UAGrayscaleSetEnabled (true grayscale, shows notification)
//
// The ONLY approach that produces true grayscale on macOS 15 Sequoia.
// Triggers "Color Filter On/Off" notification — no way to suppress it.
// Currently kept loaded for forceRestoreSaturation() cleanup.
//
// ---- UAGRAYSCALE IMPLEMENTATION START ----
//
// uaSetEnabled(true)  → true grayscale ON (notification)
// uaSetEnabled(false) → grayscale OFF (notification)
//
// ---- UAGRAYSCALE IMPLEMENTATION END ----

// MARK: - Failed: CGDisplayForceToGray (NO-OP on macOS 15)
//
// Symbol exists but is a no-op on macOS 15 Sequoia.
//
// ---- CGDISPLAYFORCETOGRAY IMPLEMENTATION START ----
// dlsym(handle, "CGDisplayForceToGray") → found, forceToGray(true) = no visual effect
// ---- CGDISPLAYFORCETOGRAY IMPLEMENTATION END ----

// MARK: - Failed: CABackdropLayer + CAFilter("colorSaturate") (no visual effect)
//
// Full window server config. Setup succeeded. Animation ran. Zero visual change on macOS 15.
//
// ---- CABACKDROPLAYER CAFILTER IMPLEMENTATION START ----
// CAFilter(type: "colorSaturate"), shouldAutoFlattenLayerTree=false,
// canHostLayersInWindowServer toggled, windowServerAware=true,
// allowsGroupBlending=true, CGSSetWindowTags(0x800). Zero effect.
// ---- CABACKDROPLAYER CAFILTER IMPLEMENTATION END ----

// MARK: - Failed: CABackdropLayer + CIFilter (no visual effect)
//
// ---- CABACKDROPLAYER CIFILTER IMPLEMENTATION START ----
// CIFilter("CIColorControls") on CABackdropLayer.filters — no visual change.
// ---- CABACKDROPLAYER CIFILTER IMPLEMENTATION END ----

// MARK: - Failed: Gamma tables for grayscale — GREEN or FOGGY
//
// BT.709 weights: green screen. Identical ramps: foggy white.
// Per-channel LUTs can't do cross-channel mixing for grayscale.
// BUT they ARE used successfully here for the red shift component.
//
// ---- GAMMA GRAYSCALE IMPLEMENTATION START ----
// BT.709: redTable[i]=v*0.2126, greenTable[i]=v*0.7152 → GREEN
// Mid-gray: table[i] = v*s + 0.5*(1-s) → FOGGY WHITE
// ---- GAMMA GRAYSCALE IMPLEMENTATION END ----

// MARK: - Failed: CGSNewCIFilterByName (error 1006 / crash)
//
// 3-param: error 1006. 4-param: EXC_BAD_ACCESS (wrong signature).
//
// ---- CGS FILTER IMPLEMENTATION START ----
// CGSNewCIFilterByName(cid, "CIColorControls", &fid) → 1006
// CGSNewCIFilterByName(cid, 0, "CIColorControls", &fid) → EXC_BAD_ACCESS
// ---- CGS FILTER IMPLEMENTATION END ----

// MARK: - Failed: CIFilter backgroundFilters (no visual effect)
//
// macOS compositor ignores backgroundFilters on macOS 15.
//
// ---- CIFILTER BACKGROUNDFILTERS IMPLEMENTATION START ----
// contentView.layer?.backgroundFilters = [CIFilter(name: "CIColorControls")]
// No visual change.
// ---- CIFILTER BACKGROUNDFILTERS IMPLEMENTATION END ----
