//
//  ContentSafetyStateGuard.swift
//  Intentional
//
//  Tamper detection for the Content Safety enabled flag.
//
//  Today, `contentSafety.enabled` lives only in onboarding_settings.json — a plain
//  JSON file owned by the user. A user can edit that file to set `enabled = false`
//  and on next launch ContentSafetyMonitor starts in the disabled state with no
//  tamper signal (the existing onSettingsChanged tamper path only fires when
//  isMonitoring was true at the time of the call).
//
//  This guard maintains a separate, signed "last-known intended state" file at
//  `~/Library/Application Support/Intentional/cs-state.json`. The signature is an
//  HMAC-SHA256 over `"<enabled>|<updatedAt>|<deviceId>"` keyed by a per-device
//  secret stored in the macOS Keychain.
//
//  On startup, AppDelegate calls `performStartupDivergenceCheck` which compares the
//  signed state to the on-disk JSON. Any divergence — bad signature, missing
//  signature, or signed-says-on / json-says-off — fires a tamper event to the
//  partner via the existing `BackendClient.reportContentSafetyTamper` path. When
//  the signed state says enabled and the JSON says disabled, the JSON is also
//  rewritten to `enabled = true` so the user can't bypass by hand-editing.
//
//  The state file is rewritten:
//   1. By `ContentSafetyMonitor.onSettingsChanged(enabled:)` whenever the user
//      legitimately toggles via the dashboard UI.
//   2. By AppDelegate.applicationWillTerminate on clean shutdown.
//   3. After a startup force-enable correction (so subsequent launches have a
//      consistent baseline).
//
//  Failure modes are degraded gracefully:
//   - Keychain read/write failure → write the file without an HMAC. On startup,
//     a state with `hmac == ""` is treated as "cannot verify" and falls back to
//     suspicious-only-if-divergent behaviour.
//   - State file missing on a fresh install → no tamper, just write the current
//     state and continue.
//

import Foundation
import Security
import CommonCrypto

enum ContentSafetyStateGuard {

    // MARK: - Disk paths

