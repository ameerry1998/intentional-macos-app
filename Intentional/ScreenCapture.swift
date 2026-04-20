import ScreenCaptureKit
import AppKit

actor ScreenCapture {

    func captureFrontmostWindow() async throws -> (image: CGImage, pid: pid_t)? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let frontPID = frontApp.processIdentifier

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        guard let win = content.windows.first(where: {
            $0.owningApplication?.processID == frontPID &&
            $0.isOnScreen &&
            $0.windowLayer == 0
        }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(win.frame.width * 2)
        cfg.height = Int(win.frame.height * 2)
        cfg.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return (image: image, pid: frontPID)
    }
}
