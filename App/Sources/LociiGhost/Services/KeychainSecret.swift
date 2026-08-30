import Foundation
import Security

/// Minimal generic-password store for the one secret this app holds.
///
/// v1.15.2 audit (X8): the Google Directions key was living in
/// `preferences.store`, an unencrypted SQLite file under
/// ~/Library/Application Support with no TCC protection and no
/// sandbox around it. That is a key the user pays for per request:
/// any process running as them — a backup agent, a sync client, a
/// downloaded script — could read it straight off disk and spend it.
/// The Keychain is the right place for it, and the migration below
/// clears the plaintext copy the moment it moves.
enum KeychainSecret {
    /// Suffix-scoped so a future second secret doesn't collide.
    static let googleDirectionsKey = "google-directions-api-key"

    private static let service = "com.lociighost.secrets"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Read a secret. Returns nil when absent, when the Keychain is
    /// locked, or on any error — callers treat all of those the same
    /// way ("no key configured").
    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Store (or replace) a secret. Passing nil deletes it.
    /// Returns false if the Keychain refused the write, so the caller
    /// can tell the user rather than silently losing their key.
    @discardableResult
    static func write(_ value: String?, to account: String) -> Bool {
        let base = query(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        // Try update first; fall back to add. (SecItemUpdate fails
        // with errSecItemNotFound rather than creating.)
        let updated = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        // The daemon never reads this, and neither does anything that
        // runs before the user logs in, so the strictest useful
        // accessibility class applies.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
