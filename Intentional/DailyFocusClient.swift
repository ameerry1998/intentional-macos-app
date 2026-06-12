import Foundation

/// Creates the backend daily_focus row best-effort. Returns nil offline —
/// the session works identically without it (spec: graceful degradation).
enum DailyFocusClient {
    static func create(title: String, linkedIntentionId: UUID?, via: String,
                       backend: BackendClient?) async -> UUID? {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return await backend?.createDailyFocus(
            localDate: fmt.string(from: Date()),
            title: String(title.prefix(60)),
            intentText: String(title.prefix(140)),
            linkedIntentionId: linkedIntentionId, createdVia: via)
    }
}
