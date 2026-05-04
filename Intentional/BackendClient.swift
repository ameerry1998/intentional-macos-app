//
//  BackendClient.swift
//  Intentional
//
//  Handles communication with backend API
//

import Foundation
import Cocoa
import Security
import CommonCrypto

struct EnforcementFetchResult {
    let success: Bool
    let lockMode: String
    let enforcementActive: Bool
    let constraints: [String: [String: Any]]
    let temporaryUnlockUntil: String?
    let updatedAt: String?
    let deviceId: String
    let rawJSON: Data  // the bytes we'll hand to daemon for signing
    let error: String?
}

class BackendClient {

    private let baseURL: String
    private let deviceId: String
    private static var loggedFailures: Set<String> = []

    /// SHA-256 fingerprint of the backend leaf certificate for the /device/enforcement call.
    /// Empty array = pinning disabled (dev/staging). In production, populate with uppercase
    /// colon-separated hex. When the cert is about to rotate, ship an app update with BOTH
    /// fingerprints (old + new), then drop the old after users have upgraded.
    ///
    /// To compute: `openssl s_client -connect api.intentional.social:443 -servername api.intentional.social </dev/null 2>/dev/null | openssl x509 -fingerprint -sha256 -noout`
    private static let pinnedBackendCertSHA256: [String] = [
        // TODO(ops): fill in actual fingerprint before production ship.
    ]

