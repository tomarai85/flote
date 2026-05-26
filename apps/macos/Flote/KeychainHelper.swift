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
        // Release builds use a stable commercial code signature.
        // SecAccessControl with kSecAccessControlUserPresence requires the
        // user to authenticate (Touch ID / password) before this app can
        // read the item, even if the keychain is already unlocked.
        // kSecAttrAccessibleWhenUnlockedThisDeviceOnly prevents the item from
        // migrating to other devices via iCloud Keychain backup.
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            // Fail closed: no weak fallback. The original 2026-05 implementation
            // silently fell back to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
            // WITHOUT the user-presence ACL — which means any process running as
            // the user (after login) could read the API key with no Touch ID
            // prompt. That defeated the entire purpose of the ACL. We now refuse
            // to store the key at all rather than store it under weaker terms
            // than the user expects.
            print("[Flote] SecAccessControlCreateWithFlags failed (fail-closed): \(String(describing: error))")
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
#endif
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
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
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
