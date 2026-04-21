import Cocoa
import SwiftUI

/// Data handed to the overlay for display. Immutable.
struct SwitchOverlayPresentation {
    let taskTitle: String                 // currentBlock.title
    let timeRemainingInSession: String    // e.g. "38 min left"
    let targetDisplayName: String         // "Safari" or "youtube.com — Home"
    let countdownSeconds: Int
}

/// Callbacks the controller invokes based on user action.
protocol SwitchOverlayDelegate: AnyObject {
    func switchOverlayDidTapBackToWork()
    func switchOverlayDidTapContinue()
}

final class SwitchOverlayViewModel: ObservableObject {
    let presentation: SwitchOverlayPresentation
    @Published var secondsRemaining: Int
    @Published var continueEnabled: Bool = false
    weak var delegate: SwitchOverlayDelegate?
    private var timer: Timer?

    init(presentation: SwitchOverlayPresentation) {
        self.presentation = presentation
        self.secondsRemaining = presentation.countdownSeconds
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.secondsRemaining > 0 {
                self.secondsRemaining -= 1
            }
            if self.secondsRemaining <= 0 {
                self.continueEnabled = true
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    func backToWork() { delegate?.switchOverlayDidTapBackToWork() }

    func continueToTarget() {
        guard continueEnabled else { return }
        delegate?.switchOverlayDidTapContinue()
    }

    deinit { timer?.invalidate() }
}
