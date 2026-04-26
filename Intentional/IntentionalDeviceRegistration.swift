import Foundation
import IOKit

/// One-shot registration of this Mac with the Intentional backend.
/// Called after we have a valid access token. Idempotent on the server side.
final class IntentionalDeviceRegistration {
    static let shared = IntentionalDeviceRegistration()
    private init() {}

    private let storedDeviceIdKey = "intentional_backend_mac_device_id"

    var storedDeviceId: String? {
        UserDefaults.standard.string(forKey: storedDeviceIdKey)
    }

    /// Register this Mac. Pass the current access token (intentional JWT or Supabase JWT).
    /// Fire-and-forget: errors are logged via the `log` callback, never thrown.
    ///
    /// On 401 the registration self-recovers by calling `onAuthExpired` (if
    /// provided), expecting the caller to refresh the token and re-invoke
    /// `registerIfNeeded`. Without this, an expired access token causes
    /// device registration to fail forever — and because the WebSocket auth
    /// uses the same token, cross-device focus signals stop working until
    /// the user manually signs out and back in.
    func registerIfNeeded(
        token: String,
        log: @escaping (String) -> Void,
        onAuthExpired: (() -> Void)? = nil
    ) {
        guard !token.isEmpty else { return }

        #if DEBUG
        let base = "http://localhost:8000"
        #else
        let base = "https://api.intentional.social"
        #endif
        guard let url = URL(string: "\(base)/devices/register") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        let name = Host.current().localizedName ?? "Mac"
        let body: [String: Any] = [
            "device_type": "mac",
            "device_name": name,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let storedKey = self.storedDeviceIdKey
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                log("🔌 DeviceRegister failed: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                log("🔌 DeviceRegister non-2xx status: \(code)")
                if code == 401, let recover = onAuthExpired {
                    log("🔌 DeviceRegister: triggering token refresh")
                    DispatchQueue.main.async { recover() }
                }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("🔌 DeviceRegister: bad response body")
                return
            }
            if let deviceId = json["device_id"] as? String {
                UserDefaults.standard.set(deviceId, forKey: storedKey)
                log("🔌 DeviceRegister OK: device_id=\(deviceId)")
            } else {
                log("🔌 DeviceRegister: no device_id in response")
            }
        }.resume()
    }
}
