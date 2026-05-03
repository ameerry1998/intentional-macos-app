import Foundation
import AppKit

/// Pulls bedtime config from the backend, caches it to disk, and feeds the
/// active config to BedtimeEnforcer. Also performs the one-time migration
/// of legacy `bedtime_settings.json` -> backend on first run.
///
/// Cache file: ~/Library/Application Support/Intentional/bedtime_settings.json
/// (same path as the legacy local-only format; the existing file IS the cache.
/// On first run we read it as the "legacy snapshot", push to backend, then
/// from then on overwrite it with backend-pulled DTO encoded as
/// BackendClient.BedtimeConfigDTO. Reads attempt both formats.)
final class BedtimeConfigSync {
    weak var appDelegate: AppDelegate?
    weak var enforcer: BedtimeEnforcer?
    private let backendClient: BackendClient

    private var pullTimer: Timer?
    private var becameActiveObserver: NSObjectProtocol?
    private let migrationFlagKey = "bedtime_legacy_migrated_v1"

    init(appDelegate: AppDelegate, enforcer: BedtimeEnforcer, backendClient: BackendClient) {
        self.appDelegate = appDelegate
        self.enforcer = enforcer
        self.backendClient = backendClient
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bedtime_settings.json")
    }

    func start() {
        // 1. Migration: if a legacy file exists and we've never migrated, push it.
        Task { await migrateLegacyIfNeeded() }

        // 2. Initial pull.
        Task { await pullAndApply() }

        // 3. Refresh on app focus + every 10 minutes.
        becameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.pullAndApply() }
        }
        // 60s — config rarely changes, but when it does (user toggles
        // bedtime on the iPhone), users notice if the Mac takes minutes to
        // catch up. Compromise between sync latency and backend traffic.
        // didBecomeActiveNotification still drives an immediate pull when
        // the user actually focuses the Mac dashboard.
        pullTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { await self?.pullAndApply() }
        }
    }

    func stop() {
        pullTimer?.invalidate()
        if let obs = becameActiveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Pull

    func pullAndApply() async {
        guard let dto = await backendClient.getBedtimeConfig() else {
            applyFromCache()
            return
        }
        // Persist to cache (DTO format).
        if let data = try? JSONEncoder().encode(dto) {
            try? data.write(to: cacheURL)
        }
        await MainActor.run { applyDTO(dto) }
    }

    private func applyFromCache() {
        // Try DTO format first (post-migration).
        if let data = try? Data(contentsOf: cacheURL),
           let dto = try? JSONDecoder().decode(BackendClient.BedtimeConfigDTO.self, from: data) {
            Task { @MainActor in applyDTO(dto) }
            return
        }
        // Legacy format already loaded by BedtimeEnforcer.loadSettings() during init.
        appDelegate?.postLog("🌙 Bedtime sync: backend unreachable, no DTO cache; using legacy local settings")
    }

    @MainActor
    private func applyDTO(_ dto: BackendClient.BedtimeConfigDTO) {
        let settings = BedtimeSettings(
            enabled: dto.enabled,
            bedtimeStart: TimeOfDay(hour: dto.bedtime_start.hour, minute: dto.bedtime_start.minute),
            wakeTime: TimeOfDay(hour: dto.wake.hour, minute: dto.wake.minute),
            activeDays: BedtimeConfigSync.isoToSundayBased(dto.active_days),
            partnerLocked: dto.partner_locked
        )
        enforcer?.applyRemoteSettings(settings)
        appDelegate?.postLog("🌙 Bedtime config applied from backend: enabled=\(dto.enabled) start=\(dto.bedtime_start.hour):\(String(format: "%02d", dto.bedtime_start.minute))")
    }

    /// Convert ISO weekdays (1=Mon..7=Sun) -> Mac internal (0=Sun..6=Sat).
    /// ISO 7=Sun -> 0; ISO 1=Mon -> 1; ... ISO 6=Sat -> 6.
    static func isoToSundayBased(_ iso: [Int]) -> [Int] {
        iso.map { $0 == 7 ? 0 : $0 }
    }

    /// Convert Mac internal (0=Sun..6=Sat) -> ISO (1=Mon..7=Sun).
    static func sundayBasedToISO(_ macDays: [Int]) -> [Int] {
        macDays.map { $0 == 0 ? 7 : $0 }
    }

    // MARK: - Legacy migration

    private func migrateLegacyIfNeeded() async {
        if UserDefaults.standard.bool(forKey: migrationFlagKey) { return }
        // Read the legacy file (BedtimeSettings format). If absent or already in
        // DTO format, treat as "nothing to migrate".
        guard let data = try? Data(contentsOf: cacheURL) else {
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            return
        }
        // If it already decodes as DTO, no migration needed.
        if (try? JSONDecoder().decode(BackendClient.BedtimeConfigDTO.self, from: data)) != nil {
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            return
        }
        guard let legacy = try? JSONDecoder().decode(BedtimeSettings.self, from: data) else {
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            return
        }
        let dto = BackendClient.BedtimeConfigDTO(
            enabled: legacy.enabled,
            bedtime_start: .init(hour: legacy.bedtimeStart.hour, minute: legacy.bedtimeStart.minute),
            wake: .init(hour: legacy.wakeTime.hour, minute: legacy.wakeTime.minute),
            active_days: BedtimeConfigSync.sundayBasedToISO(legacy.activeDays),
            allowlist_bundle_ids: [],
            partner_locked: legacy.partnerLocked,
            updated_at: nil
        )
        let ok = await backendClient.putBedtimeConfig(dto)
        if ok {
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            await MainActor.run {
                appDelegate?.postLog("🌙 Migrated legacy bedtime_settings.json -> backend")
            }
        } else {
            await MainActor.run {
                appDelegate?.postLog("🌙 Legacy bedtime migration failed; will retry next launch")
            }
        }
    }
}
