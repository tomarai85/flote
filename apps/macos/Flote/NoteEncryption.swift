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
                return "ノート暗号化キーの Keychain 保存に失敗しました (OSStatus=\(s))。"
            case .keychainReadFailed(let s):
                return "ノート暗号化キーの Keychain 読み出しに失敗しました (OSStatus=\(s))。"
            case .keyDataInvalid:
                return "ノート暗号化キーのデータ形式が壊れています。"
            case .sealFailed(let e):
                return "ノートの暗号化に失敗しました: \(e.localizedDescription)"
            case .openFailed(let e):
                return "ノートの復号に失敗しました: \(e.localizedDescription)"
            }
        }
    }

    private static let service = "com.tomtim.Flote.noteEncryptionKey"
    private static let account = "primary"

    // MARK: - Key lifecycle

    /// Returns the symmetric key from Keychain. If none exists, generates
    /// a fresh 256-bit key, stores it in Keychain, and returns it.
    static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try? readKey() {
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        try saveKey(fresh)
        return fresh
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
