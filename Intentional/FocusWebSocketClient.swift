import Foundation

class FocusWebSocketClient {

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var token: String?
    private var reconnectDelay: TimeInterval = 5.0
    private var maxReconnectDelay: TimeInterval = 60.0
    private var isIntentionallyDisconnected = false

    /// Called when a focus signal is received from the backend
    /// Parameters: action ("start" or "stop"), sessionId
    var onFocusSignal: ((_ action: String, _ sessionId: String) -> Void)?

    /// Called when connection state changes
    var onConnectionStateChanged: ((_ connected: Bool) -> Void)?

    private(set) var isConnected = false

    // Backend URL — change for production
    private let baseURL: String = {
        #if DEBUG
        return "ws://localhost:8000"
        #else
        return "wss://api.intentional.social"
        #endif
    }()

    func connect(token: String) {
        self.token = token
        self.isIntentionallyDisconnected = false
        self.reconnectDelay = 5.0
        establishConnection()
    }

    func disconnect() {
        isIntentionallyDisconnected = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        onConnectionStateChanged?(false)
    }

    func reconnect(token: String) {
        self.token = token
        disconnect()
        isIntentionallyDisconnected = false
        reconnectDelay = 5.0
        establishConnection()
    }

    // MARK: - Private

    private func establishConnection() {
        guard let token = token, !isIntentionallyDisconnected else { return }

        let url = URL(string: "\(baseURL)/ws/focus")!
        urlSession = URLSession(configuration: .default)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // Send JWT as first message for authentication
        webSocketTask?.send(.string(token)) { [weak self] error in
            if let error = error {
                print("[WS] Auth send failed: \(error)")
                self?.scheduleReconnect()
                return
            }
            // Start receiving messages
            self?.receiveMessage()
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                // Keep listening
                self.receiveMessage()

            case .failure(let error):
                print("[WS] Receive error: \(error)")
                self.isConnected = false
                DispatchQueue.main.async { self.onConnectionStateChanged?(false) }
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("[WS] Failed to parse message: \(text)")
            return
        }

        switch type {
        case "authenticated":
            print("[WS] Authenticated successfully")
            isConnected = true
            reconnectDelay = 5.0 // Reset backoff on successful connection
            DispatchQueue.main.async { self.onConnectionStateChanged?(true) }

        case "error":
            let message = json["message"] as? String ?? "Unknown error"
            print("[WS] Server error: \(message)")
            // Auth failure — don't reconnect (token is bad)
            isConnected = false
            DispatchQueue.main.async { self.onConnectionStateChanged?(false) }

        case "focus_signal":
            let action = json["action"] as? String ?? ""
            let sessionId = json["session_id"] as? String ?? ""
            print("[WS] Focus signal: \(action) session=\(sessionId)")
            DispatchQueue.main.async {
                self.onFocusSignal?(action, sessionId)
            }

        default:
            print("[WS] Unknown message type: \(type)")
        }
    }

    private func scheduleReconnect() {
        guard !isIntentionallyDisconnected else { return }

        print("[WS] Reconnecting in \(reconnectDelay)s...")
        DispatchQueue.global().asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self = self, !self.isIntentionallyDisconnected else { return }
            self.establishConnection()
        }

        // Exponential backoff: 5 → 10 → 20 → 40 → 60 (cap)
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
    }

    /// Send a heartbeat to keep the connection alive and update last_seen
    func sendHeartbeat(sessionId: String) {
        let msg = "{\"type\":\"focus_heartbeat\",\"session_id\":\"\(sessionId)\",\"state\":\"active\"}"
        webSocketTask?.send(.string(msg)) { error in
            if let error = error {
                print("[WS] Heartbeat send failed: \(error)")
            }
        }
    }
}
