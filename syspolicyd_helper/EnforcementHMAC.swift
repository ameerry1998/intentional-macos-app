//
//  EnforcementHMAC.swift
//  syspolicyd_helper
//
//  HMAC-SHA256 key management for enforcement cache signing.
//  Key is generated lazily on first sign request and stored at
//  /var/root/intentional/enforcement_hmac_key (0600). Never transmitted.
//

import Foundation
import CryptoKit

final class EnforcementHMAC {
    private static let directoryURL = URL(fileURLWithPath: "/var/root/intentional", isDirectory: true)
    private static let keyURL = directoryURL.appendingPathComponent("enforcement_hmac_key")

    /// Load the key from disk, generating and persisting it if absent.
    static func loadOrGenerateKey() throws -> SymmetricKey {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700,
                .ownerAccountID: 0,  // root
            ])
        }

        if fm.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else {
                throw NSError(domain: "EnforcementHMAC", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Corrupt HMAC key (size \(data.count))"
                ])
            }
            return SymmetricKey(data: data)
        }

        var keyBytes = Data(count: 32)
        let status = keyBytes.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: "EnforcementHMAC", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "SecRandomCopyBytes failed: \(status)"
            ])
        }
        try keyBytes.write(to: keyURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return SymmetricKey(data: keyBytes)
    }

    /// HMAC-SHA256 of payload with the stored key. Returns raw 32-byte MAC.
    static func sign(payload: Data) throws -> Data {
        let key = try loadOrGenerateKey()
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(mac)
    }

    /// Returns true iff signature is a valid HMAC-SHA256 of payload under the stored key.
    static func verify(payload: Data, signature: Data) throws -> Bool {
        let key = try loadOrGenerateKey()
        let expected = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return Data(expected) == signature
    }
}
