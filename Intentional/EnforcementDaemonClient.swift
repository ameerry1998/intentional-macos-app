//
//  EnforcementDaemonClient.swift
//  Intentional
//
//  Async wrapper around DaemonXPCClient.signEnforcement / verifyEnforcement.
//  Surfaces a clean `daemonAvailable` flag so callers can drop into the
//  degraded-mode fallback described in the spec §6.5.
//

import Foundation

final class EnforcementDaemonClient {
    private let daemonClient: DaemonXPCClient

    init(daemonClient: DaemonXPCClient) {
        self.daemonClient = daemonClient
    }

    /// True if the XPC connection looks healthy. Callers treat `false` as the
    /// degraded-mode signal (no daemon → ratchet-up-only mode, no cache signing).
    var daemonAvailable: Bool {
        daemonClient.isDaemonAvailable
    }

    /// Sign payload via daemon. Returns nil on any failure (daemon absent, key error).
    func sign(_ payload: Data) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            guard let proxy = daemonClient.proxyForEnforcement() else {
                continuation.resume(returning: nil)
                return
            }
            proxy.signEnforcement(payload: payload) { signature, _ in
                continuation.resume(returning: signature)
            }
        }
    }

    /// Verify signature via daemon. Returns false on any failure.
    func verify(payload: Data, signature: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard let proxy = daemonClient.proxyForEnforcement() else {
                continuation.resume(returning: false)
                return
            }
            proxy.verifyEnforcement(payload: payload, signature: signature) { ok in
                continuation.resume(returning: ok)
            }
        }
    }
}
