import Cocoa
import SwiftUI

/// Review-and-confirm modal for the close-the-noise sweep.
///
/// Pivot from auto-stash (shipped 2026-05-18) to user-confirms-first per
/// CLAUDE.md "Hard-Won Lessons" #1: for the ADHD ICP, agency > automation.
/// The AI pre-classifies tabs into three buckets (probably-keep,
/// borderline, probably-close); the user reviews, adjusts, and clicks
/// the button that actually closes things. Cancel keeps everything.
///
/// Defaults bias toward closing — borderline + probably-close items are
/// pre-checked. User opts IN to keep by unchecking.

enum SweepReviewBucket: String {
    case probablyKeep    // AI: relevant=true, high confidence
    case borderline      // AI: middle confidence, either side
    case probablyClose   // AI: relevant=false, high confidence
}

enum SweepReviewItemKind: Equatable {
    case browserTab(originalURL: String, originalWindow: Int, originalIndex: Int, browserBundleId: String)
    case nativeApp(bundleId: String)
}

struct SweepReviewItem: Identifiable {
    let id: String        // tab URL or bundle ID — used to map back to the action
    let title: String
    let subtitle: String  // URL for tabs, bundleId for apps
    let kind: SweepReviewItemKind
    let bucket: SweepReviewBucket
    let aiConfidence: Int
}

/// Returned to the caller after the user clicks. Contains only the items
/// the user CHOSE to close — not what the AI suggested.
struct SweepReviewResult {
    let confirmedCloseTabs: [SweepReviewItem]
    let confirmedHideApps: [SweepReviewItem]
    let cancelled: Bool
    let autoCloseNextTime: Bool
}

final class SweepReviewWindowController {
    weak var appDelegate: AppDelegate?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<SweepReviewResult, Never>?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    @MainActor
    func present(items: [SweepReviewItem], intent: String) async -> SweepReviewResult {
        dismiss()
        return await withCheckedContinuation { (cont: CheckedContinuation<SweepReviewResult, Never>) in
            self.continuation = cont

            let viewModel = SweepReviewViewModel(
                items: items,
                intent: intent,
                onConfirm: { [weak self] toClose, autoCloseNextTime in
                    self?.finish(SweepReviewResult(
                        confirmedCloseTabs: toClose.filter {
                            if case .browserTab = $0.kind { return true } else { return false }
                        },
                        confirmedHideApps: toClose.filter {
                            if case .nativeApp = $0.kind { return true } else { return false }
                        },
                        cancelled: false,
                        autoCloseNextTime: autoCloseNextTime
                    ))
                },
                onCancel: { [weak self] in
                    self?.finish(SweepReviewResult(
                        confirmedCloseTabs: [], confirmedHideApps: [],
                        cancelled: true, autoCloseNextTime: false
                    ))
                }
            )

            let host = NSHostingView(rootView: SweepReviewView(viewModel: viewModel))
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Before you focus — what stays open?"
            panel.contentView = host
            panel.isReleasedWhenClosed = false
            panel.center()
            panel.level = .floating
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = panel
        }
    }

