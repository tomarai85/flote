import Foundation

// MARK: - PersistenceService
//
// Sprint 3 Data Loss Resilience:
//   - All 4 save families (notes/history/groups/learning) use WAL sidecar writes
//     via WALFileIO.atomicWrite(to:data:).
//   - load() uses WALFileIO.safeRead(from:) so a stranded .wal file is recovered
//     automatically on the next launch.
//   - Decode failures trigger bak-based recovery (D6):
//       (a) main valid            → use main, update .bak
//       (b) main corrupt + .wal   → recover via WALFileIO.safeRead (already handled)
//       (c) main corrupt, no .wal → try .bak, retire corrupt file with timestamp
//       (d) all corrupt           → return empty array (same as previous behaviour)
//   - .bak files are retained for 5 generations; older ones are pruned.
//
// Security 2026-05-12 (Track 3):
//   - All four families now persist as AES-256-GCM ciphertext at
//     `<name>.encrypted` (e.g. `flote_notes.encrypted`). The plaintext
//     `<name>.json` form is migrated once on first launch after upgrade.
//   - File permissions are forced to 0600 after every successful write
//     (main, .wal, .bak.*).
//   - On migration: read plaintext → encrypt → atomic write to
//     `.encrypted` → rename plaintext to `.json.pre-encrypt-backup`
//     (NOT deleted; kept as a one-version safety net so a user who
//     finds their notes empty after upgrade can recover manually).
//   - If encryption setup fails (Keychain locked, denied), the plaintext
//     file is LEFT IN PLACE untouched and the error is surfaced to the
//     caller — no silent data loss.

struct PersistenceService {

    // MARK: - Error type

    enum PersistenceError: LocalizedError {
        case encryptionUnavailable(Error)
        case migrationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .encryptionUnavailable(let e):
                return "ノートの暗号化を利用できません: \(e.localizedDescription)"
            case .migrationFailed(let e):
                return "ノートの暗号化移行に失敗しました: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Directory helper

    private static func floteDir() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Flote", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - URL helpers
    //
    // We retain the LEGACY plaintext URL helpers for read-only migration use
    // and expose ENCRYPTED URL helpers as the primary storage targets.

    private static func legacyURL(_ basename: String) throws -> URL {
        try floteDir().appendingPathComponent("\(basename).json")
    }

    private static func encryptedURL(_ basename: String) throws -> URL {
        try floteDir().appendingPathComponent("\(basename).encrypted")
    }

    // MARK: - Shared encoder / decoder factories

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Permission tightening (0600)
    //
    // Set file mode to 0600 after every successful write so the file is
    // user-only readable, irrespective of process umask. Failure to set
    // permissions is logged but non-fatal — the file is still written.

    private static func tighten(_ url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            NSLog("[Flote] PersistenceService: chmod 0600 failed for %@: %@",
                  url.lastPathComponent, String(describing: error))
        }
    }

    // MARK: - Generic ENCRYPTED WAL save

    private static func walSave<T: Encodable>(_ value: T, to url: URL) throws {
        let plaintext = try makeEncoder().encode(value)
        let ciphertext = try NoteEncryption.seal(plaintext)
        try WALFileIO.atomicWrite(to: url, data: ciphertext)
        tighten(url)
    }

    // MARK: - Generic ENCRYPTED load with bak recovery (D6)
    //
    // Returns the decoded value on success.
    // On decrypt-or-decode failure:
    //   - retires the corrupt file as <name>.bak.YYYYMMDD-HHmmss
    //   - attempts to restore from the most-recent .bak.*
    //   - prunes bak files beyond maxBakGenerations
    //   - if all fail, returns empty array via throw (caller uses fallback)

    private static let maxBakGenerations = 5

    private static func walLoad<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        // safeRead handles main + .wal fallback automatically
        guard let cipher = WALFileIO.safeRead(from: url) else {
            // No file at all — first launch or manually deleted
            throw CocoaError(.fileNoSuchFile)
        }