    private static let stateFileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Intentional/cs-state.json")
    }()

    private static let onboardingSettingsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Intentional/onboarding_settings.json")
    }()

    // MARK: - Keychain (HMAC secret)

    private static let keychainService = "com.intentional.auth"
    private static let hmacKeychainKey = "cs_hmac_secret"

    /// Fetch the per-device HMAC secret. If none exists, generate one and store it.
    /// Returns nil only if Keychain access fails outright.
    private static func getOrCreateHmacKey() -> Data? {
        if let existing = keychainGetData(hmacKeychainKey) {
            return existing
        }
        // Generate 32 random bytes
        var key = Data(count: 32)
        let result = key.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard result == errSecSuccess else { return nil }
        keychainSetData(key, forKey: hmacKeychainKey)
        // Verify the write took
        return keychainGetData(hmacKeychainKey)
    }

    private static func keychainSetData(_ value: Data, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = value
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func keychainGetData(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    // MARK: - HMAC

    /// Compute HMAC-SHA256 over `"<enabled>|<updatedAt>|<deviceId>"`, hex-encoded.
    private static func computeHmac(enabled: Bool, updatedAt: String, deviceId: String, key: Data) -> String {
        let message = "\(enabled)|\(updatedAt)|\(deviceId)"
        guard let messageData = message.data(using: .utf8) else { return "" }
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBuf in
            messageData.withUnsafeBytes { msgBuf in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBuf.baseAddress, key.count,
                    msgBuf.baseAddress, messageData.count,
                    &mac
                )
            }
        }
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Loading

    /// What we found when reading cs-state.json.
    enum LoadResult {
        /// File exists and signature matches.
        case ok(enabled: Bool, updatedAt: String)
        /// File doesn't exist (fresh install or cleared state).
        case missing
        /// File exists but signature failed verification → tamper.
        case invalidSignature(claimedEnabled: Bool?)
        /// File exists with hmac == "" (Keychain was unavailable when written).
        /// Treated as "cannot verify" — the on-disk enabled value is reported but
        /// callers should treat divergence-with-disable as suspicious.
        case unverifiable(enabled: Bool)
        /// File exists but couldn't be parsed at all.
        case corrupt
    }

    /// Read and verify the signed state file.
    static func load(deviceId: String) -> LoadResult {
        guard let data = try? Data(contentsOf: stateFileURL) else {
            return .missing
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .corrupt
        }
        guard let enabled = json["enabled"] as? Bool,
              let updatedAt = json["updatedAt"] as? String,
              let storedHmac = json["hmac"] as? String else {
            return .corrupt
        }
        // Empty hmac means the writer couldn't reach Keychain → unverifiable.
        if storedHmac.isEmpty {
            return .unverifiable(enabled: enabled)
        }
        guard let key = getOrCreateHmacKey() else {
            // We have a signature but can't verify it because Keychain failed.
            // Treat as unverifiable rather than tamper — verification machinery is broken.
            return .unverifiable(enabled: enabled)
        }
        let expected = computeHmac(enabled: enabled, updatedAt: updatedAt, deviceId: deviceId, key: key)
        // Constant-time compare not strictly necessary (local file, not network),
        // but the values are identical-length hex strings so equality is fine.
        if expected == storedHmac {
            return .ok(enabled: enabled, updatedAt: updatedAt)
        }
        return .invalidSignature(claimedEnabled: enabled)
    }

    // MARK: - Writing

    /// Write the signed state file. Called on clean shutdown, on legitimate UI
    /// toggle, and after a startup force-enable correction.
    @discardableResult
    static func write(enabled: Bool, deviceId: String) -> Bool {
        let updatedAt = ISO8601DateFormatter().string(from: Date())
        let hmac: String
        if let key = getOrCreateHmacKey() {
            hmac = computeHmac(enabled: enabled, updatedAt: updatedAt, deviceId: deviceId, key: key)
        } else {
            // Keychain unavailable — write without signature so we still have a
            // best-effort record of the last-known intended state.
            hmac = ""
        }
        let payload: [String: Any] = [
            "enabled": enabled,
            "updatedAt": updatedAt,
            "hmac": hmac
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        // Ensure parent dir exists
        let parent = stateFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try data.write(to: stateFileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Onboarding settings helpers

    /// Read `contentSafety.enabled` from onboarding_settings.json. Returns nil
    /// if the file or key is missing.
    static func readOnboardingEnabled() -> Bool? {
        guard let data = try? Data(contentsOf: onboardingSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cs = json["contentSafety"] as? [String: Any],
              let enabled = cs["enabled"] as? Bool else {
            return nil
        }
        return enabled
    }

    /// Force `contentSafety.enabled = true` in onboarding_settings.json.
    /// Used after we detect tampering and decide to override the user.
    @discardableResult
    static func forceEnableInOnboardingSettings() -> Bool {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: onboardingSettingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var cs = json["contentSafety"] as? [String: Any] ?? [:]
        cs["enabled"] = true
        json["contentSafety"] = cs
        json["lastModified"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else {
            return false
        }
        let parent = onboardingSettingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try data.write(to: onboardingSettingsURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Startup divergence check

    /// Outcome of the startup divergence check. AppDelegate uses this to decide
    /// the effective `enabled` value, whether to fire a tamper event, and whether
    /// to overwrite the on-disk JSON.
    struct StartupCheckResult {
        /// What CS should actually be set to after this check.
        let effectiveEnabled: Bool
        /// Whether onboarding_settings.json was rewritten to force-enable.
        let didForceEnable: Bool
        /// Tamper event reason, or nil if no tamper detected.
        let tamperReason: String?
        /// Human-readable summary for postLog.
        let logMessage: String
    }

    /// Compare the on-disk onboarding settings to the signed state and return
    /// a StartupCheckResult describing what should happen.
    ///
    /// - Parameter deviceId: The current device ID (matches BackendClient's deviceId).
    static func performStartupDivergenceCheck(deviceId: String) -> StartupCheckResult {
        let onboardingEnabled = readOnboardingEnabled()  // may be nil if file missing
        let signed = load(deviceId: deviceId)

        switch signed {
        case .missing:
            // No prior signed state. Could be first run or wiped state. Don't
            // fire a tamper event — just write the current state so subsequent
            // launches have a baseline.
            let current = onboardingEnabled ?? false
            write(enabled: current, deviceId: deviceId)
            return StartupCheckResult(
                effectiveEnabled: current,
                didForceEnable: false,
                tamperReason: nil,
                logMessage: "🛡️ CS state guard: no prior state, baselined enabled=\(current)"
            )

        case .corrupt:
            // The file exists but JSON couldn't be parsed. Treat as tamper.
            let onboarding = onboardingEnabled ?? false
            // We have nothing to compare against, so don't force-enable — just report.
            // Re-baseline with the current onboarding value.
            write(enabled: onboarding, deviceId: deviceId)
            return StartupCheckResult(
                effectiveEnabled: onboarding,
                didForceEnable: false,
                tamperReason: "cs_state_corrupt_at_startup",
                logMessage: "🛡️ TAMPER: cs-state.json corrupt — re-baselined to onboarding=\(onboarding)"
            )

        case .invalidSignature(let claimedEnabled):
            // HMAC didn't match. The file was forged or the secret was rotated
            // out from under us. Fire tamper. If signed file claimed enabled and
            // onboarding now says disabled, force-enable as the safer state.
            let onboarding = onboardingEnabled ?? false
            let claimed = claimedEnabled ?? false
            var didForce = false
            var effective = onboarding
            if claimed == true && onboarding == false {
                forceEnableInOnboardingSettings()
                didForce = true
                effective = true
            }
            // Re-baseline with the corrected effective value
            write(enabled: effective, deviceId: deviceId)
            return StartupCheckResult(
                effectiveEnabled: effective,
                didForceEnable: didForce,
                tamperReason: "cs_state_signature_invalid_at_startup",
                logMessage: "🛡️ TAMPER: cs-state.json signature invalid (claimed=\(claimed), onboarding=\(onboarding), forced=\(didForce))"
            )

        case .unverifiable(let signedEnabled):
            // Keychain was unavailable when this file was written, OR is unavailable
            // now. We can read the value but can't trust it cryptographically.
            // Policy: if signed says ON and onboarding says OFF, treat as suspicious
            // (most likely tamper scenario), force-enable, and log it.
            let onboarding = onboardingEnabled ?? false
            if signedEnabled == true && onboarding == false {
                forceEnableInOnboardingSettings()
                write(enabled: true, deviceId: deviceId)
                return StartupCheckResult(
                    effectiveEnabled: true,
                    didForceEnable: true,
                    tamperReason: "cs_state_unverifiable_divergence_at_startup",
                    logMessage: "🛡️ TAMPER: cs-state unverifiable, signed=on/onboarding=off — force-enabled"
                )
            }
            // Otherwise just align baseline to current onboarding value.
            write(enabled: onboarding, deviceId: deviceId)
            return StartupCheckResult(
                effectiveEnabled: onboarding,
                didForceEnable: false,
                tamperReason: nil,
                logMessage: "🛡️ CS state guard: signed state unverifiable but consistent (enabled=\(onboarding))"
            )

        case .ok(let signedEnabled, _):
            let onboarding = onboardingEnabled ?? false
            if signedEnabled == onboarding {
                // Consistent. Refresh updatedAt so the file stays recent.
                write(enabled: onboarding, deviceId: deviceId)
                return StartupCheckResult(
                    effectiveEnabled: onboarding,
                    didForceEnable: false,
                    tamperReason: nil,
                    logMessage: "🛡️ CS state guard: consistent (enabled=\(onboarding))"
                )
            }
            // Divergence! Signed state disagrees with onboarding JSON.
            if signedEnabled == true && onboarding == false {
                // The dangerous case — user disabled by editing JSON.
                forceEnableInOnboardingSettings()
                write(enabled: true, deviceId: deviceId)
                return StartupCheckResult(
                    effectiveEnabled: true,
                    didForceEnable: true,
                    tamperReason: "settings_divergence_at_startup",
                    logMessage: "🛡️ TAMPER: signed=on, onboarding=off → force-enabled"
                )
            }
            // signedEnabled == false && onboarding == true: less dangerous (user
            // is being MORE protective than last record), but still report so we
            // can see when the JSON was edited externally.
            write(enabled: onboarding, deviceId: deviceId)
            return StartupCheckResult(
                effectiveEnabled: onboarding,
                didForceEnable: false,
                tamperReason: "settings_divergence_at_startup",
                logMessage: "🛡️ TAMPER: signed=off, onboarding=on (re-baselined to on)"
            )
        }
    }
}