    private func finish(_ result: SweepReviewResult) {
        let cont = self.continuation
        self.continuation = nil
        dismiss()
        cont?.resume(returning: result)
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

final class SweepReviewViewModel: ObservableObject {
    let intent: String
    let items: [SweepReviewItem]

    // Bucketed views (computed once).
    let probablyKeep: [SweepReviewItem]
    let borderline: [SweepReviewItem]
    let probablyClose: [SweepReviewItem]
    let apps: [SweepReviewItem]

    /// Keyed by SweepReviewItem.id. True = will be closed when the user
    /// hits the confirm button. Defaults bias toward closing for
    /// borderline + probablyClose; probablyKeep defaults to false (keep).
    @Published var willClose: [String: Bool] = [:]
    @Published var collapseKeep: Bool = false
    @Published var collapseBorderline: Bool = false
    @Published var collapseClose: Bool = false
    @Published var collapseApps: Bool = false
    @Published var autoCloseNextTime: Bool = false

    let onConfirm: ([SweepReviewItem], Bool) -> Void
    let onCancel: () -> Void

    init(items: [SweepReviewItem],
         intent: String,
         onConfirm: @escaping ([SweepReviewItem], Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.items = items
        self.intent = intent
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        // Bucket once.
        var pk: [SweepReviewItem] = []
        var bd: [SweepReviewItem] = []
        var pc: [SweepReviewItem] = []
        var ap: [SweepReviewItem] = []
        for item in items {
            if case .nativeApp = item.kind {
                ap.append(item)
                continue
            }
            switch item.bucket {
            case .probablyKeep:  pk.append(item)
            case .borderline:    bd.append(item)
            case .probablyClose: pc.append(item)
            }
        }
        self.probablyKeep = pk.sorted { $0.aiConfidence > $1.aiConfidence }
        self.borderline = bd
        self.probablyClose = pc.sorted { $0.aiConfidence > $1.aiConfidence }
        self.apps = ap

        // Defaults per spec: probablyClose + borderline + apps pre-checked
        // (will close); probablyKeep pre-unchecked (will keep).
        var defaults: [String: Bool] = [:]
        for item in items {
            if case .nativeApp = item.kind {
                defaults[item.id] = true
                continue
            }
            switch item.bucket {
            case .probablyKeep:  defaults[item.id] = false
            case .borderline:    defaults[item.id] = true
            case .probablyClose: defaults[item.id] = true
            }
        }
        self.willClose = defaults
    }

    var countToClose: Int {
        willClose.values.filter { $0 }.count
    }

    func toggle(_ id: String) {
        willClose[id] = !(willClose[id] ?? false)
    }

    func setAll(_ ids: [String], to value: Bool) {
        for id in ids { willClose[id] = value }
    }

    func itemsToClose() -> [SweepReviewItem] {
        return items.filter { willClose[$0.id] == true }
    }
}

struct SweepReviewView: View {
    @ObservedObject var viewModel: SweepReviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Before you focus — what stays open?")
                    .font(.system(size: 16, weight: .semibold))
                Text(viewModel.intent.isEmpty ? "No session intent set" : "Goal: \(viewModel.intent.prefix(160))")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            Divider()

            // Body
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section(
                        title: "Probably close",
                        subtitle: "AI flagged as off-task",
                        items: viewModel.probablyClose,
                        collapsed: $viewModel.collapseClose,
                        bucketColor: .red.opacity(0.6)
                    )
                    section(
                        title: "Borderline — your call",
                        subtitle: "AI wasn't sure",
                        items: viewModel.borderline,
                        collapsed: $viewModel.collapseBorderline,
                        bucketColor: .orange.opacity(0.6)
                    )
                    section(
                        title: "Probably keep",
                        subtitle: "AI thinks these match your goal",
                        items: viewModel.probablyKeep,
                        collapsed: $viewModel.collapseKeep,
                        bucketColor: .green.opacity(0.6)
                    )
                    if !viewModel.apps.isEmpty {
                        section(
                            title: "Apps to hide (Cmd+H)",
                            subtitle: "Hidden, not quit. Cmd+Tab brings them back.",
                            items: viewModel.apps,
                            collapsed: $viewModel.collapseApps,
                            bucketColor: .gray.opacity(0.6)
                        )
                    }
                }
                .padding(.horizontal, 0)
            }

            Divider()

            // Footer
            HStack {
                Toggle("Skip this review next time — trust AI", isOn: $viewModel.autoCloseNextTime)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("After this run, future sweeps will close tabs automatically without asking. Change in Settings if you want it back.")
                Spacer()
                Button("Cancel — keep everything") { viewModel.onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(viewModel.countToClose == 0
                       ? "Start session"
                       : "Close \(viewModel.countToClose) item\(viewModel.countToClose == 1 ? "" : "s") → Start") {
                    viewModel.onConfirm(viewModel.itemsToClose(), viewModel.autoCloseNextTime)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 640, height: 640)
    }

    @ViewBuilder
    private func section(title: String,
                         subtitle: String,
                         items: [SweepReviewItem],
                         collapsed: Binding<Bool>,
                         bucketColor: Color) -> some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Section header with collapse + bulk actions.
                HStack(spacing: 8) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Circle().fill(bucketColor).frame(width: 8, height: 8)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text("(\(items.count))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !collapsed.wrappedValue {
                        Button("Check all") {
                            viewModel.setAll(items.map { $0.id }, to: true)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        Button("Uncheck all") {
                            viewModel.setAll(items.map { $0.id }, to: false)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture { collapsed.wrappedValue.toggle() }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20).padding(.bottom, 6)
                }

                if !collapsed.wrappedValue {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SweepReviewItem) -> some View {
        let checked = viewModel.willClose[item.id] ?? false
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { viewModel.willClose[item.id] ?? false },
                set: { _ in viewModel.toggle(item.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? item.subtitle : item.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .strikethrough(checked, color: .secondary)
                    .foregroundColor(checked ? .secondary : .primary)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.aiConfidence > 0 {
                Text("\(item.aiConfidence)%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.toggle(item.id) }
    }
}