    init(baseURL: String) {
        self.baseURL = baseURL

        // Get or generate device ID (stored in UserDefaults)
        if let stored = UserDefaults.standard.string(forKey: "deviceId") {
            self.deviceId = stored
        } else {
            // Generate random 64-char hex string
            let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let random = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            self.deviceId = (uuid + random).prefix(64).lowercased()
            UserDefaults.standard.set(self.deviceId, forKey: "deviceId")
        }

        // Log device ID via AppDelegate if available
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.postLog("📱 Device ID: \(deviceId.prefix(16))...")
        } else {
            print("📱 Device ID: \(deviceId.prefix(16))...")
        }
    }

    /// Send system event to backend
    func sendEvent(type: String, details: [String: Any]) async {
        let endpoint = "\(baseURL)/system-event"

        var payload: [String: Any] = [
            "event_type": type,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": "native_app_macos"
        ]

        // Merge details
        payload.merge(details) { (_, new) in new }

        guard let url = URL(string: endpoint) else {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.postLog("❌ Invalid URL: \(endpoint)")
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let statusCode = httpResponse.statusCode
                await MainActor.run {
                    if !Self.loggedFailures.contains(type) {
                        Self.loggedFailures.insert(type)
                        let appDelegate = NSApplication.shared.delegate as? AppDelegate
                        appDelegate?.postLog("⚠️ Event failed: \(type) - Status \(statusCode)")
                    }
                }
            }
        } catch {
            await MainActor.run {
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.postLog("❌ Network error sending event \(type): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Set accountability partner via backend API
    func setPartner(email: String, name: String?) async {
        let endpoint = "\(baseURL)/partner"

        guard let url = URL(string: endpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        var payload: [String: Any] = ["partner_email": email]
        if let name = name, !name.isEmpty { payload["partner_name"] = name }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                appDelegate?.postLog("✅ Partner set: \(email)")
            } else {
                if let body = String(data: data, encoding: .utf8) {
                    appDelegate?.postLog("⚠️ Partner set failed: \(body)")
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Partner set error: \(error.localizedDescription)")
        }
    }

    /// Remove accountability partner via backend API (DELETE /partner)
    func removePartner() async -> Bool {
        let endpoint = "\(baseURL)/partner"

        guard let url = URL(string: endpoint) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                appDelegate?.postLog("✅ Partner removed via DELETE /partner")
                return true
            } else {
                if let body = String(data: data, encoding: .utf8) {
                    appDelegate?.postLog("⚠️ Partner removal failed: \(body)")
                }
                return false
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Partner removal error: \(error.localizedDescription)")
            return false
        }
    }

    /// Debug access to base URL
    var baseURLForDebug: String { baseURL }

    // MARK: - Lock Mode (with structured result)

    struct LockResult {
        let success: Bool
        let message: String
        let statusCode: Int
    }

    /// Set lock mode via backend API — returns structured result
    func setLockMode(mode: String) async -> LockResult {
        let endpoint = "\(baseURL)/lock"

        guard let url = URL(string: endpoint) else {
            return LockResult(success: false, message: "Invalid URL", statusCode: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        let payload = ["mode": mode]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            if let httpResponse = response as? HTTPURLResponse {
                if isSuccess(httpResponse.statusCode) {
                    appDelegate?.postLog("✅ Lock mode set: \(mode)")
                    return LockResult(success: true, message: "Lock mode set to \(mode)", statusCode: httpResponse.statusCode)
                } else {
                    let msg = errorMessage(from: data)
                    appDelegate?.postLog("⚠️ Lock mode set failed (\(httpResponse.statusCode)): \(msg)")
                    return LockResult(success: false, message: msg, statusCode: httpResponse.statusCode)
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Lock mode error: \(error.localizedDescription)")
            return LockResult(success: false, message: error.localizedDescription, statusCode: 0)
        }
        return LockResult(success: false, message: "Unknown error", statusCode: 0)
    }

    // MARK: - Unlock

    struct UnlockResult {
        let success: Bool
        let message: String
        let statusCode: Int
        let mode: String?
    }

    /// Request an unlock code from the backend
    func requestUnlock() async -> UnlockResult {
        let endpoint = "\(baseURL)/unlock/request"

        guard let url = URL(string: endpoint) else {
            return UnlockResult(success: false, message: "Invalid URL", statusCode: 0, mode: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [:] as [String: String])
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let json = parseJSON(data)
                let msg = (json?["message"] as? String) ?? errorMessage(from: data)
                let mode = json?["mode"] as? String
                if isSuccess(httpResponse.statusCode) {
                    return UnlockResult(success: true, message: msg, statusCode: httpResponse.statusCode, mode: mode)
                } else {
                    return UnlockResult(success: false, message: msg, statusCode: httpResponse.statusCode, mode: mode)
                }
            }
        } catch {
            return UnlockResult(success: false, message: error.localizedDescription, statusCode: 0, mode: nil)
        }
        return UnlockResult(success: false, message: "Unknown error", statusCode: 0, mode: nil)
    }

    // MARK: - Verify Unlock Code

    struct VerifyResult {
        let success: Bool
        let message: String
        let autoRelock: Bool
        let temporaryUnlockUntil: String?  // ISO8601 timestamp or nil for permanent
        let statusCode: Int
    }

    /// Verify an unlock code with the backend
    func verifyUnlock(code: String, autoRelock: Bool) async -> VerifyResult {
        let endpoint = "\(baseURL)/unlock/verify"

        guard let url = URL(string: endpoint) else {
            return VerifyResult(success: false, message: "Invalid URL", autoRelock: autoRelock, temporaryUnlockUntil: nil, statusCode: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        var body: [String: Any] = ["auto_relock": autoRelock]
        if !code.isEmpty { body["code"] = code }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               let json = parseJSON(data) {
                let msg = json["message"] as? String ?? errorMessage(from: data)
                let success = json["success"] as? Bool ?? false
                let tuu = json["temporary_unlock_until"] as? String
                let ar = json["auto_relock"] as? Bool ?? autoRelock

                return VerifyResult(
                    success: success,
                    message: msg,
                    autoRelock: ar,
                    temporaryUnlockUntil: tuu,
                    statusCode: httpResponse.statusCode
                )
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Verify unlock error: \(error.localizedDescription)")
            return VerifyResult(success: false, message: error.localizedDescription, autoRelock: autoRelock, temporaryUnlockUntil: nil, statusCode: 0)
        }
        return VerifyResult(success: false, message: "Unknown error", autoRelock: autoRelock, temporaryUnlockUntil: nil, statusCode: 0)
    }

    // MARK: - Extra Time

    struct ExtraTimeRequestResult {
        let success: Bool
        let message: String
        let requestId: String?
        let partnerName: String?
        let statusCode: Int
        let verifiedToday: Int
        let remainingToday: Int
    }

    /// Request extra browse time via accountability partner
    func requestExtraTime(minutes: Int) async -> ExtraTimeRequestResult {
        let endpoint = "\(baseURL)/extra-time/request"

        guard let url = URL(string: endpoint) else {
            return ExtraTimeRequestResult(success: false, message: "Invalid URL", requestId: nil, partnerName: nil, statusCode: 0, verifiedToday: 0, remainingToday: 2)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["minutes": minutes])
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let json = parseJSON(data)
                let msg = (json?["message"] as? String) ?? errorMessage(from: data)
                let requestId = json?["request_id"] as? String
                let partnerName = json?["partner_name"] as? String
                let verifiedToday = json?["verified_today"] as? Int ?? 0
                let remainingToday = json?["remaining_today"] as? Int ?? 2
                if isSuccess(httpResponse.statusCode) {
                    return ExtraTimeRequestResult(success: true, message: msg, requestId: requestId, partnerName: partnerName, statusCode: httpResponse.statusCode, verifiedToday: verifiedToday, remainingToday: remainingToday)
                } else {
                    return ExtraTimeRequestResult(success: false, message: msg, requestId: nil, partnerName: partnerName, statusCode: httpResponse.statusCode, verifiedToday: verifiedToday, remainingToday: remainingToday)
                }
            }
        } catch {
            return ExtraTimeRequestResult(success: false, message: error.localizedDescription, requestId: nil, partnerName: nil, statusCode: 0, verifiedToday: 0, remainingToday: 2)
        }
        return ExtraTimeRequestResult(success: false, message: "Unknown error", requestId: nil, partnerName: nil, statusCode: 0, verifiedToday: 0, remainingToday: 2)
    }

    struct ExtraTimeVerifyResult {
        let success: Bool
        let message: String
        let addedMinutes: Int
        let statusCode: Int
        let verifiedToday: Int
        let remainingToday: Int
    }

    /// Verify an extra time code with the backend
    func verifyExtraTime(code: String, requestId: String) async -> ExtraTimeVerifyResult {
        let endpoint = "\(baseURL)/extra-time/verify"

        guard let url = URL(string: endpoint) else {
            return ExtraTimeVerifyResult(success: false, message: "Invalid URL", addedMinutes: 0, statusCode: 0, verifiedToday: 0, remainingToday: 2)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "request_id": requestId])
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let json = parseJSON(data)
                let msg = (json?["message"] as? String) ?? errorMessage(from: data)
                let success = json?["success"] as? Bool ?? false
                let addedMinutes = json?["added_minutes"] as? Int ?? 0
                let verifiedToday = json?["verified_today"] as? Int ?? 0
                let remainingToday = json?["remaining_today"] as? Int ?? 2
                if isSuccess(httpResponse.statusCode) && success {
                    return ExtraTimeVerifyResult(success: true, message: msg, addedMinutes: addedMinutes, statusCode: httpResponse.statusCode, verifiedToday: verifiedToday, remainingToday: remainingToday)
                } else {
                    return ExtraTimeVerifyResult(success: false, message: msg, addedMinutes: 0, statusCode: httpResponse.statusCode, verifiedToday: verifiedToday, remainingToday: remainingToday)
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Verify extra time error: \(error.localizedDescription)")
            return ExtraTimeVerifyResult(success: false, message: error.localizedDescription, addedMinutes: 0, statusCode: 0, verifiedToday: 0, remainingToday: 2)
        }
        return ExtraTimeVerifyResult(success: false, message: "Unknown error", addedMinutes: 0, statusCode: 0, verifiedToday: 0, remainingToday: 2)
    }

    // MARK: - AI Override

    struct OverrideRequestResult {
        let success: Bool
        let message: String
        let requestId: String?
        let partnerName: String?
    }

    struct OverrideVerifyResult {
        let success: Bool
        let message: String
    }

    /// Request an AI override from accountability partner
    func requestOverride(blockType: String, pageTitle: String, intention: String) async -> OverrideRequestResult {
        let endpoint = "\(baseURL)/override/request"

        guard let url = URL(string: endpoint) else {
            return OverrideRequestResult(success: false, message: "Invalid URL", requestId: nil, partnerName: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "block_type": blockType,
                "page_title": pageTitle,
                "intention": intention
            ])
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let json = parseJSON(data)
                let msg = (json?["message"] as? String) ?? errorMessage(from: data)
                let requestId = json?["request_id"] as? String
                let partnerName = json?["partner_name"] as? String
                if isSuccess(httpResponse.statusCode) {
                    return OverrideRequestResult(success: true, message: msg, requestId: requestId, partnerName: partnerName)
                } else {
                    return OverrideRequestResult(success: false, message: msg, requestId: nil, partnerName: partnerName)
                }
            }
        } catch {
            return OverrideRequestResult(success: false, message: error.localizedDescription, requestId: nil, partnerName: nil)
        }
        return OverrideRequestResult(success: false, message: "Unknown error", requestId: nil, partnerName: nil)
    }

    /// Verify an AI override code with the backend
    func verifyOverride(code: String, requestId: String) async -> OverrideVerifyResult {
        let endpoint = "\(baseURL)/override/verify"

        guard let url = URL(string: endpoint) else {
            return OverrideVerifyResult(success: false, message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "request_id": requestId])
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let json = parseJSON(data)
                let msg = (json?["message"] as? String) ?? errorMessage(from: data)
                let success = json?["success"] as? Bool ?? false
                if isSuccess(httpResponse.statusCode) && success {
                    return OverrideVerifyResult(success: true, message: msg)
                } else {
                    return OverrideVerifyResult(success: false, message: msg)
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Verify override error: \(error.localizedDescription)")
            return OverrideVerifyResult(success: false, message: error.localizedDescription)
        }
        return OverrideVerifyResult(success: false, message: "Unknown error")
    }

    // MARK: - Relock

    /// Re-lock settings by re-applying the current lock mode (clears temporary_unlock_until on backend)
    func relockSettings() async -> UnlockResult {
        // Get current lock mode first
        let currentMode = UserDefaults.standard.string(forKey: "lockMode") ?? "partner"

        // PUT /lock with the same mode clears temporary_unlock_until
        let result = await setLockMode(mode: currentMode)
        return UnlockResult(
            success: result.success,
            message: result.success ? "Settings re-locked" : result.message,
            statusCode: result.statusCode,
            mode: currentMode
        )
    }

    // MARK: - Unlock Status

    struct StatusResult {
        let success: Bool
        let lockMode: String
        let partnerEmail: String?
        let consentStatus: String?
        let isLocked: Bool
        let isTemporarilyUnlocked: Bool
        let temporaryUnlockUntil: String?
        let autoRelock: Bool
        let hasPendingRequest: Bool
    }

    /// Get current lock/unlock status from backend
    func getUnlockStatus() async -> StatusResult? {
        let endpoint = "\(baseURL)/unlock/status"

        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, isSuccess(httpResponse.statusCode),
               let json = parseJSON(data) {
                return StatusResult(
                    success: true,
                    lockMode: json["lock_mode"] as? String ?? "none",
                    partnerEmail: json["partner_email"] as? String,
                    consentStatus: json["consent_status"] as? String,
                    isLocked: json["is_locked"] as? Bool ?? false,
                    isTemporarilyUnlocked: json["is_temporarily_unlocked"] as? Bool ?? false,
                    temporaryUnlockUntil: json["temporary_unlock_until"] as? String,
                    autoRelock: json["auto_relock"] as? Bool ?? true,
                    hasPendingRequest: json["has_pending_request"] as? Bool ?? false
                )
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ Failed to fetch unlock status: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Bedtime Config (cross-device sync)

    struct BedtimeTimeOfDayDTO: Codable, Equatable {
        let hour: Int
        let minute: Int
    }

    struct BedtimeConfigDTO: Codable, Equatable {
        let enabled: Bool
        let bedtime_start: BedtimeTimeOfDayDTO
        let wake: BedtimeTimeOfDayDTO
        let active_days: [Int]   // ISO 1=Mon..7=Sun
        let allowlist_bundle_ids: [String]
        let partner_locked: Bool
        let updated_at: String?
    }

    /// GET /bedtime/config — returns nil on any failure (offline, 4xx, decode error).
    /// Caller falls back to the on-disk cache.
    func getBedtimeConfig() async -> BedtimeConfigDTO? {
        let endpoint = "\(baseURL)/bedtime/config"
        guard let url = URL(string: endpoint) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(BedtimeConfigDTO.self, from: data)
        } catch {
            return nil
        }
    }

    /// PUT /bedtime/config — replaces the full config on the backend so
    /// sibling devices (iPhone) pick up the change on their next pull.
    /// Returns true on 2xx.
    @discardableResult
    func putBedtimeConfig(_ config: BedtimeConfigDTO) async -> Bool {
        let endpoint = "\(baseURL)/bedtime/config"
        guard let url = URL(string: endpoint) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            req.httpBody = try JSONEncoder().encode(config)
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    // MARK: - Bedtime Unlock

    /// Errors specific to the bedtime-unlock flow. Surfaced to the UI so
    /// the user sees the right phrasing for once-per-night cap vs no
    /// partner configured vs network failure.
    enum BedtimeUnlockError: Error, LocalizedError {
        /// Backend 409 with "already used your extension" — the user has a
        /// verified row with released_until > now. New requests blocked
        /// until wake.
        case alreadyUsed
        /// Backend 409 with "no partner" — onboarding incomplete.
        case noPartner
        case other(String)

        var errorDescription: String? {
            switch self {
            case .alreadyUsed:
                return "You've already used your extension for tonight. Bedtime ends at your wake alarm."
            case .noPartner:
                return "Add an accountability partner to request a bedtime extension."
            case .other(let msg):
                return msg
            }
        }
    }

    struct BedtimeUnlockRequestResult {
        let requestId: String
        let partnerEmail: String
        let expiresAt: String  // ISO8601
    }

    /// Send a bedtime-unlock request. The slider value (15 / 30 / 60 / 120
    /// or -1 for "until wake") is sent as `duration_minutes`; backend
    /// stores it on the `bedtime_unlock_requests` row and uses it at
    /// verify time to compute released_until.
    ///
    /// Throws `BedtimeUnlockError.alreadyUsed` on backend 409 — the user
    /// has already consumed tonight's extension. Once-per-night enforced
    /// backend-side per migration 016.
    func bedtimeUnlockRequest(
        durationMinutes: Int,
        reason: String?,
        note: String?
    ) async throws -> BedtimeUnlockRequestResult {
        let endpoint = "\(baseURL)/bedtime/unlock-request"
        guard let url = URL(string: endpoint) else {
            throw BedtimeUnlockError.other("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        if let token = await loadJWT() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = ["duration_minutes": durationMinutes]
        if let reason { body["reason"] = reason }
        if let note { body["note"] = note }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BedtimeUnlockError.other("No response")
            }
            let json = parseJSON(data)

            if httpResponse.statusCode == 200 {
                guard
                    let requestId = json?["request_id"] as? String,
                    let partnerEmail = json?["partner_email"] as? String,
                    let expiresAt = json?["expires_at"] as? String
                else {
                    throw BedtimeUnlockError.other("Malformed response")
                }
                return BedtimeUnlockRequestResult(
                    requestId: requestId,
                    partnerEmail: partnerEmail,
                    expiresAt: expiresAt
                )
            }

            if httpResponse.statusCode == 409 {
                let detail = (json?["detail"] as? String)?.lowercased() ?? ""
                if detail.contains("already") {
                    throw BedtimeUnlockError.alreadyUsed
                }
                if detail.contains("partner") {
                    throw BedtimeUnlockError.noPartner
                }
                throw BedtimeUnlockError.other(json?["detail"] as? String ?? "Conflict")
            }

            throw BedtimeUnlockError.other(
                json?["detail"] as? String ?? "HTTP \(httpResponse.statusCode)"
            )
        } catch let err as BedtimeUnlockError {
            throw err
        } catch {
            throw BedtimeUnlockError.other(error.localizedDescription)
        }
    }

    /// Helper: load the cached Supabase JWT for Authorization header. Some
    /// callers may not have a JWT (legacy device-only auth still works via
    /// X-Device-ID — backend resolves account via dual-auth).
    private func loadJWT() async -> String? {
        return keychainGet("access_token")
    }

    // MARK: - Partner Status

    /// Result from partner status query
    struct PartnerStatusResult {
        let success: Bool
        let partnerEmail: String?
        let partnerName: String?
        let consentStatus: String
        let message: String
    }

    /// Fetch current partner and consent status from backend
    func getPartnerStatus() async -> PartnerStatusResult? {
        let endpoint = "\(baseURL)/partner/status"

        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, isSuccess(httpResponse.statusCode),
               let json = parseJSON(data) {
                return PartnerStatusResult(
                    success: true,
                    partnerEmail: json["partner_email"] as? String,
                    partnerName: json["partner_name"] as? String,
                    consentStatus: json["consent_status"] as? String ?? "none",
                    message: json["message"] as? String ?? ""
                )
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ Failed to fetch partner status: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - Helpers

    private func isSuccess(_ statusCode: Int) -> Bool {
        return statusCode >= 200 && statusCode < 300
    }

    private func parseJSON(_ data: Data) -> [String: Any]? {
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func errorMessage(from data: Data) -> String {
        if let json = parseJSON(data) {
            return (json["error"] as? String)
                ?? (json["message"] as? String)
                ?? (json["detail"] as? String)
                ?? "Unknown error"
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    /// Register device with backend (call on first launch)
    func registerDevice() async {
        let endpoint = "\(baseURL)/register"

        guard let url = URL(string: endpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["device_id": deviceId]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                appDelegate?.postLog("✅ Device registered")
            } else {
                appDelegate?.postLog("⚠️ Device registration failed")
                if let body = String(data: data, encoding: .utf8) {
                    appDelegate?.postLog("   Response: \(body)")
                }
            }
        } catch {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.postLog("❌ Registration error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sessions

    /// POST /sessions — record a completed browsing session
    func recordSession(
        platform: String,
        browser: String,
        intent: String?,
        freeBrowse: Bool,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int,
        plannedDurationSeconds: Int?,
        videoSeconds: Int
    ) async {
        let endpoint = "\(baseURL)/sessions"
        guard let url = URL(string: endpoint) else { return }

        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "platform": platform,
            "browser": browser,
            "free_browse": freeBrowse,
            "started_at": formatter.string(from: startedAt),
            "ended_at": formatter.string(from: endedAt),
            "duration_seconds": durationSeconds,
            "video_seconds": videoSeconds
        ]
        if let intent = intent { payload["intent"] = intent }
        if let planned = plannedDurationSeconds { payload["planned_duration_seconds"] = planned }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let appDelegate = NSApplication.shared.delegate as? AppDelegate
                if isSuccess(httpResponse.statusCode) {
                    appDelegate?.postLog("📊 Session recorded: \(platform) (\(durationSeconds)s)")
                } else {
                    appDelegate?.postLog("⚠️ Session record failed: \(httpResponse.statusCode)")
                    if let body = String(data: data, encoding: .utf8) {
                        appDelegate?.postLog("   Response: \(body)")
                    }
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Session record error: \(error.localizedDescription)")
        }
    }

    // MARK: - Usage Sync

    /// POST /usage/sync — upsert daily usage data (called every 60s by TimeTracker)
    func syncUsage(platforms: [[String: Any]]) async {
        let endpoint = "\(baseURL)/usage/sync"
        guard let url = URL(string: endpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        let payload: [String: Any] = ["platforms": platforms]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, !isSuccess(httpResponse.statusCode) {
                let appDelegate = NSApplication.shared.delegate as? AppDelegate
                appDelegate?.postLog("⚠️ Usage sync failed: \(httpResponse.statusCode)")
                if let body = String(data: data, encoding: .utf8) {
                    appDelegate?.postLog("   Response: \(body)")
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Usage sync error: \(error.localizedDescription)")
        }
    }

    /// GET /usage/history — fetch daily usage history
    func getUsageHistory(days: Int = 7) async -> [String: Any]? {
        let endpoint = "\(baseURL)/usage/history?days=\(days)"
        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, isSuccess(httpResponse.statusCode) {
                return parseJSON(data)
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ Usage history fetch error: \(error.localizedDescription)")
        }
        return nil
    }

    /// GET /sessions/journal — fetch session journal for a date
    func getJournal(date: String? = nil) async -> [String: Any]? {
        var endpoint = "\(baseURL)/sessions/journal"
        if let date = date { endpoint += "?date=\(date)" }
        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, isSuccess(httpResponse.statusCode) {
                return parseJSON(data)
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ Journal fetch error: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Settings Sync

    /// PUT /settings/sync — save settings to backend (requires JWT auth)
    func syncSettings(settings: [String: Any]) async {
        guard let accessToken = keychainGet("access_token") else { return }

        let endpoint = "\(baseURL)/settings/sync"
        guard let url = URL(string: endpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = ["settings": settings]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    let refreshed = await authRefresh()
                    if refreshed { await syncSettings(settings: settings) }
                    return
                }
                if isSuccess(httpResponse.statusCode) {
                    let appDelegate = NSApplication.shared.delegate as? AppDelegate
                    appDelegate?.postLog("☁️ Settings synced to backend")
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Settings sync error: \(error.localizedDescription)")
        }
    }

    /// GET /settings/sync — retrieve settings from backend (requires JWT auth)
    func getSettings() async -> [String: Any]? {
        guard let accessToken = keychainGet("access_token") else { return nil }

        let endpoint = "\(baseURL)/settings/sync"
        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    let refreshed = await authRefresh()
                    if refreshed { return await getSettings() }
                    return nil
                }
                if isSuccess(httpResponse.statusCode), let json = parseJSON(data) {
                    return json["settings"] as? [String: Any]
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ Settings fetch error: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Keychain Helpers

    private static let keychainService = "com.intentional.auth"

    private func keychainSet(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func keychainGet(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    func clearAuthTokens() {
        keychainDelete("access_token")
        keychainDelete("refresh_token")
        keychainDelete("account_id")
        keychainDelete("email")
    }

    var isLoggedIn: Bool {
        return keychainGet("access_token") != nil
    }

    /// Returns the stored JWT access token, or nil if not logged in.
    /// Used by FocusWebSocketClient for WebSocket authentication.
    func getAccessToken() -> String? {
        return keychainGet("access_token")
    }

    /// Returns the stable 64-char hex device ID. Linked to the user's account
    /// after `/auth/verify`. Used as `X-Device-ID` on legacy endpoints and
    /// (via FocusStatePoller) on `/focus/active` for long-lived auth that
    /// doesn't suffer 15-min JWT expiry.
    func getDeviceId() -> String {
        return deviceId
    }

    var storedEmail: String? {
        return keychainGet("email")
    }

    var storedAccountId: String? {
        return keychainGet("account_id")
    }

    // MARK: - Auth API

    struct AuthResult {
        let success: Bool
        let message: String
        let data: [String: Any]?
    }

    /// POST /auth/login — send verification code
    func authLogin(email: String) async -> AuthResult {
        let endpoint = "\(baseURL)/auth/login"
        guard let url = URL(string: endpoint) else {
            return AuthResult(success: false, message: "Invalid URL", data: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let json = parseJSON(data)
                let msg = json?["message"] as? String ?? errorMessage(from: data)
                return AuthResult(success: isSuccess(httpResponse.statusCode), message: msg, data: json)
            }
        } catch {
            return AuthResult(success: false, message: error.localizedDescription, data: nil)
        }
        return AuthResult(success: false, message: "Unknown error", data: nil)
    }

    /// POST /auth/verify — verify code, get tokens, link device
    func authVerify(email: String, code: String) async -> AuthResult {
        let endpoint = "\(baseURL)/auth/verify"
        guard let url = URL(string: endpoint) else {
            return AuthResult(success: false, message: "Invalid URL", data: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = ["email": email, "code": code, "device_id": deviceId]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let json = parseJSON(data)

                if isSuccess(httpResponse.statusCode), let json = json {
                    if let t = json["access_token"] as? String { keychainSet(t, forKey: "access_token") }
                    if let t = json["refresh_token"] as? String { keychainSet(t, forKey: "refresh_token") }
                    if let v = json["account_id"] as? String { keychainSet(v, forKey: "account_id") }
                    if let v = json["email"] as? String { keychainSet(v, forKey: "email") }

                    let appDelegate = NSApplication.shared.delegate as? AppDelegate
                    appDelegate?.postLog("✅ Auth: Signed in as \(json["email"] as? String ?? "unknown")")
                    return AuthResult(success: true, message: "Signed in", data: json)
                } else {
                    let msg = json?["detail"] as? String ?? json?["message"] as? String ?? errorMessage(from: data)
                    return AuthResult(success: false, message: msg, data: json)
                }
            }
        } catch {
            return AuthResult(success: false, message: error.localizedDescription, data: nil)
        }
        return AuthResult(success: false, message: "Unknown error", data: nil)
    }

    /// POST /auth/refresh — rotate tokens
    /// Serialised refresh: concurrent callers share a single in-flight task.
    /// Without this, two paths (DeviceRegister + WebSocket, or two API calls)
    /// hitting 401 at the same time both POST `/auth/refresh` with the same
    /// refresh token. The first succeeds (rotates the refresh token); the
    /// second uses the now-invalidated old refresh token, gets rejected, and
    /// — under the previous logic — called `clearAuthTokens()`, wiping
    /// BOTH the access AND refresh tokens that the first call had just
    /// written. Net effect: race losers logged the user out.
    private let refreshLock = NSLock()
    private var refreshTask: Task<Bool, Never>?

    func authRefresh() async -> Bool {
        // Coalesce: if a refresh is already running, await its result.
        refreshLock.lock()
        if let inFlight = refreshTask {
            refreshLock.unlock()
            return await inFlight.value
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self = self else { return false }
            return await self.performAuthRefresh()
        }
        refreshTask = task
        refreshLock.unlock()

        let result = await task.value

        refreshLock.lock()
        refreshTask = nil
        refreshLock.unlock()
        return result
    }

    private func performAuthRefresh() async -> Bool {
        guard let refreshToken = keychainGet("refresh_token") else { return false }

        let endpoint = "\(baseURL)/auth/refresh"
        guard let url = URL(string: endpoint) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, isSuccess(httpResponse.statusCode),
               let json = parseJSON(data) {
                if let t = json["access_token"] as? String { keychainSet(t, forKey: "access_token") }
                if let t = json["refresh_token"] as? String { keychainSet(t, forKey: "refresh_token") }
                return true
            } else {
                // Defensive: only clear tokens on a 4xx (definitive "refresh
                // token is invalid"). Don't clear on 5xx / network error /
                // ambiguous failure — those are transient and the user should
                // be allowed to retry without being signed out.
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (400..<500).contains(statusCode) {
                    clearAuthTokens()
                }
                return false
            }
        } catch {
            // Network error — leave tokens alone, user can retry.
            return false
        }
    }

    /// POST /auth/logout — revoke token family
    func authLogout() async -> AuthResult {
        let refreshToken = keychainGet("refresh_token")

        if let refreshToken = refreshToken {
            let endpoint = "\(baseURL)/auth/logout"
            if let url = URL(string: endpoint) {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
                _ = try? await URLSession.shared.data(for: request)
            }
        }

        clearAuthTokens()
        let appDelegate = NSApplication.shared.delegate as? AppDelegate
        appDelegate?.postLog("✅ Auth: Signed out")
        return AuthResult(success: true, message: "Signed out", data: nil)
    }

    /// GET /auth/me — get account info (auto-refreshes on 401)
    func authMe(retried: Bool = false) async -> AuthResult {
        guard let accessToken = keychainGet("access_token") else {
            return AuthResult(success: false, message: "Not signed in", data: nil)
        }

        let endpoint = "\(baseURL)/auth/me"
        guard let url = URL(string: endpoint) else {
            return AuthResult(success: false, message: "Invalid URL", data: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 && !retried {
                    let refreshed = await authRefresh()
                    if refreshed {
                        return await authMe(retried: true)
                    } else {
                        return AuthResult(success: false, message: "Session expired", data: nil)
                    }
                }

                if isSuccess(httpResponse.statusCode), let json = parseJSON(data) {
                    return AuthResult(success: true, message: "OK", data: json)
                }
            }
        } catch {
            return AuthResult(success: false, message: error.localizedDescription, data: nil)
        }
        return AuthResult(success: false, message: "Unknown error", data: nil)
    }

    /// POST /auth/delete — request account deletion (auto-refreshes on 401)
    func authDelete(retried: Bool = false) async -> AuthResult {
        guard let accessToken = keychainGet("access_token") else {
            return AuthResult(success: false, message: "Not signed in", data: nil)
        }

        let endpoint = "\(baseURL)/auth/delete"
        guard let url = URL(string: endpoint) else {
            return AuthResult(success: false, message: "Invalid URL", data: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 && !retried {
                    let refreshed = await authRefresh()
                    if refreshed {
                        return await authDelete(retried: true)
                    } else {
                        return AuthResult(success: false, message: "Session expired", data: nil)
                    }
                }

                let json = parseJSON(data)
                let msg = json?["message"] as? String ?? errorMessage(from: data)
                return AuthResult(success: isSuccess(httpResponse.statusCode), message: msg, data: json)
            }
        } catch {
            return AuthResult(success: false, message: error.localizedDescription, data: nil)
        }
        return AuthResult(success: false, message: "Unknown error", data: nil)
    }

    // MARK: - Content Safety

    /// Report a content safety detection to the backend.
    /// The backend sends a blurred screenshot to the accountability partner.
    /// Returns true if the report was accepted (email may or may not have been sent).
    func reportContentSafety(blurredImageBase64: String, timestamp: String) async -> Bool {
        let endpoint = "\(baseURL)/content-safety/report"

        guard let url = URL(string: endpoint) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        // Longer timeout for large base64 payloads
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "timestamp": timestamp,
            "blurred_image_base64": blurredImageBase64
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    appDelegate?.postLog("🛡️ Content safety report accepted")
                    return true
                } else if httpResponse.statusCode == 429 {
                    appDelegate?.postLog("🛡️ Content safety report rate-limited (429)")
                    return false
                } else {
                    if let body = String(data: data, encoding: .utf8) {
                        appDelegate?.postLog("⚠️ Content safety report failed (\(httpResponse.statusCode)): \(body)")
                    }
                    return false
                }
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("❌ Content safety report error: \(error.localizedDescription)")
        }

        return false
    }

    // MARK: - Enforcement

    /// Fetch authoritative enforcement state. Uses cert-pinned URLSession when pinning
    /// fingerprints are configured; otherwise falls back to the default session with a
    /// warning log (dev/staging).
    func fetchEnforcement() async -> EnforcementFetchResult? {
        let endpoint = "\(baseURL)/device/enforcement"
        guard let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        let session = Self.pinnedBackendCertSHA256.isEmpty
            ? URLSession.shared
            : URLSession(configuration: .default,
                         delegate: CertPinningDelegate(pinned: Self.pinnedBackendCertSHA256),
                         delegateQueue: nil)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let appDelegate = NSApplication.shared.delegate as? AppDelegate
                appDelegate?.postLog("⚠️ fetchEnforcement non-200: \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let constraints = (json["constraints"] as? [String: [String: Any]]) ?? [:]
            return EnforcementFetchResult(
                success: (json["success"] as? Bool) ?? false,
                lockMode: (json["lock_mode"] as? String) ?? "none",
                enforcementActive: (json["enforcement_active"] as? Bool) ?? false,
                constraints: constraints,
                temporaryUnlockUntil: json["temporary_unlock_until"] as? String,
                updatedAt: json["updated_at"] as? String,
                deviceId: (json["device_id"] as? String) ?? deviceId,
                rawJSON: data,
                error: nil
            )
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ fetchEnforcement failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Report a tamper event (permission revoked or feature disabled).
    /// Backend notifies the accountability partner.
    func reportContentSafetyTamper(eventType: String, detail: String) async {
        let endpoint = "\(baseURL)/content-safety/tamper"

        guard let url = URL(string: endpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        let payload: [String: Any] = [
            "event_type": eventType,
            "detail": detail,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)

            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                appDelegate?.postLog("🛡️ Tamper event reported: \(eventType)/\(detail)")
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ Tamper report error: \(error.localizedDescription)")
        }
    }

    // MARK: - Intentions (Spec 1)

    /// Custom error for /intentions PUT 409 (stale version).
    enum IntentionError: Error, LocalizedError {
        case versionConflict(currentServerVersion: Int?)
        case notFound
        case network(String)

        var errorDescription: String? {
            switch self {
            case .versionConflict(let v):
                return "Server has a newer version (\(v.map(String.init) ?? "?")). Refetch and retry."
            case .notFound:
                return "Focus mode not found on server"
            case .network(let s):
                return s
            }
        }
    }

    private func intentionsJSONDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    private func intentionsJSONEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// GET /intentions — returns nil on network failure, [] when truly empty.
    /// `includeDeleted` true returns tombstones (used for session-history rendering).
    func getIntentions(includeDeleted: Bool = false) async -> [Intention]? {
        var components = URLComponents(string: "\(baseURL)/intentions")
        if includeDeleted {
            components?.queryItems = [URLQueryItem(name: "include_deleted", value: "true")]
        }
        guard let url = components?.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let resp = try intentionsJSONDecoder().decode(IntentionListResponse.self, from: data)
            return resp.intentions
        } catch {
            return nil
        }
    }

    /// GET /intentions/{id} — includes soft-deleted (for history). Returns nil on 404.
    func getIntention(id: UUID) async -> Intention? {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try intentionsJSONDecoder().decode(Intention.self, from: data)
        } catch {
            return nil
        }
    }

    /// POST /intentions — server assigns id and version=1.
    func createIntention(_ payload: IntentionCreatePayload) async throws -> Intention {
        guard let url = URL(string: "\(baseURL)/intentions") else {
            throw IntentionError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        req.httpBody = try intentionsJSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw IntentionError.network("HTTP \(code)")
        }
        return try intentionsJSONDecoder().decode(Intention.self, from: data)
    }

    /// PUT /intentions/{id} — caller must include current version. Throws .versionConflict on 409.
    func updateIntention(id: UUID, payload: IntentionUpdatePayload) async throws -> Intention {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)") else {
            throw IntentionError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        req.httpBody = try intentionsJSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 409 {
            // Try to refetch the current version for the error
            let current = await getIntention(id: id)
            throw IntentionError.versionConflict(currentServerVersion: current?.version)
        }
        if code == 404 || code == 410 {
            throw IntentionError.notFound
        }
        guard code == 200 else {
            throw IntentionError.network("HTTP \(code)")
        }
        return try intentionsJSONDecoder().decode(Intention.self, from: data)
    }

    /// DELETE /intentions/{id} — soft delete. Returns true on 204.
    @discardableResult
    func deleteIntention(id: UUID) async -> Bool {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? -1) == 204
        } catch {
            return false
        }
    }

    // MARK: - Focus Toggle (Spec 1 — extended with intention_id)

    enum FocusToggleAction: String { case start, stop }

    struct FocusToggleResult {
        let sessionId: String?
        let status: String  // "started" | "stopped" | "no_active_session"
    }

    /// POST /focus/toggle. `intentionId` and `triggeredBy` are optional —
    /// when sent on start, the backend stamps focus_sessions.intention_id and
    /// pushes a silent APNs to peer iOS devices.
    @discardableResult
    func postFocusToggle(
        action: FocusToggleAction,
        intentionId: UUID? = nil,
        triggeredBy: String = "mac_manual"
    ) async -> FocusToggleResult? {
        guard let url = URL(string: "\(baseURL)/focus/toggle") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        var body: [String: Any] = [
            "action": action.rawValue,
            "triggered_by": triggeredBy,
        ]
        if let intentionId {
            body["intention_id"] = intentionId.uuidString
        }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return FocusToggleResult(
                sessionId: json["session_id"] as? String,
                status: json["status"] as? String ?? "unknown"
            )
        } catch {
            return nil
        }
    }

    // MARK: - Intention Strictness (Spec 3 — May 2026)

    enum StrictnessUpdateError: Error, LocalizedError {
        case requiresPartnerUnlock           // 423 from server
        case requires24hCooldown             // 425 from server
        case sessionInProgress               // 409 from server (D6)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .requiresPartnerUnlock: return "Stepping down from Strict requires partner unlock"
            case .requires24hCooldown:   return "Softening Standard→Soft is queued for 24h"
            case .sessionInProgress:     return "Cannot change strictness while a session of this focus mode is running"
            case .network(let s):        return s
            }
        }
    }

    /// PUT /intentions/{id}/strictness
    /// - 200 (instant tightening or queued softening — server returns updated Intention with optional pending_strictness_change)
    /// - 409 if a session is in progress (D6)
    /// - 423 if going from Strict requires partner unlock (caller must use partner flow)
    /// - 425 if Standard→Soft and the 24h cool-down was implicitly accepted (we still surface to UI as info)
    func updateIntentionStrictness(
        id: UUID,
        toPreset: StrictnessPreset,
        partnerUnlockCode: String? = nil
    ) async throws -> Intention {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)/strictness") else {
            throw StrictnessUpdateError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        var body: [String: Any] = ["to_preset": toPreset.rawValue]
        if let code = partnerUnlockCode { body["partner_unlock_code"] = code }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 200: return try intentionsJSONDecoder().decode(Intention.self, from: data)
        case 409: throw StrictnessUpdateError.sessionInProgress
        case 423: throw StrictnessUpdateError.requiresPartnerUnlock
        case 425: throw StrictnessUpdateError.requires24hCooldown
        default:  throw StrictnessUpdateError.network("HTTP \(code)")
        }
    }

    /// GET /intentions/{id}/strictness/pending → returns nil if none pending.
    /// Backend route confirmed in main.py (Plan A backend executor).
    func getPendingStrictnessChange(id: UUID) async -> PendingStrictnessChange? {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)/strictness/pending") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try intentionsJSONDecoder().decode(PendingStrictnessChange.self, from: data)
        } catch {
            return nil
        }
    }

    /// POST /intentions/{id}/strictness/cancel — cancel a queued softening.
    /// Backend route confirmed in main.py (Plan A backend executor). 204 on success, idempotent.
    @discardableResult
    func cancelPendingStrictnessChange(id: UUID) async -> Bool {
        guard let url = URL(string: "\(baseURL)/intentions/\(id.uuidString)/strictness/cancel") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? -1) == 204
        } catch { return false }
    }

    // MARK: - Intention Strictness Partner Unlock (NOT YET IMPLEMENTED ON BACKEND)
    //
    // KNOWN LIMITATION (overnight 2026-05-04): These endpoints are CALLED by the
    // Mac UI flow for Strict-step-down softening, but the backend (Plan A) explicitly
    // deferred the partner-unlock endpoints to a follow-up sprint. Until added:
    //   • requestIntentionStrictnessUnlock will throw (HTTP 404)
    //   • The Mac dialog will show an error toast
    //   • Strict-step-down is BLOCKED end-to-end (which is actually safer than
    //     auto-softening; users can use "Cancel" and stay Strict)
    //
    // To unblock: backend needs (see overnight log + plan A "What this plan does NOT do"):
    //   • Table: intention_strictness_unlock_requests (mirrors bedtime_unlock_requests)
    //   • POST /intention_strictness_unlock_requests — create + email partner code
    //   • POST /intention_strictness_unlock_requests/{id}/verify — verify code,
    //     stamp partner_unlocked_at on the matching pending row, scheduler then applies

    struct IntentionStrictnessUnlockRequestResult {
        let requestId: String
        let sentTo: String
    }

    func requestIntentionStrictnessUnlock(
        intentionId: UUID,
        toPreset: StrictnessPreset,
        reason: String,
        note: String?
    ) async throws -> IntentionStrictnessUnlockRequestResult {
        guard let url = URL(string: "\(baseURL)/intention_strictness_unlock_requests") else {
            throw StrictnessUpdateError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        var body: [String: Any] = [
            "intention_id": intentionId.uuidString,
            "to_preset": toPreset.rawValue,
            "reason": reason,
        ]
        if let note { body["note"] = note }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw StrictnessUpdateError.network("HTTP \(code) — partner-unlock endpoint not deployed yet") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rid = json["request_id"] as? String,
              let to = json["sent_to"] as? String else {
            throw StrictnessUpdateError.network("Malformed response")
        }
        return IntentionStrictnessUnlockRequestResult(requestId: rid, sentTo: to)
    }

    /// Verify the 6-digit code the partner emailed; on success the server flips strictness AND
    /// returns the updated Intention.
    /// NOT YET IMPLEMENTED ON BACKEND — see comment above.
    func verifyIntentionStrictnessUnlock(
        requestId: String,
        code: String
    ) async throws -> Intention {
        guard let url = URL(string: "\(baseURL)/intention_strictness_unlock_requests/\(requestId)/verify") else {
            throw StrictnessUpdateError.network("Bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, response) = try await URLSession.shared.data(for: req)
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else { throw StrictnessUpdateError.network("HTTP \(httpCode) — partner-unlock endpoint not deployed yet") }
        return try intentionsJSONDecoder().decode(Intention.self, from: data)
    }

    // MARK: - Time Blocks (Spec 2)

    struct TimeBlockDTO: Codable, Equatable {
        let block_id: String
        let title: String
        let block_type: String  // "deep_work" | "focus_hours" (legacy carryover)
        let intention_id: String?
        let intensity: String  // "deep_work" | "focus_hours"
        let start_hour: Int
        let start_minute: Int
        let end_hour: Int
        let end_minute: Int
        let active_days: [Int]   // ISO 1=Mon..7=Sun
        let enabled: Bool
        let updated_at: String?
    }

    struct TimeBlocksResponse: Codable {
        let blocks: [TimeBlockDTO]
    }

    /// GET /time_blocks — returns nil on network failure, [] when truly empty.
    func getTimeBlocks() async -> [TimeBlockDTO]? {
        guard let url = URL(string: "\(baseURL)/time_blocks") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(TimeBlocksResponse.self, from: data).blocks
        } catch {
            return nil
        }
    }

    /// PUT /time_blocks — atomic replace. Returns the new blocks list on success.
    @discardableResult
    func putTimeBlocks(_ blocks: [TimeBlockDTO]) async -> [TimeBlockDTO]? {
        guard let url = URL(string: "\(baseURL)/time_blocks") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let encoder = JSONEncoder()
            let blocksData = try encoder.encode(blocks)
            guard let blocksArray = try JSONSerialization.jsonObject(with: blocksData) as? [[String: Any]] else {
                return nil
            }
            let payload: [String: Any] = ["blocks": blocksArray]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(TimeBlocksResponse.self, from: data).blocks
        } catch {
            return nil
        }
    }
}

// MARK: - TLS Certificate Pinning

final class CertPinningDelegate: NSObject, URLSessionDelegate {
    let pinned: [String]

    init(pinned: [String]) { self.pinned = pinned }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Let system evaluate trust first (chain + expiry).
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Then check the leaf cert SHA-256 against our pinned list.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(leaf) as Data
        let fingerprint = data.sha256HexColons.uppercased()
        if pinned.map({ $0.uppercased() }).contains(fingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private extension Data {
    var sha256HexColons: String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(self.count), &hash)
        }
        return hash.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
