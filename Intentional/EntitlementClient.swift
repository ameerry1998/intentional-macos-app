//
//  EntitlementClient.swift
//  Intentional
//
//  Manages subscription state. Backend is canonical; local cache for offline resilience.
//  Polls on launch + foreground + 60s timer.
//

import Foundation
import AppKit

@MainActor
final class EntitlementClient: ObservableObject {
    @Published private(set) var current: Entitlement?

    private let backendClient: BackendClient
    private let cacheURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Intentional/entitlement_cache.json")
    }()

    private var timer: Timer?
    private var foregroundObserver: NSObjectProtocol?

    init(backendClient: BackendClient) {
        self.backendClient = backendClient
        loadCache()
    }

    deinit {
        timer?.invalidate()
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Call once at app launch.
    func start() {
        Task { await self.refresh() }

        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        t.tolerance = 5.0
        RunLoop.main.add(t, forMode: .common)
        timer = t

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard let fresh = await backendClient.getEntitlements() else {
            // Network failed — keep cached value
            return
        }
        current = fresh
        saveCache(fresh)
    }

    private func loadCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? decoder.decode(Entitlement.self, from: data) else {
            return
        }
        current = decoded
    }

    private func saveCache(_ ent: Entitlement) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(ent) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
