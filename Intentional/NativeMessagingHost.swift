import Foundation

/// Handles Native Messaging protocol for Chrome/Firefox extension communication
/// Protocol: 4-byte little-endian length prefix + JSON message
class NativeMessagingHost {

    weak var appDelegate: AppDelegate?
    weak var timeTracker: TimeTracker?

    private var inputHandle: FileHandle?
    private var isRunning = false
    private let messageQueue = DispatchQueue(label: "com.intentional.nativemessaging", qos: .userInitiated)

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Start listening for messages from the extension
    func start() {
        guard !isRunning else { return }
        isRunning = true

        inputHandle = FileHandle.standardInput

        messageQueue.async { [weak self] in
            self?.readLoop()
        }

        appDelegate?.postLog("🔌 Native Messaging host started")
    }

    /// Stop the messaging host
    func stop() {
        isRunning = false
        appDelegate?.postLog("🔌 Native Messaging host stopped")
    }

    /// Main read loop - reads messages from stdin
    private func readLoop() {
        while isRunning {
            guard let message = readMessage() else {
                // Extension disconnected or error
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            handleMessage(message)
        }
    }

    /// Read a single message from stdin using Native Messaging protocol
    private func readMessage() -> [String: Any]? {
        guard let inputHandle = inputHandle else { return nil }

        // Read 4-byte length prefix (little-endian)
        let lengthData = inputHandle.readData(ofLength: 4)
        guard lengthData.count == 4 else { return nil }

        let length = lengthData.withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).littleEndian
        }

        // Sanity check - messages shouldn't be huge
        guard length > 0 && length < 1_000_000 else { return nil }

        // Read the JSON message
        let jsonData = inputHandle.readData(ofLength: Int(length))
        guard jsonData.count == Int(length) else { return nil }

        // Parse JSON
        do {
            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                return json
            }
        } catch {
            appDelegate?.postLog("❌ Native Messaging: Failed to parse JSON: \(error)")
        }

        return nil
    }

    /// Send a message to the extension via stdout
    func sendMessage(_ message: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: message)

            // Write 4-byte length prefix (little-endian)
            var length = UInt32(jsonData.count).littleEndian
            let lengthData = Data(bytes: &length, count: 4)

            FileHandle.standardOutput.write(lengthData)
            FileHandle.standardOutput.write(jsonData)

        } catch {
            appDelegate?.postLog("❌ Native Messaging: Failed to send message: \(error)")
        }
    }

    /// Handle incoming message from extension
    private func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else {
            appDelegate?.postLog("⚠️ Native Messaging: Message missing type")
            return
        }

        switch type {
        case "PING":
            // Simple ping/pong for connection testing
            sendMessage(["type": "PONG", "timestamp": Date().timeIntervalSince1970])

        case "TIME_UPDATE":
            // Extension reporting time spent on site
            handleTimeUpdate(message)

        case "SESSION_START":
            // Extension starting a session
            handleSessionStart(message)

        case "SESSION_END":
            // Extension ending a session
            handleSessionEnd(message)

        case "GET_STATUS":
            // Extension requesting current status
            sendStatus()

        default:
            appDelegate?.postLog("⚠️ Native Messaging: Unknown message type: \(type)")
        }
    }

    /// Handle time update from extension
    private func handleTimeUpdate(_ message: [String: Any]) {
        guard let platform = message["platform"] as? String,
              let browser = message["browser"] as? String,
              let seconds = message["seconds"] as? Int else {
            appDelegate?.postLog("⚠️ Native Messaging: Invalid TIME_UPDATE message")
            return
        }

        let isVideoPlaying = message["isVideoPlaying"] as? Bool ?? false
        let url = message["url"] as? String

        // Forward to TimeTracker
        DispatchQueue.main.async { [weak self] in
            self?.timeTracker?.recordTime(
                platform: platform,
                browser: browser,
                seconds: seconds,
                isVideoPlaying: isVideoPlaying,
                url: url
            )

            // Check if budget exceeded and notify extension
            if let tracker = self?.timeTracker, tracker.isBudgetExceeded(for: platform) {
                self?.sendMessage([
                    "type": "BUDGET_EXCEEDED",
                    "platform": platform,
                    "minutesUsed": tracker.getMinutesUsed(for: platform),
                    "budgetMinutes": tracker.getBudget(for: platform)
                ])
            }
        }
    }

    /// Handle session start from extension
    private func handleSessionStart(_ message: [String: Any]) {
        guard let platform = message["platform"] as? String,
              let browser = message["browser"] as? String else { return }

        let intent = message["intent"] as? String

        DispatchQueue.main.async { [weak self] in
            self?.timeTracker?.startSession(platform: platform, browser: browser, intent: intent)
            self?.appDelegate?.postLog("🎬 Session started: \(platform) on \(browser)")
        }
    }

    /// Handle session end from extension
    private func handleSessionEnd(_ message: [String: Any]) {
        guard let platform = message["platform"] as? String,
              let browser = message["browser"] as? String else { return }

        DispatchQueue.main.async { [weak self] in
            self?.timeTracker?.endSession(platform: platform, browser: browser)
            self?.appDelegate?.postLog("🛑 Session ended: \(platform) on \(browser)")
        }
    }

    /// Send current status to extension
    private func sendStatus() {
        guard let tracker = timeTracker else { return }

        sendMessage([
            "type": "STATUS",
            "youtube": [
                "minutesUsed": tracker.getMinutesUsed(for: "youtube"),
                "budgetMinutes": tracker.getBudget(for: "youtube"),
                "isExceeded": tracker.isBudgetExceeded(for: "youtube")
            ],
            "instagram": [
                "minutesUsed": tracker.getMinutesUsed(for: "instagram"),
                "budgetMinutes": tracker.getBudget(for: "instagram"),
                "isExceeded": tracker.isBudgetExceeded(for: "instagram")
            ],
            "timestamp": Date().timeIntervalSince1970
        ])
    }
}
