//
//  HeartbeatService.swift
//  IntentionalDaemon
//
//  Sends independent heartbeats to the backend every 60 seconds.
//  This runs in the root daemon, so heartbeats continue even if the GUI app is killed.
//  If heartbeats stop, the backend knows the daemon was killed (requires sudo).
//

import Foundation

class HeartbeatService {

    private let baseURL = "https://api.intentional.social"
    private var timer: DispatchSourceTimer?
    private let config: ConfigManager
    private let interval: TimeInterval = 60  // Every 60 seconds

    init(config: ConfigManager) {
        self.config = config
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: interval)  // First heartbeat after 5s
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }
        timer.resume()
        self.timer = timer
        log("Heartbeat service started (every \(Int(interval))s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        log("Heartbeat service stopped")
    }

    /// Send a tamper event to the backend immediately.
    func reportTamper(eventType: String, detail: String) {
        guard let deviceId = config.deviceId else {
            log("Cannot report tamper: no device ID")
            return
        }

        let payload: [String: Any] = [
            "event_type": eventType,
            "detail": detail,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        postJSON(endpoint: "/content-safety/tamper", deviceId: deviceId, payload: payload) { success in
            log("Tamper report (\(eventType)): \(success ? "sent" : "failed")")
        }
    }

    // MARK: - Private

    private func sendHeartbeat() {
        guard let deviceId = config.deviceId else {
            log("Heartbeat skipped: no device ID configured")
            return
        }

        let payload: [String: Any] = [
            "type": "daemon_heartbeat",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "strict_mode": config.strictModeEnabled,
            "partner_locked": config.partnerLocked
        ]

        postJSON(endpoint: "/system-event", deviceId: deviceId, payload: payload) { [weak self] success in
            if success {
                self?.config.recordBackendHeartbeat()
            }
        }
    }

    private func postJSON(endpoint: String, deviceId: String, payload: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: baseURL + endpoint) else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        request.timeoutInterval = 10

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false)
            return
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                completion(true)
            } else {
                if let error = error {
                    log("Heartbeat error: \(error.localizedDescription)")
                }
                completion(false)
            }
        }.resume()
    }
}
