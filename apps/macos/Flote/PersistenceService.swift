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
                return LN("ノートの暗号化を利用できません: ", "Note encryption is unavailable: ") + e.localizedDescription
            case .migrationFailed(let e):
                return LN("ノートの暗号化移行に失敗しました: ", "Encryption migration failed: ") + e.localizedDescription
            }
        }
    }

    // MARK: - Directory helper

    #if DEBUG
    /// Test-only hook: when set, all storage roots resolve under this URL
    /// instead of ~/Library/Application Support/Flote. Lets the standalone
    /// persistence harness (.harness/tests/) exercise migration against a
    /// temp directory. Compiled out of Release builds.
    nonisolated(unsafe) static var overrideRootForTesting: URL?
    #endif

    private static func floteDir() throws -> URL {
        #if DEBUG
        if let override = overrideRootForTesting {
            if !FileManager.default.fileExists(atPath: override.path) {
                try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            }
            return override
        }
        #endif
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

    /// Subdirectory of the Flote root, created on demand.
    private static func subdir(_ name: String) throws -> URL {
        let dir = try floteDir().appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path
            )
        }
        return dir
    }

    // MARK: - Per-note store v2 directories (S2)
    //
    // notes-v2/<uuid>.encrypted          — one active StickyNote per file
    // recently-deleted/<uuid>.encrypted  — soft-deleted notes (30-day retention)
    //
    // Rationale: the combined-array store meant one corrupt byte risked ALL
    // notes; per-note files bound the blast radius of any corruption to a
    // single note, and each file keeps its own .wal + .bak.* lineage.
    // Format is platform-agnostic (plain AES-GCM-sealed JSON per note).

    private static let notesV2DirName = "notes-v2"
    private static let recentlyDeletedDirName = "recently-deleted"

    static func notesV2Dir() throws -> URL { try subdir(notesV2DirName) }
    static func recentlyDeletedDir() throws -> URL { try subdir(recentlyDeletedDirName) }

    private static func noteURL(_ id: UUID) throws -> URL {
        try notesV2Dir().appendingPathComponent("\(id.uuidString).encrypted")
    }

    private static func deletedNoteURL(_ id: UUID) throws -> URL {
        try recentlyDeletedDir().appendingPathComponent("\(id.uuidString).encrypted")
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
        } catch let error as NoteEncryption.NoteEncryptionError {
            // Key ACCESS failure is not data corruption (Evaluator r3 #2):
            // a denied/locked keychain must abort the load untouched — the
            // 2026-07-10 12:56 quarantine retired a perfectly good store.
            if case .keychainReadFailed = error {
                NSLog("[Flote] PersistenceService: keychain denied for %@ — store left intact",
                      url.lastPathComponent)
                throw error
            }
            NSLog("[Flote] PersistenceService: decrypt/decode failed for %@ — %@",
                  url.lastPathComponent, error.localizedDescription)
            retireCorrupt(url: url)
            if let recovered = tryBakRestore(type, for: url) {
                return recovered
            }
            throw error
        } catch {
            // Decode failed on a successfully decrypted payload: retire and
            // attempt bak recovery.
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

    // MARK: - Per-note store v2 API (S2)

    /// Persist one note to notes-v2/<uuid>.encrypted (WAL + fsync + rename,
    /// 0600, same crash-safety as the combined store had).
    static func saveNote(_ note: StickyNote) throws {
        let url = try noteURL(note.id)
        try walSave(note, to: url)
    }

    /// Remove a note's per-note file plus its .wal and .bak.* lineage.
    /// Callers MUST have secured a durable copy elsewhere first (softDelete
    /// does) — this is the only code that erases active-note bytes.
    static func deleteNoteFile(id: UUID) throws {
        let url = try noteURL(id)
        removeArtifacts(for: url)
    }

    /// Load every decodable note from notes-v2/. FAIL-CLOSED PER FILE: a
    /// corrupt file is retired to .corrupt.* (with a bak-restore attempt)
    /// and never aborts loading the remaining notes — that containment is
    /// the whole point of per-note storage vs the combined array.
    /// Returned notes are sorted by createdAt ascending (stable order for
    /// downstream zOrder/index logic; the old combined array was insertion-
    /// ordered which approximates the same).
    static func loadAllNotesV2() throws -> [StickyNote] {
        let dir = try notesV2Dir()
        return try loadAllNotes(in: dir).sorted { $0.createdAt < $1.createdAt }
    }

    /// Soft-delete: stamp deletedAt, durably write the note into
    /// recently-deleted/, and only THEN remove the active per-note file.
    /// If the durable write fails, the active file is untouched and the
    /// error is thrown — no code path drops a note silently.
    @discardableResult
    static func softDelete(note: StickyNote) throws -> StickyNote {
        var stamped = note
        stamped.deletedAt = Date()
        let deletedURL = try deletedNoteURL(note.id)
        try walSave(stamped, to: deletedURL)
        // Durable copy secured — now erase the active file (best-effort;
        // a leftover active file only means the note resurrects on next
        // launch, which errs on the keep-data side).
        do {
            try deleteNoteFile(id: note.id)
        } catch {
            NSLog("[Flote] PersistenceService: softDelete cleanup failed for %@: %@",
                  note.id.uuidString, String(describing: error))
        }
        return stamped
    }

    /// Restore a soft-deleted note: clear deletedAt, write it back into
    /// notes-v2/ FIRST, then remove the recently-deleted copy. Returns nil
    /// if no recoverable copy exists for the id.
    static func restoreDeleted(id: UUID) throws -> StickyNote? {
        let deletedURL = try deletedNoteURL(id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: deletedURL.path)
                || fm.fileExists(atPath: deletedURL.appendingPathExtension("wal").path)
        else { return nil }
        // Clobber guard (S2 review #1): if an ACTIVE note already owns this
        // id (duplicated ids from an old history bug), restoring would
        // overwrite the active note's file = data loss. Fail closed: keep
        // the deleted copy recoverable, never clobber the active note.
        if fm.fileExists(atPath: try noteURL(id).path) {
            throw CocoaError(.fileWriteFileExists,
                             userInfo: [NSLocalizedDescriptionKey:
                                "同じ ID のノートが既に存在するため復元できません（データ保護のため中止）"])
        }
        var note = try walLoad(StickyNote.self, from: deletedURL)
        note.deletedAt = nil
        try saveNote(note)          // active copy durable first
        removeArtifacts(for: deletedURL)
        return note
    }

    /// Load every decodable note from recently-deleted/, newest deletion
    /// first. Corrupt files are retired per-file, never aborting the rest.
    static func loadRecentlyDeleted() throws -> [StickyNote] {
        let dir = try recentlyDeletedDir()
        return try loadAllNotes(in: dir).sorted {
            ($0.deletedAt ?? $0.modifiedAt) > ($1.deletedAt ?? $1.modifiedAt)
        }
    }

    /// Permanently remove recently-deleted notes whose deletedAt is older
    /// than `olderThan` (default 30 days). Files that cannot be decoded are
    /// left alone here — walLoad already retires corrupt files to .corrupt.*
    /// on read, and purge must never be the thing that destroys the last
    /// readable copy by guessing.
    static func purgeExpiredDeleted(olderThan interval: TimeInterval = 30 * 24 * 60 * 60) {
        guard let dir = try? recentlyDeletedDir() else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        for url in encryptedFileURLs(in: dir) {
            guard let cipher = WALFileIO.safeRead(from: url),
                  let plaintext = try? NoteEncryption.open(cipher),
                  let note = try? makeDecoder().decode(StickyNote.self, from: plaintext)
            else { continue }
            let deletedStamp = note.deletedAt ?? note.modifiedAt
            if deletedStamp < cutoff {
                removeArtifacts(for: url)
                NSLog("[Flote] PersistenceService: purged expired deleted note %@ (deletedAt %@)",
                      url.lastPathComponent, String(describing: deletedStamp))
            }
        }
    }

    /// Permanently empty the recently-deleted store (user-confirmed
    /// "clear all" in Settings).
    static func purgeAllDeleted() {
        guard let dir = try? recentlyDeletedDir() else { return }
        for url in encryptedFileURLs(in: dir) {
            removeArtifacts(for: url)
        }
    }

    // MARK: Per-note store internals

    /// All main `.encrypted` files in a directory (excludes .wal/.bak/.corrupt
    /// sidecars, whose names never END in ".encrypted").
    private static func encryptedFileURLs(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries
            .filter { $0.hasSuffix(".encrypted") }
            .map { dir.appendingPathComponent($0) }
    }

    /// Decode every note file in `dir`, skipping (and retiring) corrupt ones.
    private static func loadAllNotes(in dir: URL) throws -> [StickyNote] {
        var notes: [StickyNote] = []
        var seen = Set<UUID>()
        var keychainDenials = 0
        var visited = 0
        // Also consider orphaned .wal sidecars whose main file vanished —
        // safeRead inside walLoad handles promotion, but only if we visit
        // the main URL, so derive main URLs from stranded .wal names too.
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var mainNames = Set(entries.filter { $0.hasSuffix(".encrypted") })
        for name in entries where name.hasSuffix(".encrypted.wal") {
            mainNames.insert(String(name.dropLast(4)))  // strip ".wal"
        }
        for name in mainNames.sorted() {
            let url = dir.appendingPathComponent(name)
            do {
                let note = try walLoad(StickyNote.self, from: url)
                // Guard duplicate ids (e.g. a hand-copied file): first wins.
                if seen.insert(note.id).inserted {
                    notes.append(note)
                } else {
                    NSLog("[Flote] PersistenceService: duplicate note id in %@ — skipped", name)
                }
            } catch let error as NoteEncryption.NoteEncryptionError {
                if case .keychainReadFailed = error { keychainDenials += 1 }
                NSLog("[Flote] PersistenceService: skipping note file %@: %@",
                      name, String(describing: error))
            } catch {
                // walLoad already retired the corrupt file and attempted a
                // .bak restore. One bad note must not block the rest.
                NSLog("[Flote] PersistenceService: skipping unrecoverable note file %@: %@",
                      name, String(describing: error))
            }
            visited += 1
        }
        // Fail LOUDLY, not empty (r3b NEW-3): when every note failed on
        // keychain access, "no notes" is a lie — the store is fine and the
        // app just can't unlock it. Surfacing beats silently starting over.
        if visited > 0, keychainDenials == visited {
            throw NoteEncryption.NoteEncryptionError.keychainReadFailed(errSecAuthFailed)
        }
        return notes
    }

    /// Remove a note file plus its .wal and .bak.* sidecars.
    /// (.corrupt.* retirements are intentionally kept — forensic safety net.)
    private static func removeArtifacts(for url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: url.appendingPathExtension("wal"))
        let dir = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in entries where name.hasPrefix(base + ".bak.") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Migration: combined store → per-note store v2 (S2, idempotent)
    //
    // Sources handled:
    //   (a) plaintext flote_notes.json         → first funneled through the
    //       existing plaintext→combined-encrypted migration (migrateIfNeeded),
    //       then (b) applies.
    //   (b) combined flote_notes.encrypted     → each note written to
    //       notes-v2/<uuid>.encrypted; legacy history seeded into
    //       recently-deleted/ with deletedAt = modifiedAt.
    //
    // Fail-closed ordering: the legacy file is renamed to
    // *.migrated-backup-v2 ONLY after every per-note write succeeded.
    // MERGE semantics make re-runs safe: a note whose per-note file already
    // exists is never overwritten (the per-note copy may be newer), so a
    // crash mid-migration heals on the next launch instead of losing the
    // tail of the array. Once the legacy file is renamed the function is a
    // permanent no-op.

    static func migrateToPerNoteStoreIfNeeded() {
        // Step 0: legacy plaintext → combined encrypted (existing, idempotent).
        migrateIfNeeded()

        migrateCombinedFamily(
            basename: "flote_notes",
            destinationURL: { try noteURL($0.id) },
            transform: { $0 }
        )
        migrateCombinedFamily(
            basename: "flote_history",
            destinationURL: { try deletedNoteURL($0.id) },
            transform: { note in
                var n = note
                // Legacy history carried no deletion stamp — approximate
                // with the last modification time so 30-day expiry works.
                if n.deletedAt == nil { n.deletedAt = n.modifiedAt }
                return n
            }
        )
    }

    /// Migrate one combined-array family into per-note files. Renames the
    /// legacy file only after ALL writes succeeded (fail-closed).
    private static func migrateCombinedFamily(
        basename: String,
        destinationURL: (StickyNote) throws -> URL,
        transform: (StickyNote) -> StickyNote
    ) {
        let fm = FileManager.default
        guard let legacyURL = try? encryptedURL(basename) else { return }
        let hasMain = fm.fileExists(atPath: legacyURL.path)
        let hasWal = fm.fileExists(atPath: legacyURL.appendingPathExtension("wal").path)
        guard hasMain || hasWal else { return }  // already migrated (or fresh install)

        let legacy: [StickyNote]
        do {
            legacy = try walLoad([StickyNote].self, from: legacyURL)
        } catch {
            // Unreadable legacy store: leave it in place (walLoad already
            // attempted bak recovery + retired the corrupt main). Nothing is
            // renamed, so a later launch with a healthier disk retries.
            NSLog("[Flote] PersistenceService: v2 migration could not read %@: %@",
                  basename, String(describing: error))
            return
        }

        var allSucceeded = true
        var written = 0
        for note in legacy {
            do {
                let dest = try destinationURL(note)
                // MERGE: never clobber an existing per-note file — it may
                // hold edits newer than this legacy snapshot.
                if fm.fileExists(atPath: dest.path) { continue }
                try walSave(transform(note), to: dest)
                written += 1
            } catch {
                allSucceeded = false
                NSLog("[Flote] PersistenceService: v2 migration write failed for note %@ in %@: %@",
                      note.id.uuidString, basename, String(describing: error))
            }
        }

        guard allSucceeded else {
            NSLog("[Flote] PersistenceService: v2 migration for %@ incomplete (%d/%d written) — legacy file kept for retry",
                  basename, written, legacy.count)
            return
        }

        // Every note has a durable per-note copy → retire the legacy file.
        // NEVER deleted, only renamed, exactly like the pre-encrypt backups.
        var backupURL = legacyURL.appendingPathExtension("migrated-backup-v2")
        if fm.fileExists(atPath: backupURL.path) {
            // A previous aborted run left a backup; keep both (timestamped).
            let stamp = ISO8601DateFormatter.compactFormatter.string(from: Date())
            backupURL = legacyURL.appendingPathExtension("migrated-backup-v2.\(stamp)")
        }
        // NOTE: walLoad→safeRead may have PROMOTED a stranded .wal to the
        // main file above, so re-check what actually exists on disk now
        // (the hasMain/hasWal flags from before the read are stale).
        do {
            let walURL = legacyURL.appendingPathExtension("wal")
            let mainExistsNow = fm.fileExists(atPath: legacyURL.path)
            let walExistsNow = fm.fileExists(atPath: walURL.path)
            if mainExistsNow {
                try fm.moveItem(at: legacyURL, to: backupURL)
                // The .wal (if promote-failure left one) holds the same
                // bytes we just migrated — safe to retire.
                if walExistsNow { try? fm.removeItem(at: walURL) }
            } else if walExistsNow {
                // Promote failed and only the sidecar holds the data:
                // preserve IT as the backup instead of deleting it.
                try fm.moveItem(at: walURL, to: backupURL)
            }
            NSLog("[Flote] PersistenceService: migrated %@ (%d notes) → per-note v2; legacy kept as %@",
                  basename, legacy.count, backupURL.lastPathComponent)
        } catch {
            NSLog("[Flote] PersistenceService: v2 migration rename failed for %@: %@ — will retry (merge) next launch",
                  basename, String(describing: error))
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

// MARK: - Manual backup / restore (P1/S — rival-behavior-specs finding #2)
//
// All three competitors sync via iCloud; Flote has no sync yet. This manual
// backup is the stopgap that kills the "my notes are trapped in this app /
// this machine" objection until v2 sync lands.
//
// Format: ONE plaintext-JSON file, `Flote-backup-YYYY-MM-DD-HHmm.flotebackup`.
// It is DELIBERATELY not encrypted: the AES key lives in this Mac's Keychain
// (ThisDeviceOnly) and does not travel — an encrypted backup would be
// unrestorable on a new machine, which is worthless. The Settings UI states
// this plainly. Locked notes (isLocked) export like any other note for the
// same reason.
//
// Restore contract (content protection over everything):
//   1. parse + validate the WHOLE document before any write (all-or-nothing;
//      corrupt file = error alert, current data untouched);
//   2. snapshot the current store aside (snapshotBeforeRestore) before the
//      first merge write;
//   3. merge ONLY through NoteManager/GroupManager save paths — an id that
//      already exists is skipped, never overwritten; missing groups are
//      recreated by name.

// BACKUP-PURE-BEGIN
/// Pure backup-document core. Foundation-only — the standalone harness
/// (`.harness/tests/s8-backup-roundtrip-test.sh`) extracts this region
/// verbatim with sed and compiles it with swiftc, so the round-trip test
/// always runs against the SHIPPING encode/parse/validate logic, never a
/// copy. Keep this region free of AppKit / CryptoKit / Keychain / L()/LN()
/// references.
enum FloteBackup {

    /// Bump when the document layout changes incompatibly. parse() rejects
    /// documents NEWER than this (fail closed — never guess at a future
    /// format); older versions stay decodable via tolerant per-field decode.
    static let currentSchemaVersion = 1

    struct Manifest: Codable, Equatable {
        let schemaVersion: Int
        let appVersion: String
        let createdAt: Date
        let noteCount: Int
        let groupCount: Int
        let historyCount: Int
        let learningCount: Int
    }

    struct Document: Codable {
        let manifest: Manifest
        let notes: [StickyNote]
        let groups: [NoteGroup]
        /// Recently-deleted entries (deletedAt set). Exported for
        /// completeness/inspection; v1 restore does not merge them.
        let history: [StickyNote]
        let learning: [ClassificationExample]
    }

    enum BackupError: Error, Equatable {
        /// Not decodable as a Flote backup document (wrong shape / corrupt
        /// bytes / not JSON). `detail` carries the underlying decode message.
        case notAFloteBackup(detail: String)
        /// Document written by a newer Flote than this build understands.
        case unsupportedSchema(found: Int)
        /// Manifest count disagrees with the payload — corruption tell.
        case manifestMismatch(field: String, manifest: Int, actual: Int)
    }

    /// Build a document whose manifest counts are DERIVED from the payload —
    /// the single place counts are computed, so encode→parse can never
    /// disagree with itself.
    static func document(
        notes: [StickyNote],
        groups: [NoteGroup],
        history: [StickyNote],
        learning: [ClassificationExample],
        appVersion: String,
        createdAt: Date = Date()
    ) -> Document {
        Document(
            manifest: Manifest(
                schemaVersion: currentSchemaVersion,
                appVersion: appVersion,
                createdAt: createdAt,
                noteCount: notes.count,
                groupCount: groups.count,
                historyCount: history.count,
                learningCount: learning.count
            ),
            notes: notes,
            groups: groups,
            history: history,
            learning: learning
        )
    }

    /// Plaintext JSON bytes for the .flotebackup file. Pretty-printed and
    /// key-sorted so the user can open, inspect, and diff a backup in any
    /// text editor — the file doubles as its own documentation.
    static func encode(_ document: Document) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(document)
    }

    /// ALL-OR-NOTHING parse + validation. Any malformed byte, any note that
    /// fails to decode, an unknown future schema, or manifest counts that
    /// disagree with the payload → throws. Callers write NOTHING on throw.
    static func parse(_ data: Data) throws -> Document {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let document: Document
        do {
            document = try d.decode(Document.self, from: data)
        } catch {
            throw BackupError.notAFloteBackup(detail: String(describing: error))
        }
        let m = document.manifest
        guard m.schemaVersion >= 1, m.schemaVersion <= currentSchemaVersion else {
            throw BackupError.unsupportedSchema(found: m.schemaVersion)
        }
        let checks: [(String, Int, Int)] = [
            ("noteCount", m.noteCount, document.notes.count),
            ("groupCount", m.groupCount, document.groups.count),
            ("historyCount", m.historyCount, document.history.count),
            ("learningCount", m.learningCount, document.learning.count),
        ]
        for (field, declared, actual) in checks where declared != actual {
            throw BackupError.manifestMismatch(field: field, manifest: declared, actual: actual)
        }
        return document
    }

    /// e.g. "Flote-backup-2026-07-11-0930.flotebackup"
    static func suggestedFilename(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "Flote-backup-\(f.string(from: date)).flotebackup"
    }
}
// BACKUP-PURE-END

// LocalizedError lives OUTSIDE the pure region (LN() is app-side).
extension FloteBackup.BackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notAFloteBackup(let detail):
            return LN("バックアップファイルを読み取れません（形式が不正か、破損しています）。現在のデータは変更されていません。",
                      "Could not read the backup file (invalid or corrupted). Your current data is untouched.")
                + " [\(detail)]"
        case .unsupportedSchema(let found):
            return LN("このバックアップは新しいバージョンの Flote で作成されています (schema \(found))。Flote を更新してから復元してください。現在のデータは変更されていません。",
                      "This backup was created by a newer version of Flote (schema \(found)). Update Flote and try again. Your current data is untouched.")
        case .manifestMismatch(let field, let declared, let actual):
            return LN("バックアップの内容が一致しません（\(field): 宣言 \(declared) / 実際 \(actual)）。ファイルが破損している可能性があります。現在のデータは変更されていません。",
                      "The backup is inconsistent (\(field): declared \(declared) / actual \(actual)) — the file may be corrupted. Your current data is untouched.")
        }
    }
}

