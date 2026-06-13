import AppKit

/// Withholds VISIBLE coach actions (nudge/rescue) in contexts where interrupting
/// would be harmful or unwanted. plan_prompt is never suppressed here.
/// Conservative by design: prefer a missed nudge over a nudge mid-call.
enum CoachSuppression {
    /// Dedicated call/conferencing apps — if one is RUNNING, assume a call may be live.
    static let callBundleIds: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap" // Slack/Discord huddles
    ]

    static func isSuppressed(action: String, muted: Bool, escapeUntil: Date?,
                             lastNudgeAt: Date?, now: Date = Date()) -> Bool {
        guard action == "nudge" || action == "rescue" else { return false }
        if muted { return true }
        if let until = escapeUntil, now < until { return true }
        if isOnCallOrSharing() { return true }
        if action == "nudge", let last = lastNudgeAt, now.timeIntervalSince(last) < 3600 { return true }
        return false
    }

    /// A dedicated call app running, OR the screen is being shared/captured.
    static func isOnCallOrSharing() -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        if !running.isDisjoint(with: callBundleIds) { return true }
        return isScreenCaptured()
    }

    /// Logged once so we can confirm the real screen-capture key on this machine.
    private static var dumpedSessionKeys = false

    /// Screen recording / sharing active. Gates on `CGSSessionScreenIsCaptured`,
    /// the documented key for an active screen capture/share. Dumps the session
    /// dictionary keys once (first call) so we can verify the real key name on
    /// this macOS; if the key isn't present the running-call-app heuristic still
    /// covers the common case (a running Zoom suppresses).
    static func isScreenCaptured() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if !dumpedSessionKeys {
            dumpedSessionKeys = true
            NSLog("📡 CoachSuppression: CGSession keys = \(dict.keys.sorted())")
        }
        if let cap = dict["CGSSessionScreenIsCaptured"] as? Int, cap == 1 { return true }
        return false
    }
}
