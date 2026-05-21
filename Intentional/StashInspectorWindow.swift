import Cocoa
import SwiftUI

/// Small floating NSPanel that lists a session's stashed tabs + hidden apps
/// with per-row Restore buttons. Opened from the close-the-noise toast's
/// [View stash] button or from Settings → Stash History.
final class StashInspectorWindowController {
    weak var appDelegate: AppDelegate?
    private var window: NSWindow?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    func show(stash: SessionStash) {
        dismiss()
        let viewModel = StashInspectorViewModel(
            stash: stash,
            onClose: { [weak self] in self?.dismiss() },
            onRestoreTab: { [weak self] tab in
                self?.appDelegate?.restoreSingleTab(tab, fromSession: stash.sessionId)
            },
            onRestoreApp: { [weak self] bundleId in
                self?.appDelegate?.restoreSingleApp(bundleId: bundleId, fromSession: stash.sessionId)
            }
        )

        let host = NSHostingView(rootView: StashInspectorView(viewModel: viewModel))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Session Stash"
        panel.contentView = host
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

final class StashInspectorViewModel: ObservableObject {
    @Published var stash: SessionStash
    let onClose: () -> Void
    let onRestoreTab: (StashedTab) -> Void
    let onRestoreApp: (String) -> Void

    init(stash: SessionStash,
         onClose: @escaping () -> Void,
         onRestoreTab: @escaping (StashedTab) -> Void,
         onRestoreApp: @escaping (String) -> Void) {
        self.stash = stash
        self.onClose = onClose
        self.onRestoreTab = onRestoreTab
        self.onRestoreApp = onRestoreApp
    }
}

struct StashInspectorView: View {
    @ObservedObject var viewModel: StashInspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Session Stash")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 4)
            Text("Stashed at \(viewModel.stash.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 14)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !viewModel.stash.stashedTabs.isEmpty {
                        sectionHeader("Tabs (\(viewModel.stash.stashedTabs.count))")
                        ForEach(viewModel.stash.stashedTabs, id: \.url) { tab in
                            row(title: tab.title.isEmpty ? tab.url : tab.title,
                                subtitle: tab.url) {
                                viewModel.onRestoreTab(tab)
                            }
                        }
                    }
                    if !viewModel.stash.hiddenBundleIds.isEmpty {
                        sectionHeader("Apps (\(viewModel.stash.hiddenBundleIds.count))")
                        ForEach(viewModel.stash.hiddenBundleIds, id: \.self) { bid in
                            row(title: bid, subtitle: "hidden via Cmd+H") {
                                viewModel.onRestoreApp(bid)
                            }
                        }
                    }
                    if viewModel.stash.stashedTabs.isEmpty && viewModel.stash.hiddenBundleIds.isEmpty {
                        Text("Nothing in this stash.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(title: String, subtitle: String, restore: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Restore", action: restore).controlSize(.small)
        }
        .padding(.horizontal, 18).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
