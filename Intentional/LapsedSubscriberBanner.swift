//
//  LapsedSubscriberBanner.swift
//  Intentional
//
//  Bridges entitlement state changes from EntitlementClient to dashboard.html
//  so the dashboard can show/hide its lapsed-subscriber banner.
//

import Foundation
import AppKit
import Combine

@MainActor
final class LapsedSubscriberBanner {
    weak var mainWindow: MainWindow?
    private var cancellable: AnyCancellable?

    init(mainWindow: MainWindow, entitlementClient: EntitlementClient) {
        self.mainWindow = mainWindow
        // React to entitlement changes — push state to dashboard.
        self.cancellable = entitlementClient.$current.sink { [weak self] ent in
            self?.update(entitlement: ent)
        }
    }

    func update(entitlement: Entitlement?) {
        guard let main = mainWindow else { return }
        let payload: [String: Any] = [
            "tier": entitlement?.tier.rawValue ?? "none",
            "is_hard_lapsed": entitlement?.isHardLapsed ?? false,
            "current_period_ends_at": entitlement?.currentPeriodEndsAt.flatMap { ISO8601DateFormatter().string(from: $0) } as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        main.callJS("window._entitlementState && window._entitlementState(\(json))")
    }
}
