import Foundation
import AppKit

/// Mac-side counterpart to iOS's PartnerSyncService. Fetches /partner/status
/// on launch + NSApplication.didBecomeActiveNotification + 60s timer,
/// writes the result to the dashboard settings JSON (same keys the
/// existing partner UI already reads: partnerEmail, partnerName,
/// consentStatus), and posts Notification.Name.partnerSyncDidUpdate
/// so MainWindow can push the new values into the dashboard via callJS.
///
/// Why this exists: backend `POST /partner` already writes to every
/// sibling user row sharing the same account_id, and `GET /partner/status`
/// falls back to siblings when the calling row is empty. The Mac client
/// only fetched partner status on dashboard navigation to a "pending"
/// consent view, so a Mac that never set the partner locally never
/// learned about a sibling-set partner. This service closes that gap.
///
/// Sync direction is backend -> client only. Setting partner still goes
/// through BackendClient.setPartner which already triggers the
/// sibling-sync write on the backend side.
@MainActor
final class PartnerSyncService {
    static let shared = PartnerSyncService()

    private weak var appDelegate: AppDelegate?
    private weak var backendClient: BackendClient?

    private var pullTimer: Timer?
    private var becameActiveObserver: NSObjectProtocol?
    private var started = false

    private init() {}

    /// Wire the service to its dependencies. Called once from AppDelegate
    /// after BackendClient is constructed.
    func configure(appDelegate: AppDelegate, backendClient: BackendClient) {
        self.appDelegate = appDelegate
        self.backendClient = backendClient
    }

    /// Begin observing app-active and start the 60s poll loop. Idempotent —
    /// extra calls won't double-subscribe or stack timers.
    func start() {
        guard !started else {
            // Still trigger a pull so re-entering "start" yields fresh data.
            Task { await pullAndApply() }
            return
        }
        started = true

        Task { await pullAndApply() }

        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.pullAndApply() }
        }

        pullTimer?.invalidate()
        pullTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { await self?.pullAndApply() }
        }
    }

    /// Stop observers + poll timer. Used in teardown / tests.
    func stop() {
        pullTimer?.invalidate()
        pullTimer = nil
        if let obs = becameActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            becameActiveObserver = nil
        }
        started = false
    }

    /// Public so callers (e.g. an explicit refresh button) can trigger
    /// an immediate fetch outside the 60s cadence.
    func pullAndApply() async {
        guard let backend = backendClient else { return }
        guard let result = await backend.getPartnerStatus() else {
            // BackendClient.getPartnerStatus returns nil on network error;
            // its own implementation already logs via appDelegate.postLog.
            return
        }
        applyToCache(
            email: result.partnerEmail,
            name: result.partnerName,
            consentStatus: result.consentStatus
        )
    }

    private func applyToCache(email: String?, name: String?, consentStatus: String?) {
        let defaults = UserDefaults.standard

        // Mirror to UserDefaults so any code path that reads partner data
        // (legacy bridges, future callers) sees a consistent value.
        if let email, !email.isEmpty {
            defaults.set(email, forKey: "partnerEmail")
        } else {
            defaults.removeObject(forKey: "partnerEmail")
        }
        if let name, !name.isEmpty {
            defaults.set(name, forKey: "partnerName")
        } else {
            defaults.removeObject(forKey: "partnerName")
        }
        if let consentStatus, !consentStatus.isEmpty {
            defaults.set(consentStatus, forKey: "partnerConsentStatus")
        } else {
            defaults.removeObject(forKey: "partnerConsentStatus")
        }

        // Drive MainWindow's WKWebView push + settings JSON update.
        var userInfo: [String: Any] = [:]
        userInfo["partnerEmail"] = email ?? ""
        userInfo["partnerName"] = name ?? ""
        userInfo["partnerConsentStatus"] = consentStatus ?? ""
        NotificationCenter.default.post(
            name: .partnerSyncDidUpdate,
            object: nil,
            userInfo: userInfo
        )

        appDelegate?.postLog(
            "👥 PartnerSync: email=\(email ?? "<nil>"), name=\(name ?? "<nil>"), consent=\(consentStatus ?? "<nil>")"
        )
    }
}

extension Notification.Name {
    /// Posted by PartnerSyncService whenever a /partner/status pull
    /// completes. userInfo contains: partnerEmail, partnerName,
    /// partnerConsentStatus (always present, "" when missing).
    /// MainWindow listens to this and pushes the values into dashboard.html
    /// via WKWebView callJS.
    static let partnerSyncDidUpdate = Notification.Name("partnerSyncDidUpdate")
}
