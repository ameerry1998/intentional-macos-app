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