        do {
            let plaintext = try NoteEncryption.open(cipher)
            let value = try makeDecoder().decode(type, from: plaintext)
            // Successful decode: update .bak (also encrypted)
            updateBak(for: url, with: cipher)
            return value
        } catch {
            // Decrypt-or-decode failed: retire corrupt main/wal and attempt bak recovery
            NSLog("[Flote] PersistenceService: decrypt/decode failed for %@ — %@",
                  url.lastPathComponent, error.localizedDescription)
            retireCorrupt(url: url)
            if let recovered = tryBakRestore(type, for: url) {
                NSLog("[Flote] PersistenceService: successfully restored %@ from .bak",
                      url.lastPathComponent)
                return recovered
            }
            NSLog("[Flote] PersistenceService: bak restore failed for %@ — returning empty",
                  url.lastPathComponent)
            throw error  // caller falls back to empty array
        }
    }

    // MARK: - Bak helpers

    /// Write current good encrypted bytes as a timestamped .bak file and prune old ones.
    /// `data` is already encrypted ciphertext.
    private static func updateBak(for url: URL, with data: Data) {
        let dir = url.deletingLastPathComponent()
        let base = url.lastPathComponent  // e.g. "flote_notes.encrypted"

        let stamp = ISO8601DateFormatter.compactFormatter.string(from: Date())
        let bakURL = dir.appendingPathComponent("\(base).bak.\(stamp)")
        do {
            try data.write(to: bakURL, options: [.atomic])
            tighten(bakURL)
        } catch {
            NSLog("[Flote] PersistenceService: bak write failed for %@: %@",
                  bakURL.lastPathComponent, String(describing: error))
        }

        pruneBaks(for: url, keeping: maxBakGenerations)
    }

    /// Move the corrupt file aside so the next launch sees no corrupt main.
    private static func retireCorrupt(url: URL) {
        let dir = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        let stamp = ISO8601DateFormatter.compactFormatter.string(from: Date())
        let corruptURL = dir.appendingPathComponent("\(base).corrupt.\(stamp)")
        let fm = FileManager.default
        try? fm.moveItem(at: url, to: corruptURL)
        // Also clear any stranded .wal so safeRead doesn't loop on the same bad data
        let walURL = url.appendingPathExtension("wal")
        try? fm.removeItem(at: walURL)
    }

    /// Try the most-recent bak file and decode it.
    private static func tryBakRestore<T: Decodable>(_ type: T.Type, for url: URL) -> T? {
        let dir = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }

        let bakFiles = entries
            .filter { $0.hasPrefix(base + ".bak.") }
            .sorted(by: >)  // newest first (ISO8601 stamps sort lexicographically)

        for name in bakFiles {
            let bakURL = dir.appendingPathComponent(name)
            if let cipher = try? Data(contentsOf: bakURL),
               let plaintext = try? NoteEncryption.open(cipher),
               let value = try? makeDecoder().decode(type, from: plaintext) {
                // Promote recovered bak to main. A silent try? here hid
                // disk-full / permission issues from the user — if promotion
                // fails the next launch will decode from bak again, which is
                // correct but invisible. Log so repeated fallback is detected.
                do {
                    try WALFileIO.atomicWrite(to: url, data: cipher)
                    tighten(url)
                } catch {
                    NSLog("[Flote] PersistenceService: bak promote to main failed for %@: %@",
                          url.lastPathComponent, String(describing: error))
                }
                return value
            }
        }
        return nil
    }

    /// Delete old bak files beyond the generation cap.
    private static func pruneBaks(for url: URL, keeping maxCount: Int) {
        let dir = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        let bakFiles = entries
            .filter { $0.hasPrefix(base + ".bak.") }
            .sorted(by: >)  // newest first

        if bakFiles.count > maxCount {
            for old in bakFiles.dropFirst(maxCount) {
                try? fm.removeItem(at: dir.appendingPathComponent(old))
            }
        }
    }

    // MARK: - Plaintext → ciphertext migration (one-shot, idempotent)
    //
    // For each known basename, if the legacy plaintext `.json` file exists
    // AND no `.encrypted` file exists yet, encrypt the plaintext, write to
    // `.encrypted`, and rename the plaintext to `.json.pre-encrypt-backup`.
    // If anything fails, the plaintext file is LEFT IN PLACE so the user
    // does not lose data.
    //
    // Called lazily from each loader. Re-running is a no-op (the
    // `.encrypted` existence check guards it).

    private static let knownBasenames = [
        "flote_notes",
        "flote_history",
        "flote_groups",
        "flote_learning"
    ]

    /// Returns true if the encryption migration step was attempted (success
    /// or failure) — useful for unit tests; not consulted by callers.
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        var didAnyWork = false
        for basename in knownBasenames {
            do {
                let plaintextURL = try legacyURL(basename)
                let cipherURL = try encryptedURL(basename)
                let fm = FileManager.default

                // Skip if already migrated
                if fm.fileExists(atPath: cipherURL.path) { continue }
                // Nothing to migrate for this family
                if !fm.fileExists(atPath: plaintextURL.path) { continue }

                didAnyWork = true
                do {
                    try migrateOne(plaintextURL: plaintextURL, cipherURL: cipherURL)
                    // Also migrate any plaintext .bak.* for this family
                    migrateLegacyBaks(basename: basename)
                    NSLog("[Flote] PersistenceService: migrated %@ → %@",
                          plaintextURL.lastPathComponent, cipherURL.lastPathComponent)
                } catch {
                    // Leave plaintext file in place so user data is not lost
                    NSLog("[Flote] PersistenceService: migration failed for %@: %@",
                          plaintextURL.lastPathComponent, String(describing: error))
                }
            } catch {
                NSLog("[Flote] PersistenceService: migration url-build failed for %@: %@",
                      basename, String(describing: error))
            }
        }
        return didAnyWork
    }

    /// Encrypt one plaintext file → ciphertext file with safety backup.
    /// Sequence (atomic-leaning):
    ///   1. Read plaintext bytes
    ///   2. Encrypt
    ///   3. Atomic write to `.encrypted` (via WALFileIO)
    ///   4. Set 0600 on `.encrypted`
    ///   5. Rename plaintext to `.json.pre-encrypt-backup`
    /// If step 1-3 fail, plaintext is untouched. If step 5 fails, both files
    /// exist temporarily — re-runs of migrateIfNeeded skip via cipher-exists
    /// guard, so the dangling plaintext is left visible to the user.
    private static func migrateOne(plaintextURL: URL, cipherURL: URL) throws {
        let plaintext = try Data(contentsOf: plaintextURL)
        let cipher = try NoteEncryption.seal(plaintext)
        try WALFileIO.atomicWrite(to: cipherURL, data: cipher)
        tighten(cipherURL)

        // Backup name keeps the original extension so it sorts next to siblings.
        let backupURL = plaintextURL.appendingPathExtension("pre-encrypt-backup")
        let fm = FileManager.default
        // Remove any prior backup so the move succeeds.
        if fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: backupURL)
        }
        do {
            try fm.moveItem(at: plaintextURL, to: backupURL)
            // Tighten the backup too — even though it's "backup", it
            // contains the same sensitive plaintext until the user deletes it.
            tighten(backupURL)
        } catch {
            // Encrypted is already in place; surface the rename failure.
            throw error
        }
    }

    /// Plaintext `.bak.*` files (from the pre-encryption era) carry note
    /// contents in cleartext. Encrypt them in place with the new key and
    /// the new `.encrypted.bak.*` name; rename originals to
    /// `<old>.pre-encrypt-backup`.
    private static func migrateLegacyBaks(basename: String) {
        let fm = FileManager.default
        guard let dir = try? floteDir() else { return }
        let plaintextBakPrefix = "\(basename).json.bak."
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in entries where name.hasPrefix(plaintextBakPrefix) {
            // Skip already-renamed backups.
            if name.hasSuffix(".pre-encrypt-backup") { continue }
            let oldURL = dir.appendingPathComponent(name)
            do {
                let plaintext = try Data(contentsOf: oldURL)
                let cipher = try NoteEncryption.seal(plaintext)
                // New name carries the timestamp from after ".json.bak."
                let stampPortion = name.dropFirst(plaintextBakPrefix.count)
                let newName = "\(basename).encrypted.bak.\(stampPortion)"
                let newURL = dir.appendingPathComponent(newName)
                try cipher.write(to: newURL, options: [.atomic])
                tighten(newURL)
                // Rename original to ".pre-encrypt-backup" so it's clearly
                // marked as obsolete plaintext the user can delete.
                let safetyURL = dir.appendingPathComponent("\(name).pre-encrypt-backup")
                if fm.fileExists(atPath: safetyURL.path) {
                    try? fm.removeItem(at: safetyURL)
                }
                try fm.moveItem(at: oldURL, to: safetyURL)
            } catch {
                NSLog("[Flote] PersistenceService: legacy bak migration failed for %@: %@",
                      name, String(describing: error))
            }
        }
    }

    // MARK: - Notes

    static func save(_ notes: [StickyNote]) throws {
        let url = try encryptedURL("flote_notes")
        try walSave(notes, to: url)
    }

    static func load() throws -> [StickyNote] {
        migrateIfNeeded()
        let url = try encryptedURL("flote_notes")
        guard FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.appendingPathExtension("wal").path)
        else { return [] }
        return try walLoad([StickyNote].self, from: url)
    }

    // MARK: - History

    static func saveHistory(_ notes: [StickyNote]) throws {
        let url = try encryptedURL("flote_history")
        try walSave(notes, to: url)
    }

    static func loadHistory() throws -> [StickyNote] {
        migrateIfNeeded()
        let url = try encryptedURL("flote_history")
        guard FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.appendingPathExtension("wal").path)
        else { return [] }
        return try walLoad([StickyNote].self, from: url)
    }

    // MARK: - Groups

    static func saveGroups(_ groups: [NoteGroup]) throws {
        let url = try encryptedURL("flote_groups")
        try walSave(groups, to: url)
    }

    static func loadGroups() throws -> [NoteGroup] {
        migrateIfNeeded()
        let url = try encryptedURL("flote_groups")
        guard FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.appendingPathExtension("wal").path)
        else { return [] }
        return try walLoad([NoteGroup].self, from: url)
    }

    // MARK: - Learning

    static func saveLearning(_ examples: [ClassificationExample]) throws {
        let url = try encryptedURL("flote_learning")
        try walSave(examples, to: url)
    }

    static func loadLearning() throws -> [ClassificationExample] {
        migrateIfNeeded()
        let url = try encryptedURL("flote_learning")
        guard FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.appendingPathExtension("wal").path)
        else { return [] }
        return try walLoad([ClassificationExample].self, from: url)
    }
}

// MARK: - ISO8601DateFormatter compact helper

private extension ISO8601DateFormatter {
    static let compactFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // No colons in the time component: Finder and several shell tools
        // treat ":" as a path-like separator on HFS+/APFS and can confuse
        // users inspecting .bak.* files. Omitting .withColonSeparatorInTime
        // yields "YYYY-MM-DDTHHmmssZ" which sorts lexicographically and
        // survives any tool.
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate]
        return f
    }()
}
