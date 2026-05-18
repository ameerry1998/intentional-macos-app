import Cocoa
import SwiftUI

/// Stage 1 of the Deep Work Protocol — forced declaration of intent before a
/// focus session starts. Text-only v1 (no voice / transcription yet — that's a
/// follow-up spec).
///
/// Two questions:
///   1. "What are you doing, and what does done look like?"
///   2. "What's allowed in this session — and what's not?"
///
/// The combined answer becomes the `voiceIntent` for the close-the-noise
/// sweep, so Qwen has rich context to score tabs against. If the user clicks
/// Skip (or hits Esc), the sweep falls back to the Intention's saved
/// `intentText` field.
final class StageOneIntentWindowController {
    weak var appDelegate: AppDelegate?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<StageOneAnswer, Never>?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Show the panel and await the user's answer. If the user dismisses
    /// without submitting (Skip / window close), returns `.skipped`.
    @MainActor
    func prompt(suggestedIntent: String) async -> StageOneAnswer {
        dismiss()
        return await withCheckedContinuation { (cont: CheckedContinuation<StageOneAnswer, Never>) in
            self.continuation = cont

            let viewModel = StageOneIntentViewModel(
                suggestedIntent: suggestedIntent,
                onSubmit: { [weak self] doing, allowed in
                    self?.finish(.submitted(doing: doing, allowed: allowed))
                },
                onSkip: { [weak self] in
                    self?.finish(.skipped)
                }
            )

            let host = NSHostingView(rootView: StageOneIntentView(viewModel: viewModel))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Before you start"
            panel.contentView = host
            panel.isReleasedWhenClosed = false
            panel.center()
            panel.level = .floating
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = panel
        }
    }

    private func finish(_ answer: StageOneAnswer) {
        let cont = self.continuation
        self.continuation = nil
        dismiss()
        cont?.resume(returning: answer)
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

enum StageOneAnswer {
    case submitted(doing: String, allowed: String)
    case skipped

    /// Build the combined intent string for the sweep. Returns nil if skipped
    /// or both fields are blank — caller should fall back to a different source.
    var combinedIntent: String? {
        switch self {
        case .skipped:
            return nil
        case .submitted(let doing, let allowed):
            let d = doing.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = allowed.trimmingCharacters(in: .whitespacesAndNewlines)
            if d.isEmpty && a.isEmpty { return nil }
            var parts: [String] = []
            if !d.isEmpty { parts.append("Doing: \(d)") }
            if !a.isEmpty { parts.append("Scope: \(a)") }
            return parts.joined(separator: ". ")
        }
    }
}

final class StageOneIntentViewModel: ObservableObject {
    @Published var doing: String = ""
    @Published var allowed: String = ""
    let suggestedIntent: String
    let onSubmit: (String, String) -> Void
    let onSkip: () -> Void

    init(suggestedIntent: String,
         onSubmit: @escaping (String, String) -> Void,
         onSkip: @escaping () -> Void) {
        self.suggestedIntent = suggestedIntent
        self.onSubmit = onSubmit
        self.onSkip = onSkip
    }
}

struct StageOneIntentView: View {
    @ObservedObject var viewModel: StageOneIntentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Before you start")
                    .font(.system(size: 17, weight: .semibold))
                Text("Two questions. Specific answers help the AI scoring decide what to close.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if !viewModel.suggestedIntent.isEmpty {
                Text("Your goal: \(viewModel.suggestedIntent)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What are you doing, and what does done look like?")
                    .font(.system(size: 12, weight: .medium))
                TextEditor(text: $viewModel.doing)
                    .font(.system(size: 13))
                    .frame(height: 80)
                    .padding(4)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What's allowed in this session — and what's not?")
                    .font(.system(size: 12, weight: .medium))
                TextEditor(text: $viewModel.allowed)
                    .font(.system(size: 13))
                    .frame(height: 80)
                    .padding(4)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                    )
            }

            HStack {
                Button("Skip") { viewModel.onSkip() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Start Session →") {
                    viewModel.onSubmit(viewModel.doing, viewModel.allowed)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}
