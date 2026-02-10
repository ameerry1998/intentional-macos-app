//
//  BackendClient.swift
//  Intentional
//
//  Handles communication with backend API
//

import Foundation
import Cocoa

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
    }

    /// Request an unlock code from the backend
    func requestUnlock() async -> UnlockResult {
        let endpoint = "\(baseURL)/unlock/request"

        guard let url = URL(string: endpoint) else {
            return UnlockResult(success: false, message: "Invalid URL", statusCode: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [:] as [String: String])
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let msg = (parseJSON(data)?["message"] as? String) ?? errorMessage(from: data)
                if isSuccess(httpResponse.statusCode) {
                    return UnlockResult(success: true, message: msg, statusCode: httpResponse.statusCode)
                } else {
                    return UnlockResult(success: false, message: msg, statusCode: httpResponse.statusCode)
                }
            }
        } catch {
            return UnlockResult(success: false, message: error.localizedDescription, statusCode: 0)
        }
        return UnlockResult(success: false, message: "Unknown error", statusCode: 0)
    }

    // MARK: - Unlock Status

    struct StatusResult {
        let success: Bool
        let lockMode: String
        let partnerEmail: String?
        let consentStatus: String?
        let isLocked: Bool
        let isTemporarilyUnlocked: Bool
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
                    isTemporarilyUnlocked: json["is_temporarily_unlocked"] as? Bool ?? false
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
}
