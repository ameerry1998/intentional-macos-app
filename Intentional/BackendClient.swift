//
//  BackendClient.swift
//  Intentional
//
//  Handles communication with backend API
//

import Foundation
import Cocoa
import Security

class BackendClient {

    private let baseURL: String
    private let deviceId: String

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

            if let httpResponse = response as? HTTPURLResponse {
                let appDelegate = NSApplication.shared.delegate as? AppDelegate
                if httpResponse.statusCode == 200 {
                    appDelegate?.postLog("✅ Event sent: \(type)")
                } else {
                    appDelegate?.postLog("⚠️ Event failed: \(type) - Status \(httpResponse.statusCode)")
                    if let body = String(data: data, encoding: .utf8) {
                        appDelegate?.postLog("   Response: \(body)")
                    }
                }
            }
        } catch {
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                appDelegate.postLog("❌ Network error sending event \(type): \(error.localizedDescription)")
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
        let selfUnlockAvailableAt: String?
    }

    /// Request an unlock code from the backend
    func requestUnlock() async -> UnlockResult {
        let endpoint = "\(baseURL)/unlock/request"

        guard let url = URL(string: endpoint) else {
            return UnlockResult(success: false, message: "Invalid URL", statusCode: 0, mode: nil, selfUnlockAvailableAt: nil)
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
                let sua = json?["self_unlock_available_at"] as? String
                if isSuccess(httpResponse.statusCode) {
                    return UnlockResult(success: true, message: msg, statusCode: httpResponse.statusCode, mode: mode, selfUnlockAvailableAt: sua)
                } else {
                    return UnlockResult(success: false, message: msg, statusCode: httpResponse.statusCode, mode: mode, selfUnlockAvailableAt: nil)
                }
            }
        } catch {
            return UnlockResult(success: false, message: error.localizedDescription, statusCode: 0, mode: nil, selfUnlockAvailableAt: nil)
        }
        return UnlockResult(success: false, message: "Unknown error", statusCode: 0, mode: nil, selfUnlockAvailableAt: nil)
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
            mode: currentMode,
            selfUnlockAvailableAt: nil
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
        let selfUnlockAvailableAt: String?
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
                    hasPendingRequest: json["has_pending_request"] as? Bool ?? false,
                    selfUnlockAvailableAt: json["self_unlock_available_at"] as? String
                )
            }
        } catch {
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            appDelegate?.postLog("⚠️ Failed to fetch unlock status: \(error.localizedDescription)")
        }
        return nil
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
    func authRefresh() async -> Bool {
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
                clearAuthTokens()
                return false
            }
        } catch {
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
}