// MARK: - Pre-restore snapshot (safety rail)

extension PersistenceService {

    /// Copy everything a restore-merge can write (the per-note store and the
    /// groups family file) aside BEFORE the first merge write. Throws on any
    /// copy failure — the caller must then ABORT the restore.
    ///
    /// Naming: `*.pre-restore-<stamp>*`, deliberately NOT `<file>.bak.<stamp>`.
    /// The `.bak.` prefix is the rolling 5-generation recovery set
    /// (tryBakRestore/pruneBaks sort it lexicographically) and a
    /// "…bak.pre-restore-…" entry would sort ABOVE every date stamp — always
    /// preferred on corruption recovery and never pruned, silently evicting
    /// the real generations. This name keeps the snapshot outside that
    /// machinery: a manual-recovery artifact, pruned to the last 3 restores.
    static func snapshotBeforeRestore() throws {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter.compactFormatter.string(from: Date())
        let root = try floteDir()

        // 1) Per-note store: whole-directory copy (note files are KB-scale).
        let notesDir = try notesV2Dir()
        let notesSnap = root.appendingPathComponent(
            "notes-v2.pre-restore-\(stamp)", isDirectory: true)
        try fm.copyItem(at: notesDir, to: notesSnap)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: notesSnap.path)

        // 2) Groups family file (restore may create groups → file rewrite).
        let groupsURL = try encryptedURL("flote_groups")
        if fm.fileExists(atPath: groupsURL.path) {
            let snap = root.appendingPathComponent(
                "flote_groups.encrypted.pre-restore-\(stamp).bak")
            if fm.fileExists(atPath: snap.path) { try fm.removeItem(at: snap) }
            try fm.copyItem(at: groupsURL, to: snap)
            tighten(snap)
        }

        prunePreRestoreSnapshots(in: root, keeping: 3)
    }

    /// Keep only the newest `maxCount` pre-restore snapshots per family
    /// (compact ISO stamps sort lexicographically = chronologically).
    private static func prunePreRestoreSnapshots(in root: URL, keeping maxCount: Int) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for prefix in ["notes-v2.pre-restore-", "flote_groups.encrypted.pre-restore-"] {
            let snaps = entries.filter { $0.hasPrefix(prefix) }.sorted(by: >)
            for old in snaps.dropFirst(maxCount) {
                try? fm.removeItem(at: root.appendingPathComponent(old))
            }
        }
    }
}
