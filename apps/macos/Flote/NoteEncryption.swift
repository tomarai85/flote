import Foundation
import CryptoKit
import Security

/// Symmetric encryption helper for at-rest note storage.
///
/// - Algorithm: AES-256-GCM via CryptoKit `AES.GCM.SealedBox`.
/// - Key: 256-bit symmetric, generated once on first use, persisted in the
///   macOS Keychain as a generic password under service
///   `com.tomtim.Flote.noteEncryptionKey`.
/// - Accessibility: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` —
///   the key cannot migrate to other devices via iCloud Keychain and is
///   only readable while the user's login keychain is unlocked.
/// - File layout: ciphertext is the SealedBox `.combined` representation
///   (nonce || ciphertext || tag) written directly to disk. No magic
///   header / version byte today; if we ever need format evolution, a
///   one-byte version prefix can be added (existing files would still
///   decrypt by the absence-of-prefix branch).
///
/// Failure mode: if Keychain access fails (locked keychain, denied ACL,
/// missing entitlement), `loadOrCreateKey()` throws `NoteEncryptionError`
/// to the caller — the caller MUST surface the error to the user rather
/// than silently degrading to plaintext. Persistence migration uses this
/// to keep the legacy plaintext file untouched.
enum NoteEncryption {

    enum NoteEncryptionError: LocalizedError {
        case keychainSaveFailed(OSStatus)
        case keychainReadFailed(OSStatus)
        case keyDataInvalid
        case sealFailed(Error)
        case openFailed(Error)

        var errorDescription: String? {
            switch self {
            case .keychainSaveFailed(let s):
                return LN("ノート暗号化キーの Keychain 保存に失敗しました", "Could not save the note encryption key to the Keychain") + " (OSStatus=\(s))"
            case .keychainReadFailed(let s):
                return LN("ノート暗号化キーの Keychain 読み出しに失敗しました", "Could not read the note encryption key from the Keychain") + " (OSStatus=\(s))"
            case .keyDataInvalid:
                return LN("ノート暗号化キーのデータ形式が壊れています。", "The note encryption key data is malformed.")
            case .sealFailed(let e):
                return LN("ノートの暗号化に失敗しました: ", "Could not encrypt the note: ") + e.localizedDescription
            case .openFailed(let e):
                return LN("ノートの復号に失敗しました: ", "Could not decrypt the note: ") + e.localizedDescription
            }
        }
    }

    private static let service = "com.tomtim.Flote.noteEncryptionKey"
    private static let account = "primary"

    // MARK: - Key lifecycle

    #if DEBUG
    /// Test-only hook: when set, seal/open use this key and never touch the
    /// Keychain. The standalone persistence harness (.harness/tests/) runs as
    /// an unsigned CLI binary — reading the app's Keychain item from there
    /// would trigger a consent prompt or a denial, so tests inject a fixed
    /// key instead. Compiled out of Release builds.
    nonisolated(unsafe) static var overrideKeyForTesting: SymmetricKey?
    #endif

    /// Returns the symmetric key from Keychain. If none exists, generates
    /// a fresh 256-bit key, stores it in Keychain, and returns it.
    static func loadOrCreateKey() throws -> SymmetricKey {
        #if DEBUG
        if let testKey = overrideKeyForTesting {
            return testKey
        }
        #endif
        do {
            return try readKey()
        } catch NoteEncryptionError.keychainReadFailed(let status)
            where status == errSecItemNotFound {
            // Genuinely no key yet (true first run) — safe to mint one.
            let fresh = SymmetricKey(size: .bits256)
            try saveKey(fresh)
            return fresh
        }
        // Any OTHER failure (access denied, interaction not allowed,
        // keychain locked…) means a key EXISTS but we cannot read it.
        // Fail CLOSED: minting a replacement here silently orphans every
        // existing ciphertext — it fired once (2026-07-10 12:56 JST, the
        // flote_groups .corrupt quarantine) when a re-signed build was
        // denied access. Data loss, never again.
    }

    private static func readKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw NoteEncryptionError.keychainReadFailed(status)
        }
        guard let data = item as? Data, data.count == 32 else {
            throw NoteEncryptionError.keyDataInvalid
        }
        return SymmetricKey(data: data)
    }

    private static func saveKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        // Delete any existing item to keep the add idempotent.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // ThisDeviceOnly: do not back up to iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NoteEncryptionError.keychainSaveFailed(status)
        }
    }

    // MARK: - Seal / open

    /// Encrypt `plaintext` with the key from Keychain. Returns the
    /// SealedBox `.combined` representation: nonce(12) || ciphertext(N) || tag(16).
    static func seal(_ plaintext: Data) throws -> Data {
        let key = try loadOrCreateKey()
        do {
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else {
                throw NoteEncryptionError.sealFailed(
                    NSError(domain: "NoteEncryption", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "combined nil"])
                )
            }
            return combined
        } catch {
            throw NoteEncryptionError.sealFailed(error)
        }
    }

    /// Decrypt `ciphertext` (combined form) using the key from Keychain.
    static func open(_ ciphertext: Data) throws -> Data {
        let key = try loadOrCreateKey()
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw NoteEncryptionError.openFailed(error)
        }
    }

    // MARK: - Diagnostics / first-run probe

    /// Returns true if the encryption key already exists in Keychain.
    /// Used by the migration step to distinguish first-launch-after-upgrade
    /// from a returning-user state.
    static func keyExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
