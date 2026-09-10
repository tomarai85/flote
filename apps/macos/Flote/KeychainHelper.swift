import Foundation
import Security

/// Keychain wrapper for the Anthropic API key.
/// The item is created by this app process; on sandboxed builds it is pinned
/// to the app's code signature. On un-sandboxed builds, access is gated only
/// by the user's login keychain unlock — this is a known limitation.
///
/// Security policy (2026-05-12, Track 3):
///   - DEBUG builds skip the user-presence ACL because re-signed dev
///     binaries would force a Touch ID prompt on every rebuild, blocking
///     iteration. The item is still pinned to
///     `kSecAttrAccessibleWhenUnlocked`, so login-keychain lock still
///     gates access.
///   - RELEASE builds require user-presence (Touch ID / password) AND
///     ThisDeviceOnly. If `SecAccessControlCreateWithFlags` fails for
///     any reason, the operation FAILS — there is no silent fallback to
///     a weaker storage class. Callers see `false` from `saveAPIKey`.
enum KeychainHelper {
    private static let service = "anthropic-api-key"
    private static let account = "flote"

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        // Delete any existing item first so our new one is owned by this process.
        _ = deleteAPIKey()

#if DEBUG
        // Debug builds have unstable code signatures (re-signed each build).
        // An ACL pinned to the signature would trigger a Keychain prompt on
        // every rebuild, so we skip SecAccessControl in development.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
#else
        // Release builds: kSecAttrAccessibleWhenUnlockedThisDeviceOnly —
        // login-keychain unlock gates access, no iCloud migration.
        //
        // S1 (2026-07-10, zero-interruption): the former `.userPresence`
        // SecAccessControl is deliberately REMOVED. It made every legacy
        // Organize fire a Touch ID prompt (the app's #1 interruption
        // complaint). Now that Organize is served on-device by default,
        // the Claude key is an optional power-user tier, and prompting for
        // biometrics on a background text call is the wrong trade: the item
        // is sandbox-scoped to this app's signature and this device. Note
        // encryption keys (NoteEncryption.swift) are unaffected.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
#endif
    }

    /// Existence check WITHOUT touching the secret. Metadata-only queries
    /// (no kSecReturnData) never hit the item's ACL/partition gate, so this
    /// can never raise a SecurityAgent password dialog. Callers that only
    /// need "is a key saved?" (Settings badge, provider routing) MUST use
    /// this — readAPIKey() on a foreign-signed item freezes the app behind
    /// a modal keychain prompt (live-fired 2026-07-11: opening the AI tab
    /// blocked the whole Settings window).
    static func hasAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        migrateLegacyACLItemIfNeeded(key: trimmed)
        return trimmed
    }

    /// One-time migration (Evaluator #3): keys saved by pre-S1 Release
    /// builds carry a `.userPresence` SecAccessControl ON THE ITEM — the new
    /// ACL-free save code doesn't touch existing items, so upgraders keep
    /// getting Touch ID prompts. On the first successful read (the user just
    /// authenticated, so we hold the plaintext), re-save the same key
    /// without the ACL. Flagged in UserDefaults so this runs exactly once.
    private static let aclMigrationDoneKey = "floteAPIKeyACLMigrated"

    private static func migrateLegacyACLItemIfNeeded(key: String) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: aclMigrationDoneKey), !key.isEmpty else { return }
        // delete + ACL-free re-save; saveAPIKey deletes first by design.
        if saveAPIKey(key) {
            defaults.set(true, forKey: aclMigrationDoneKey)
            print("[Flote] API key migrated off the user-presence ACL")
        }
    }

    @discardableResult
    static func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
