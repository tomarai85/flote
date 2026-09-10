import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class NoteManager {

    static let shared = NoteManager()

    private(set) var notes: [StickyNote] = []

    // Track pending save task so we can cancel and reschedule (debounce).
    private var saveTask: Task<Void, Never>?

    /// S2 dirty tracking: mutators record WHICH note changed; the debounced
    /// flush writes only those per-note files instead of rewriting the whole
    /// array. A note whose save fails stays dirty and is retried on the next
    /// flush (disk-full etc. never silently drops an edit).
    private var dirtyNoteIDs: Set<UUID> = []

    private init() {}

    /// Mark one note as needing a per-note write and arm the debounce.
    private func markDirty(_ id: UUID) {
        dirtyNoteIDs.insert(id)
        scheduleSave()
    }

    // MARK: - Lookup

    /// O(1) note lookup by ID.
    private var noteIndex: [UUID: Int] = [:]

    private func rebuildIndex() {
        noteIndex.removeAll(keepingCapacity: true)
        for (i, note) in notes.enumerated() {
            noteIndex[note.id] = i
        }
    }

    func note(byID id: UUID) -> StickyNote? {
        guard let i = index(for: id) else { return nil }
        return notes[i]
    }

    /// O(1) index lookup with fallback.
    private func index(for id: UUID) -> Int? {
        if let i = noteIndex[id], i < notes.count, notes[i].id == id {
            return i
        }
        // Fallback to linear search if index is stale.
        return notes.firstIndex { $0.id == id }
    }

    // MARK: - CRUD

    /// Create a new note. Existing notes are preserved (multi-note mode).
    /// The new note is scattered near screen center to avoid overlap.
    @discardableResult
    func createNote() -> StickyNote {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // New notes start at the app-level size suggestion (小/中/大).
        let defaultSize = FloatingPanel.SizePreset.current.size
        let centerX = screen.midX - defaultSize.width / 2
        let centerY = screen.midY - defaultSize.height / 2
        let jitterX = CGFloat.random(in: -60...60)
        let jitterY = CGFloat.random(in: -40...40)

        let maxZ = notes.map(\.zOrder).max() ?? 0
        // Fresh notes intentionally have NO group assignment. They only get a
        // group home after Organize succeeds (content + title exist), so empty
        // scratch notes never clutter Inbox.
        let note = StickyNote(
            position: CGPoint(x: centerX + jitterX, y: centerY + jitterY),
            size: defaultSize,
            colorTheme: nextColor(),
            zOrder: maxZ + 1,
            groupID: nil,
            isPanelOpen: true,
            sortedAt: nil
        )
        notes.append(note)
        rebuildIndex()
        markDirty(note.id)
        return note
    }

    /// Return the single active note, if any.
    var activeNote: StickyNote? { notes.first }

    /// Pick a color that differs from currently VISIBLE notes (open panels)
    /// and the most recent history entry, so new panels look distinct from
    /// what the user sees on screen. We intentionally ignore closed-panel
    /// notes: their colors aren't visible, so reserving them shrinks the
    /// candidate pool until only visually-similar colors (e.g. lavender next
    /// to blue) remain — the "全部青に見える" bug.
    private func nextColor() -> NoteColorTheme {
        var used = Set(notes.filter(\.isPanelOpen).map(\.colorTheme))
        if let lastHistory = history.last?.colorTheme {
            used.insert(lastHistory)
        }
        let candidates = NoteColorTheme.allCases.filter { !used.contains($0) }
        return candidates.randomElement()
            ?? NoteColorTheme.allCases.randomElement()
            ?? .yellow
    }

    /// Called at launch to ensure notes always start in expanded state.
    /// Restores the saved expandedSize/Position so the panel renders correctly.
    func resetStowStateOnLaunch() {
        for i in notes.indices {
            if notes[i].stowState != .expanded {
                notes[i].stowState = .expanded
                if let size = notes[i].expandedSize {
                    notes[i].size = size
                }
                if let pos = notes[i].expandedPosition {
                    notes[i].position = pos
                }
                markDirty(notes[i].id)
            }
        }
    }

    /// Soft-delete a note into the recently-deleted store. EVERY delete goes
    /// through here — blank notes included (durability principle: a note the
    /// user watched vanish must always be recoverable for 30 days). The note
    /// is removed from the active array only after the recently-deleted copy
    /// is durably on disk; if that write fails the note STAYS active and the
    /// failure is logged — no code path drops a note silently.
    func deleteNote(id: UUID) {
        guard let note = note(byID: id) else { return }
        do {
            let stamped = try PersistenceService.softDelete(note: note)
            // Mirror is kept oldest-first so `history.last` = newest deletion
            // (same invariant the 20-cap ring had — nextColor relies on it).
            history.append(stamped)
        } catch {
            NSLog("[Flote] softDelete failed for %@ — note kept active: %@",
                  id.uuidString, String(describing: error))
            return
        }
        notes.removeAll { $0.id == id }
        rebuildIndex()
        dirtyNoteIDs.remove(id)
        // A deleted note's pending reminders must not ring (S6 reminders).
        ReminderService.cancelAll(noteID: id)
    }

    // MARK: - Recently Deleted (S2 — backs the old `history` API surface)
    //
    // `history` is an in-memory mirror of the recently-deleted per-note
    // store, kept OLDEST-FIRST so existing UI (`history.reversed()` = newest
    // first) and `history.last` (most recent deletion) keep their semantics.
    // The 20-cap ring is gone; retention is time-based (30 days, purged at
    // launch) and every entry lives as its own encrypted file on disk.

    private(set) var history: [StickyNote] = []

    func loadHistory() {
        // Time-based retention: drop entries older than 30 days first.
        PersistenceService.purgeExpiredDeleted()
        do {
            // loadRecentlyDeleted returns newest-first; mirror stores oldest-first.
            history = Array(try PersistenceService.loadRecentlyDeleted().reversed())
        } catch {
            history = []
        }
    }

    func restoreFromHistory(id: UUID) -> StickyNote? {
        let restored: StickyNote?
        do {
            restored = try PersistenceService.restoreDeleted(id: id)
        } catch {
            NSLog("[Flote] restoreDeleted failed for %@: %@",
                  id.uuidString, String(describing: error))
            return nil
        }
        guard var note = restored else { return nil }
        history.removeAll { $0.id == id }

        // Multi-note mode: append alongside existing notes, do not replace.
        // Bump zOrder so the restored note comes to the front.
        let maxZ = notes.map(\.zOrder).max() ?? 0
        note.zOrder = maxZ + 1
        // Force expanded state so the panel is visible on restore.
        note.stowState = .expanded

        // M9: Ensure the restored note belongs to a visible group.
        // If its original groupID still exists, keep it; otherwise fall back
        // to Inbox so it always shows up in the Groups tab.
        let gm = GroupManager.shared
        gm.ensureInboxExists()
        if let gid = note.groupID, gm.group(byID: gid) == nil {
            // Original group was deleted — reassign to Inbox.
            note.groupID = gm.inboxID
        } else if note.groupID == nil {
            // Note was never assigned a group — place it in Inbox.
            note.groupID = gm.inboxID
        }
        // Bump sortedAt so the restored note appears at the top of its group.
        note.sortedAt = Date()

        notes.append(note)
        rebuildIndex()
        markDirty(note.id)
        return note
    }

    func clearHistory() {
        // User-confirmed permanent erase of the recently-deleted store.
        PersistenceService.purgeAllDeleted()
        history.removeAll()
    }

    func updateText(id: UUID, text: String) {
        guard let index = index(for: id) else { return }
        notes[index].text = text
        notes[index].modifiedAt = Date()
        markDirty(id)
    }

    func updateRolledTitle(id: UUID, title: String?) {
        guard let index = index(for: id) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[index].rolledTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        markDirty(id)
    }

    func updateRichText(id: UUID, data: Data?, plainText: String) {
        guard let index = index(for: id) else { return }
        notes[index].richTextData = data
        notes[index].text = plainText
        notes[index].modifiedAt = Date()
        markDirty(id)
    }

    /// Register an undo action for an Organize operation directly in NoteManager,
    /// bypassing any weak reference to a FloteTextView. This is safe even when
    /// the panel is closed or the view is deallocated, because the undo closure
    /// only captures the noteID (a value type) and accesses NoteManager.shared.
    ///
    /// The caller passes the undoManager from the panel's window (if any) or the
    /// shared app-level undoManager. If the note no longer exists when the user
    /// triggers undo, the closure is a no-op.
    func registerOrganizeUndo(
        id noteID: UUID,
        prevData: Data?,
        prevPlain: String,
        prevTitle: String?,
        undoManager: UndoManager?
    ) {
        guard let um = undoManager else { return }
        // Capture only the noteID by value; NoteManager.shared is a singleton.
        um.registerUndo(withTarget: self) { [noteID, prevData, prevPlain, prevTitle] nm in
            guard nm.note(byID: noteID) != nil else {
                print("[Flote] Organize undo skipped: note \(noteID) no longer exists")
                return
            }
            nm.updateRichText(id: noteID, data: prevData, plainText: prevPlain)
            nm.updateRolledTitle(id: noteID, title: prevTitle)
            // Keep the Organize↔戻す toggle consistent: after ⌘Z restores the
            // scribble there is nothing left to revert to.
            nm.clearOrganizeSnapshot(id: noteID)
            nm.cancelPendingSave()
            nm.save()
            // Re-render any open panel for this note.
            DispatchQueue.main.async {
                PanelManager.shared.reloadTextView(for: noteID, data: prevData, plain: prevPlain)
            }
        }
        um.setActionName("Organize")
    }

    // MARK: - Organize↔戻す snapshot (S1 content-protection toggle)

    /// Persist the pre-Organize state on the note itself so 戻す survives
    /// panel close and app restart. While a snapshot exists the Organize
    /// button shows 戻す — re-organizing organized output (the "summary
    /// shrinks forever" accident) is structurally impossible.
    func setOrganizeSnapshot(
        id: UUID,
        originalRichData: Data?,
        originalPlain: String,
        originalTitle: String?,
        organizedPlain: String
    ) {
        guard let index = index(for: id) else { return }
        notes[index].organizeOriginalRichData = originalRichData
        notes[index].organizeOriginalPlain = originalPlain
        notes[index].organizeOriginalTitle = originalTitle
        notes[index].organizedResultPlain = organizedPlain
        markDirty(id)
    }

    /// True when the note has been edited AFTER Organize produced its
    /// result — 戻す must then confirm before discarding those edits.
    func hasUserEditsAfterOrganize(id: UUID) -> Bool {
        guard let note = note(byID: id),
              let organized = note.organizedResultPlain else { return false }
        return note.text != organized
    }

    /// Restore the pre-Organize state (lossless — the snapshot holds the
    /// exact rich text, plain text, and title). Clears the snapshot so the
    /// button returns to Organize mode. No-op if there is no snapshot.
    func revertOrganize(id noteID: UUID) {
        guard let note = note(byID: noteID),
              let prevPlain = note.organizeOriginalPlain else { return }
        let prevData = note.organizeOriginalRichData
        let prevTitle = note.organizeOriginalTitle
        updateRichText(id: noteID, data: prevData, plainText: prevPlain)
        updateRolledTitle(id: noteID, title: prevTitle)
        clearOrganizeSnapshot(id: noteID)
        cancelPendingSave()
        save()
        // Reload is the CALLER's job via reloadTrigger (NoteView.performRevert)
        // — that path clears stale undo actions and resets typing attributes,
        // which a direct PanelManager.reloadTextView here would skip
        // (Codex S1 #6: double-dispatched reload with inconsistent semantics).
    }

    func clearOrganizeSnapshot(id: UUID) {
        guard let index = index(for: id) else { return }
        notes[index].organizeOriginalRichData = nil
        notes[index].organizeOriginalPlain = nil
        notes[index].organizeOriginalTitle = nil
        notes[index].organizedResultPlain = nil
        markDirty(id)
    }

    // MARK: - S6c: sink completed checkbox lines (Things-style)

    /// UserDefaults key for the 一般 setting 「完了した項目を下に移動」.
    nonisolated static let sinkCompletedKey = "floteSinkCompleted"

    /// Default ON — absence of the key means enabled.
    nonisolated static var sinkCompletedEnabled: Bool {
        UserDefaults.standard.object(forKey: sinkCompletedKey) == nil
            || UserDefaults.standard.bool(forKey: sinkCompletedKey)
    }

    nonisolated static let newNoteFocusKey = "floteNewNoteFocus"

    /// Default ON — a user-initiated new note starts ready to type
    /// (Codex UX gap: hotkey note required an extra click before typing).
    nonisolated static var newNoteFocusEnabled: Bool {
        UserDefaults.standard.object(forKey: newNoteFocusKey) == nil
            || UserDefaults.standard.bool(forKey: newNoteFocusKey)
    }

    /// Reorder the note so lines whose FIRST checkbox token is `[✓]` sink to
    /// the bottom (stable: both groups keep their relative order; a trailing
    /// run of blank lines stays pinned at the very end). The reorder moves
    /// ATTRIBUTED substrings — per-line formatting is preserved exactly,
    /// never regenerated or flattened (content-protection principle).
    ///
    /// Fail-closed no-ops (never guess, never mangle):
    /// - plain mirror diverged from the rich string → NSLog + no-op
    /// - unarchive/archive failure → NSLog + no-op
    /// - already ordered / setting disabled / note missing → silent no-op
    ///
    /// On change: registers undo (registerOrganizeUndo pattern — value
    /// capture only, singleton target), persists, and reloads any open
    /// panel. Returns true only when the note actually changed.
    @discardableResult
    func sinkCompletedLines(id noteID: UUID, undoManager: UndoManager? = nil) -> Bool {
        guard Self.sinkCompletedEnabled, let note = note(byID: noteID) else { return false }

        // Source of truth: the archived rich text. Fallback for notes that
        // never carried rich data: build one from the plain mirror with the
        // editor's default attributes (mirrors RichTextEditor.makeNSView).
        let rich: NSAttributedString
        if let data = note.richTextData {
            guard let unarchived = RichTextStorage.unarchive(data) else {
                NSLog("[Flote] sinkCompletedLines: unarchive failed for %@ — no-op",
                      noteID.uuidString)
                return false
            }
            rich = unarchived
        } else {
            rich = NSAttributedString(string: note.text,
                                      attributes: Self.defaultEditorAttributes(
                                        legacyTheme: note.colorTheme.rawValue))
        }

        // Paragraph math runs over the plain string; if note.text diverged
        // from the rich string the ranges would move the WRONG bytes — abort.
        let ranges: [NSRange]
        switch CheckboxSink.plan(richString: rich.string, plainMirror: note.text) {
        case .noop:
            return false
        case .divergedAbort:
            NSLog("[Flote] sinkCompletedLines: plain/rich mirror diverged for %@ — abort (no-op)",
                  noteID.uuidString)
            return false
        case .reorder(let r):
            ranges = r
        }

        // Rebuild by concatenating attributed substrings in the new order
        // (pure, standalone-tested — see CheckboxSink.rebuild).
        let rebuilt = CheckboxSink.rebuild(from: rich, ranges: ranges)

        // Duplicate lines can reorder into an identical document — treat as
        // the no-op it visually is.
        guard rebuilt.string != rich.string else { return false }
        guard let newData = RichTextStorage.archive(rebuilt) else {
            NSLog("[Flote] sinkCompletedLines: archive failed for %@ — no-op",
                  noteID.uuidString)
            return false
        }

        let prevData = note.richTextData
        let prevPlain = note.text
        let newPlain = rebuilt.string
        updateRichText(id: noteID, data: newData, plainText: newPlain)

        if let um = undoManager {
            // Capture only value types; NoteManager.shared is a singleton.
            um.registerUndo(withTarget: self) { [noteID, prevData, prevPlain] nm in
                guard nm.note(byID: noteID) != nil else {
                    print("[Flote] sink undo skipped: note \(noteID) no longer exists")
                    return
                }
                nm.updateRichText(id: noteID, data: prevData, plainText: prevPlain)
                nm.cancelPendingSave()
                nm.save()
                DispatchQueue.main.async {
                    PanelManager.shared.reloadTextView(for: noteID, data: prevData, plain: prevPlain)
                }
            }
            um.setActionName(L("完了項目を下へ移動", "Sink Completed Items"))
        }

        cancelPendingSave()
        save()
        PanelManager.shared.reloadTextView(for: noteID, data: newData, plain: newPlain)
        return true
    }

    /// The editor's default attributes (mirrors RichTextEditor.makeNSView:
    /// the RESOLVED body font — user family or theme monospace override
    /// at the user's global size (S16) — theme ink, 2.5 line spacing).
    /// Used only for the plain-text fallback path in sinkCompletedLines.
    private static func defaultEditorAttributes(legacyTheme rawValue: String?) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2.5
        return [
            .font: FontPreference.shared.resolvedBodyFont(),
            .foregroundColor: FloteInk.text(legacyTheme: rawValue),
            .paragraphStyle: paragraphStyle,
        ]
    }

    func updatePosition(id: UUID, position: CGPoint) {
        guard let index = index(for: id) else { return }
        notes[index].position = position
        markDirty(id)
    }

    func updateSize(id: UUID, size: CGSize) {
        guard let index = index(for: id) else { return }
        notes[index].size = size
        markDirty(id)
    }

    /// Free resize (2026-07-11): the user dragged this panel's edges — the
    /// note owns its geometry from now on (presets/auto-fit stop touching it).
    func markUserResized(id: UUID) {
        guard let index = index(for: id), !notes[index].userResized else { return }
        notes[index].userResized = true
        markDirty(id)
    }

    func updateStowState(id: UUID, state: StowState) {
        guard let index = index(for: id) else { return }
        notes[index].stowState = state
        markDirty(id)
    }

    /// S6 Touch ID lock opt-in. Locking also drops the panel's screen-
    /// capture sharing (PanelManager applies it — window-level property).
    func updateLocked(id: UUID, locked: Bool) {
        guard let index = index(for: id) else { return }
        notes[index].isLocked = locked
        markDirty(id)
        save()
        PanelManager.shared.applyLockState(noteID: id, locked: locked)
    }

    func updateColorTheme(id: UUID, theme: NoteColorTheme) {
        guard let index = index(for: id) else { return }
        notes[index].colorTheme = theme
        markDirty(id)
    }

    func bringToFront(id: UUID) {
        guard let index = index(for: id) else { return }
        let maxZ = notes.map(\.zOrder).max() ?? 0
        notes[index].zOrder = maxZ + 1
        markDirty(id)
    }

    // MARK: - Shape annotations

    func addShape(noteID: UUID, shape: ShapeAnnotation) {
        guard let index = index(for: noteID) else { return }
        notes[index].shapeAnnotations.append(shape)
        markDirty(noteID)
    }

    func removeShape(noteID: UUID, shapeID: UUID) {
        guard let index = index(for: noteID) else { return }
        notes[index].shapeAnnotations.removeAll { $0.id == shapeID }
        markDirty(noteID)
    }

    func updateShape(noteID: UUID, shape: ShapeAnnotation) {
        guard let noteIndex = index(for: noteID) else { return }
        guard let shapeIndex = notes[noteIndex].shapeAnnotations.firstIndex(where: { $0.id == shape.id }) else { return }
        notes[noteIndex].shapeAnnotations[shapeIndex] = shape
        markDirty(noteID)
    }

    // Persist the expanded geometry so we can restore it after stowing.
    func saveExpandedGeometry(id: UUID, size: CGSize, position: CGPoint) {
        guard let index = index(for: id) else { return }
        // Only overwrite if the note is currently expanded (avoid overwriting with stowed dims).
        guard notes[index].stowState == .expanded else { return }
        notes[index].expandedSize = size
        notes[index].expandedPosition = position
        markDirty(id)
    }

    // MARK: - Persistence

    /// True when load() aborted on total keychain denial — AppDelegate must
    /// NOT create a fresh note over an intact-but-locked store.
    private(set) var loadBlockedByKeychain = false

    func load() {
        // S2: one-shot idempotent migration (combined array → per-note files,
        // legacy history → recently-deleted), then load the per-note store.
        // One corrupt note file never blocks the rest from loading.
        PersistenceService.migrateToPerNoteStoreIfNeeded()
        do {
            notes = try PersistenceService.loadAllNotesV2()
        } catch let error as NoteEncryption.NoteEncryptionError {
            // Total keychain denial (r3b NEW-3): the store is intact but
            // this build may not read the key. LOUD, with the fix in hand —
            // and the flag stops AppDelegate from "starting fresh".
            notes = []
            loadBlockedByKeychain = true
            NSLog("[Flote] load blocked by keychain: %@", String(describing: error))
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L("ノートを読み込めません", "Can't unlock your notes")
            alert.informativeText = L(
                "ノートは無事ですが、この Flote が暗号化キーへのアクセスを拒否されています。アプリを入れ直した場合は Keychain の許可が必要です。",
                "Your notes are safe on disk, but this copy of Flote was denied access to the encryption key. If the app was reinstalled, the Keychain needs to grant it again.")
            alert.runModal()
        } catch {
            notes = []
        }
        rebuildIndex()

        // Save immediately before system sleep to avoid data loss on power-off.
        // Guard against multiple registrations if load() is called again.
        // NOTE: NSWorkspace notifications are posted ONLY to
        // NSWorkspace.shared.notificationCenter — registering on the default
        // center silently ignored the notification, so prior-to-sleep saves
        // never fired. Confirmed by Sprint 2 Evaluator (M-1).
        if sleepObserver == nil {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Sprint 3 D5: synchronous save before sleep.
                // queue: .main guarantees we are on the main DispatchQueue, so
                // MainActor.assumeIsolated is safe here. We must NOT use
                // Task { @MainActor in ... } because async Tasks cannot complete
                // before the OS suspends the process.
                MainActor.assumeIsolated {
                    self?.saveTask?.cancel()
                    self?.saveTask = nil
                    self?.save()
                    // Also flush companion managers so all 4 JSON files are in sync.
                    GroupManager.shared.flushSaveNow()
                    LearningManager.shared.flushSaveNow()
                }
            }
        }
    }

    /// Held reference to the sleep observer so we can remove it cleanly.
    private var sleepObserver: NSObjectProtocol?

    /// Called from AppDelegate.applicationWillTerminate.
    func teardown() {
        if let obs = sleepObserver {
            // Must match the center we registered on (see load()).
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            sleepObserver = nil
        }
    }

    /// Synchronously write every dirty note to its per-note file. Notes whose
    /// write fails STAY dirty and are retried on the next flush — an edit is
    /// never silently dropped because the disk hiccuped once.
    /// Called by the debounce, the sleep observer, applicationWillTerminate,
    /// and the Organize undo/revert paths (via `save()`).
    func flushAllDirty() {
        guard !dirtyNoteIDs.isEmpty else { return }
        var stillDirty: Set<UUID> = []
        for id in dirtyNoteIDs {
            // A dirty id with no live note was deleted after being marked —
            // softDelete already secured its file; nothing to write.
            guard let note = note(byID: id) else { continue }
            do {
                try PersistenceService.saveNote(note)
            } catch {
                stillDirty.insert(id)
                NSLog("[Flote] Save failed for note %@ (kept dirty for retry): %@",
                      id.uuidString, String(describing: error))
            }
        }
        dirtyNoteIDs = stillDirty
    }

    /// Kept as the historical entry point (sleep observer, terminate path,
    /// Organize undo/revert). Now flushes dirty per-note files.
    func save() {
        flushAllDirty()
    }

    // MARK: - Debounced save

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return  // Task was cancelled; a newer save is pending.
            }
            self?.flushAllDirty()
        }
    }

    /// Cancel any pending debounced save. Call this immediately before a
    /// synchronous save() so the queued Task doesn't fire afterward and
    /// overwrite with a stale snapshot.
    func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    // MARK: - Unified model: panel open/close + group move

    /// Close the panel for this note. The note stays in its group — only the
    /// floating panel disappears. This replaces the old archive concept.
    func closePanel(noteID: UUID) {
        guard let i = index(for: noteID) else { return }
        notes[i].isPanelOpen = false
        markDirty(noteID)
    }

    /// Re-open the floating panel for this note (user clicked it in Groups tab).
    /// Resets position if the saved coord is off-screen so the panel is always
    /// visible on screen again.
    func openPanel(noteID: UUID) {
        guard let i = index(for: noteID) else { return }
        notes[i].isPanelOpen = true
        notes[i].stowState = .expanded
        let maxZ = notes.map(\.zOrder).max() ?? 0
        notes[i].zOrder = maxZ + 1
        if let screen = NSScreen.main?.visibleFrame {
            let w = notes[i].size.width
            let h = notes[i].size.height
            let proposed = NSRect(x: notes[i].position.x, y: notes[i].position.y, width: w, height: h)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(proposed) }
            if !onScreen {
                notes[i].position = CGPoint(
                    x: screen.midX - w / 2 + CGFloat.random(in: -80...80),
                    y: screen.midY - h / 2 + CGFloat.random(in: -40...40)
                )
            }
        }
        markDirty(noteID)
    }

    // MARK: - Deck (S16 — one window, many notes)

    /// Ordered member IDs of the deck containing this note; `[noteID]`
    /// for a solo note, `[]` when the note no longer exists. Reads
    /// `notes` inside SwiftUI body → Observation re-renders the deck
    /// indicator on any membership change.
    func deckMemberIDs(with noteID: UUID) -> [UUID] {
        guard let note = note(byID: noteID) else { return [] }
        guard let deckID = note.deckID else { return [noteID] }
        return FloteDeck.orderedIDs(
            deckMembers(deckID: deckID).map { ($0.id, $0.deckOrder, $0.createdAt) })
    }

    /// All active notes carrying this deckID (unordered).
    func deckMembers(deckID: UUID) -> [StickyNote] {
        notes.filter { $0.deckID == deckID }
    }

    /// Set or clear deck membership. Clearing IS "leaving the deck"
    /// (archive / AI-sort put-away); the deck needs no other bookkeeping —
    /// membership lives entirely on the notes.
    func setDeck(id: UUID, deckID: UUID?, order: Int?) {
        guard let i = index(for: id) else { return }
        guard notes[i].deckID != deckID || notes[i].deckOrder != order else { return }
        notes[i].deckID = deckID
        notes[i].deckOrder = order
        markDirty(id)
    }

    /// Archive a note: park it in Inbox if it has no group, then close the
    /// panel. The note itself is never deleted — it stays retrievable from
    /// the Groups tab. Used by ⌘W and the archive hotkey.
    ///
    /// F2 empty-note hygiene: a STRICTLY empty note (NoteHygiene predicate —
    /// no text, no rich content, no title, no shapes, not locked) is silently
    /// discarded instead — it never lands in Groups Inbox NOR in Recently
    /// Deleted (there is literally nothing to recover). A note that is only
    /// text-empty but fails any other clause (rich data diverged, shapes,
    /// locked, titled) takes the normal archive path — content protection
    /// wins over tidiness.
    func archiveNote(id: UUID) {
        guard let i = index(for: id) else { return }
        if isStrictlyEmpty(notes[i]) {
            discardEmptyNote(id: id, reason: "archive of empty note")
            return
        }
        if notes[i].groupID == nil {
            GroupManager.shared.ensureInboxExists()
            if let inboxID = GroupManager.shared.inboxID {
                moveNote(id: id, toGroup: inboxID)
            }
        }
        closePanel(noteID: id)
    }

    // MARK: - F2 empty-note hygiene

    /// AppKit-side wrapper around the pure `NoteHygiene` predicate: decodes
    /// `richTextData` (when present) into its plain string. A decode failure
    /// is reported as undecodable — the pure core then refuses to call the
    /// note empty (we can't prove it, so we keep it).
    private func isStrictlyEmpty(_ note: StickyNote) -> Bool {
        var richPlain: String?
        var undecodable = false
        if let data = note.richTextData {
            if let attr = RichTextStorage.unarchive(data) {
                richPlain = attr.string
            } else {
                undecodable = true
            }
        }
        return NoteHygiene.isDiscardablyEmpty(
            text: note.text,
            richPlain: richPlain,
            hasUndecodableRichData: undecodable,
            rolledTitle: note.rolledTitle,
            hasShapeAnnotations: !note.shapeAnnotations.isEmpty,
            isLocked: note.isLocked
        )
    }

    /// Hard-discard a strictly-empty note: unlike `deleteNote(id:)` this
    /// NEVER writes a Recently-Deleted copy — the store exists to recover
    /// content, and a genuinely empty note has none, so parking it there is
    /// pure clutter. `PersistenceService.deleteNoteFile`'s "secure a durable
    /// copy first" contract is intentionally waived here for exactly that
    /// reason. Fail-closed: the emptiness predicate is re-verified at the
    /// door, so no caller can route a non-empty note through this path.
    private func discardEmptyNote(id: UUID, reason: String) {
        guard let note = note(byID: id), isStrictlyEmpty(note) else { return }
        notes.removeAll { $0.id == id }
        rebuildIndex()
        dirtyNoteIDs.remove(id)
        // A discarded note's pending reminders must not ring.
        ReminderService.cancelAll(noteID: id)
        do {
            try PersistenceService.deleteNoteFile(id: id)
        } catch {
            // Leftover file = the note resurrects on next launch, which errs
            // on the keep-data side; the launch sweep retires it eventually.
            NSLog("[Flote] discardEmptyNote: file cleanup failed for %@: %@",
                  id.uuidString, String(describing: error))
        }
        NSLog("[Flote] discarded empty note %@ (%@)", id.uuidString, reason)
    }

    /// Launch-time sweep (F2): purge empty notes that (a) are not open in any
    /// panel, (b) are older than 24h — BOTH createdAt and modifiedAt, one
    /// keep-side notch stricter than the spec so a note emptied minutes ago
    /// survives — and (c) show no user intent: an explicit groupID or a
    /// rolledTitle exempts a note (the title check lives inside the
    /// NoteHygiene predicate). Call AFTER load()/migrateLegacyFields and
    /// BEFORE panels are restored.
    func purgeStaleEmptyNotesAtLaunch(olderThan interval: TimeInterval = 24 * 60 * 60) {
        let cutoff = Date().addingTimeInterval(-interval)
        let stale = notes.filter { note in
            !note.isPanelOpen
                && note.groupID == nil
                && note.createdAt < cutoff
                && note.modifiedAt < cutoff
                && isStrictlyEmpty(note)
        }
        for note in stale {
            discardEmptyNote(id: note.id, reason: "launch sweep, created \(note.createdAt)")
        }
    }

    /// Move a note to the specified group and record a learning example so
    /// future AI sorts pick up the user's preference. Passing the same group
    /// as the current one is a no-op (no learning noise).
    func moveNote(id: UUID, toGroup groupID: UUID) {
        guard let i = index(for: id) else { return }
        if notes[i].groupID == groupID { return }
        notes[i].groupID = groupID
        notes[i].sortedAt = Date()
        markDirty(id)

        // Record as a learning example for few-shot classification.
        if let group = GroupManager.shared.group(byID: groupID) {
            LearningManager.shared.record(
                noteText: notes[i].text,
                groupName: group.name
            )
        }
    }

    /// Ensure legacy notes (those that predate the unified-model release)
    /// get a group home. Notes created under the new rules may intentionally
    /// have groupID==nil (fresh scratch notes), so we only migrate notes
    /// that actually carry content; empty scratch notes stay groupless and
    /// never surface in Groups until the user runs Organize on them.
    func migrateLegacyFields(inboxID: UUID) {
        for i in notes.indices where notes[i].groupID == nil {
            let hasContent = !notes[i].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard hasContent else { continue }
            notes[i].groupID = inboxID
            if notes[i].sortedAt == nil {
                notes[i].sortedAt = Date()
            }
            markDirty(notes[i].id)
        }
    }

    /// Notes whose panel should be restored on app launch.
    var panelOpenNotes: [StickyNote] { notes.filter { $0.isPanelOpen } }

    /// All notes inside a group, regardless of panel visibility. Newest first.
    func notes(inGroup groupID: UUID) -> [StickyNote] {
        notes.filter { $0.groupID == groupID }
            .sorted { ($0.sortedAt ?? $0.modifiedAt) > ($1.sortedAt ?? $1.modifiedAt) }
    }

    /// Progress info reported during a batch classify operation.
    struct BatchClassifyProgress {
        let total: Int
        let processed: Int
        let moved: Int
        let failed: Int
        /// Error category breakdown, e.g. ["network": 2, "key": 1].
        let errorBreakdown: [String: Int]

        init(total: Int, processed: Int, moved: Int, failed: Int, errorBreakdown: [String: Int] = [:]) {
            self.total = total
            self.processed = processed
            self.moved = moved
            self.failed = failed
            self.errorBreakdown = errorBreakdown
        }

        /// Human-readable summary of error categories, e.g. "network=2, key=1".
        var errorSummary: String {
            guard !errorBreakdown.isEmpty else { return "" }
            return errorBreakdown
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
        }
    }

    /// Run AI classification over every note currently parked in the Inbox,
    /// moving each one into the best-matching existing or newly-created group.
    /// Notes whose classification returns `.inbox` stay where they are.
    /// Errors per-note are logged and counted as `failed`; the batch continues.
    /// Returns the final tally.
    @discardableResult
    func batchClassifyInbox(
        progress: (@MainActor (BatchClassifyProgress) -> Void)? = nil
    ) async -> BatchClassifyProgress {
        GroupManager.shared.ensureInboxExists()
        guard let inboxID = GroupManager.shared.inboxID else {
            let empty = BatchClassifyProgress(total: 0, processed: 0, moved: 0, failed: 0)
            progress?(empty)
            return empty
        }
        // Capture a snapshot so later moveNote calls don't shift the iteration.
        let queue = notes(inGroup: inboxID)
        let total = queue.count
        var processed = 0
        var moved = 0
        var failed = 0
        var errorBreakdown: [String: Int] = [:]
        progress?(BatchClassifyProgress(
            total: total, processed: 0, moved: 0, failed: 0
        ))

        for note in queue {
            let groups = GroupManager.shared.groups
            do {
                let result = try await OrganizeService.shared.classify(
                    text: note.text,
                    existingGroups: groups
                )
                let stillExists = self.note(byID: note.id) != nil
                guard stillExists else {
                    processed += 1
                    continue
                }
                switch result {
                case .existing(let id):
                    if GroupManager.shared.group(byID: id) != nil, id != inboxID {
                        moveNote(id: note.id, toGroup: id)
                        moved += 1
                    }
                case .newGroup(let name):
                    let icon = GroupManager.iconForGroupName(name)
                    let color = GroupManager.colorHexForGroupName(name)
                    let g = GroupManager.shared.createGroup(name: name, icon: icon, colorHex: color)
                    moveNote(id: note.id, toGroup: g.id)
                    moved += 1
                case .inbox:
                    break
                }
            } catch {
                print("[Flote] batchClassifyInbox: note \(note.id) failed — \(error.localizedDescription)")
                failed += 1
                // Track error category for the batch result summary.
                let key = (error as? OrganizeService.OrganizeError)?.categoryKey ?? "unknown"
                errorBreakdown[key, default: 0] += 1
            }
            processed += 1
            progress?(BatchClassifyProgress(
                total: total, processed: processed, moved: moved, failed: failed
            ))
        }

        // Notify GroupManager observers so the Groups left pane re-renders
        // immediately. `moveNote` only updates NoteManager state; the Groups
        // array itself is unchanged for `.existing` targets, so SwiftUI won't
        // automatically see the note-count change without this explicit tick.
        GroupManager.shared.notifyGroupsChanged()

        return BatchClassifyProgress(
            total: total, processed: processed, moved: moved, failed: failed,
            errorBreakdown: errorBreakdown
        )
    }

    // MARK: - Backup restore merge (P1/S manual backup)

    /// Tally returned by importBackup, rendered in the Settings result alert
    /// (「N件を復元、M件は既に存在するためスキップ」).
    struct BackupImportOutcome {
        let restored: Int
        let skipped: Int
        let groupsCreated: Int
    }

    /// Merge the notes of a parsed backup document into the live store.
    ///
    /// CONTENT-PROTECTION CONTRACT:
    /// - an id that already exists (active note OR recently-deleted entry)
    ///   is SKIPPED — restore can never overwrite live data, and never
    ///   plants a duplicate id across the two stores;
    /// - imported notes land with their panel CLOSED — they appear in their
    ///   groups, not as N windows exploding onto the screen;
    /// - a note's group is resolved id-first, then by NAME against live
    ///   groups; missing groups are recreated (at root) from the backup's
    ///   own group table; unresolvable/absent groups fall back to Inbox
    ///   (content-bearing notes) or stay groupless (empty scratch notes),
    ///   mirroring migrateLegacyFields;
    /// - every write goes through the app's normal save path
    ///   (markDirty → flushAllDirty → PersistenceService.saveNote), never
    ///   raw file copies into the live store.
    ///
    /// Callers MUST have run FloteBackup.parse (all-or-nothing validation)
    /// and PersistenceService.snapshotBeforeRestore() before calling this.
    func importBackup(_ doc: FloteBackup.Document) -> BackupImportOutcome {
        let gm = GroupManager.shared
        gm.ensureInboxExists()

        // Duplicate group ids inside a hand-edited backup: first wins.
        let backupGroups = Dictionary(doc.groups.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        // liveIDs also absorbs ids imported THIS run, so a backup that
        // repeats an id can't append the same note twice.
        var liveIDs = Set(notes.map(\.id))
        let historyIDs = Set(history.map(\.id))
        var createdByName: [String: UUID] = [:]
        var restored = 0
        var skipped = 0
        var groupsCreated = 0

        for var note in doc.notes {
            if liveIDs.contains(note.id) || historyIDs.contains(note.id) {
                skipped += 1
                continue
            }
            let hasContent = !note.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            note.groupID = resolveImportGroup(
                note.groupID,
                hasContent: hasContent,
                backupGroups: backupGroups,
                createdByName: &createdByName,
                groupsCreated: &groupsCreated
            )
            if note.groupID != nil, note.sortedAt == nil {
                note.sortedAt = Date()
            }
            // Land quietly in Groups; the user opens what they need.
            note.isPanelOpen = false
            // An active note must never carry a deletion stamp (a stray
            // deletedAt from a history-derived payload would purge it in 30d).
            note.deletedAt = nil
            notes.append(note)
            liveIDs.insert(note.id)
            restored += 1
        }

        rebuildIndex()
        // Mark AFTER rebuildIndex so flushAllDirty's note(byID:) hits the
        // O(1) index instead of the linear fallback for every imported note.
        for note in notes.suffix(restored) {
            markDirty(note.id)
        }
        cancelPendingSave()
        save()               // synchronous flush through the normal per-note path
        gm.flushSaveNow()    // persist any groups created during the merge
        gm.notifyGroupsChanged()

        return BackupImportOutcome(
            restored: restored, skipped: skipped, groupsCreated: groupsCreated)
    }

    /// Resolve the group home for one imported note. See importBackup docs.
    private func resolveImportGroup(
        _ backupGroupID: UUID?,
        hasContent: Bool,
        backupGroups: [UUID: NoteGroup],
        createdByName: inout [String: UUID],
        groupsCreated: inout Int
    ) -> UUID? {
        let gm = GroupManager.shared
        guard let gid = backupGroupID else {
            // Same convention as migrateLegacyFields: content-bearing notes
            // get an Inbox home, empty scratch notes stay groupless.
            return hasContent ? gm.inboxID : nil
        }
        // Best case: the exact group still exists (restore onto same machine).
        if gm.group(byID: gid) != nil { return gid }
        // The group id is foreign — find it in the backup's own group table
        // and match/recreate by NAME.
        guard let backupGroup = backupGroups[gid] else {
            // Note references a group the backup itself doesn't carry
            // (hand-edited file); parse() passed, so fail soft into Inbox.
            return gm.inboxID
        }
        if let live = gm.groups.first(where: { $0.name == backupGroup.name }) {
            return live.id
        }
        if let alreadyCreated = createdByName[backupGroup.name] {
            return alreadyCreated
        }
        let g = gm.createGroup(
            name: backupGroup.name,
            icon: backupGroup.iconName,
            colorHex: backupGroup.colorHex
        )
        createdByName[backupGroup.name] = g.id
        groupsCreated += 1
        return g.id
    }
}

// MARK: - CheckboxSink (S6c pure core)

// S6C-SINK-PURE-BEGIN
/// Pure sink-partition core for 「完了した項目を下に移動」. Foundation-only —
/// the standalone harness (`.harness/tests/s6c-sink-test.sh`) extracts this
/// region verbatim with sed and compiles it with swiftc, so the test always
/// runs against the SHIPPING logic, never a copy. Keep this region free of
/// AppKit / app-type references.
enum CheckboxSink {

    /// What sinkCompletedLines should do, decided purely from strings.
    enum SinkPlan: Equatable {
        /// Already ordered (or nothing to do) — leave the note untouched.
        case noop
        /// note.text no longer mirrors the rich string — reordering would
        /// move the wrong ranges. Abort, never guess (content protection).
        case divergedAbort
        /// Paragraph ranges of the ORIGINAL string, in the new order.
        case reorder([NSRange])
    }

    private static let uncheckedToken = "[ ]"
    private static let checkedToken = "[\u{2713}]"

    /// Line terminators NSString paragraph APIs recognize (LF/CR/LS/PS;
    /// a CRLF pair ends in LF so the suffix check covers it too).
    private static let terminators: Set<Character> = ["\n", "\r", "\u{2028}", "\u{2029}"]

    static func endsWithLineTerminator(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return terminators.contains(last)
    }

    /// Whether the line's FIRST checkbox token is the checked one.
    /// nil = the line carries no checkbox token at all. Position in the
    /// line is irrelevant — same rule FloteLayoutManager uses for
    /// done-line styling, so what strikes through is what sinks.
    static func firstTokenChecked(inLine line: String) -> Bool? {
        let unchecked = line.range(of: uncheckedToken)
        let checked = line.range(of: checkedToken)
        switch (unchecked, checked) {
        case (nil, nil):               return nil
        case (nil, .some):             return true
        case (.some, nil):             return false
        case let (.some(u), .some(c)): return c.lowerBound < u.lowerBound
        }
    }

    /// Paragraph ranges of `text` in document order. Each range includes its
    /// terminator except (possibly) the last. The zero-length "caret
    /// paragraph" after a trailing newline is intentionally not produced.
    static func paragraphRanges(of text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < text.length {
            let r = text.paragraphRange(for: NSRange(location: location, length: 0))
            // paragraphRange always advances past at least one character
            // here (location < length), but guard against a stall anyway.
            guard r.length > 0 else { break }
            ranges.append(r)
            location = NSMaxRange(r)
        }
        return ranges
    }

    /// Decide the sink reorder for a note.
    /// - Stable partition: non-completed lines first (original order), then
    ///   lines whose first checkbox token is `[✓]` (original order).
    /// - A trailing run of blank lines stays pinned at the very end, so a
    ///   completed line never sinks BELOW the note's trailing empty space.
    static func plan(richString: String, plainMirror: String) -> SinkPlan {
        guard richString == plainMirror else { return .divergedAbort }
        let text = richString as NSString
        guard text.length > 0 else { return .noop }
        let ranges = paragraphRanges(of: text)
        guard ranges.count > 1 else { return .noop }

        // Pin the trailing blank run (empty or whitespace-only lines).
        var end = ranges.count
        while end > 0 {
            let line = text.substring(with: ranges[end - 1])
            guard line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            end -= 1
        }

        var floaters: [Int] = []   // non-completed, original order
        var sinkers: [Int] = []    // completed, original order
        for i in 0..<end {
            if firstTokenChecked(inLine: text.substring(with: ranges[i])) == true {
                sinkers.append(i)
            } else {
                floaters.append(i)
            }
        }
        guard !sinkers.isEmpty else { return .noop }
        let order = floaters + sinkers + Array(end..<ranges.count)
        guard order != Array(0..<ranges.count) else { return .noop }
        return .reorder(order.map { ranges[$0] })
    }

    /// Rebuild the document by concatenating the ATTRIBUTED paragraph
    /// substrings in `ranges` order — per-line formatting travels with each
    /// substring untouched (content-protection principle). The only
    /// characters ever added or removed are line terminators:
    /// - a moved-up original-final line (no terminator) gains one, inheriting
    ///   the segment's trailing attributes so formatting spans stay seamless;
    /// - the rebuilt document keeps the original's trailing-newline shape
    ///   (CRLF pair = 2 UTF-16 units, all other terminators = 1).
    static func rebuild(from rich: NSAttributedString, ranges: [NSRange]) -> NSAttributedString {
        let rebuilt = NSMutableAttributedString()
        for (pos, range) in ranges.enumerated() {
            let segment = rich.attributedSubstring(from: range)
            rebuilt.append(segment)
            if pos < ranges.count - 1, segment.length > 0,
               !endsWithLineTerminator(segment.string) {
                let attrs = segment.attributes(at: segment.length - 1, effectiveRange: nil)
                rebuilt.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        if !endsWithLineTerminator(rich.string), endsWithLineTerminator(rebuilt.string) {
            let s = rebuilt.string as NSString
            let tail = (s.length >= 2
                        && s.character(at: s.length - 2) == 0x0D
                        && s.character(at: s.length - 1) == 0x0A) ? 2 : 1
            rebuilt.deleteCharacters(in: NSRange(location: s.length - tail, length: tail))
        }
        return rebuilt
    }
}
// S6C-SINK-PURE-END

// MARK: - NoteHygiene (F2 empty-note hygiene, pure core)

// F2-EMPTY-PURE-BEGIN
/// Pure emptiness predicate for empty-note hygiene (Tot/Antinote lesson: no
/// ghost stickies). Foundation-only — the standalone harness
/// (`.harness/tests/f2-empty-test.sh`) extracts this region verbatim with sed
/// and compiles it with swiftc, so the test always runs against the SHIPPING
/// logic, never a copy. Keep this region free of AppKit / app-type references.
enum NoteHygiene {

    /// STRICT emptiness: true ONLY when every signal says there is nothing to
    /// keep. Content protection is the #1 principle of this codebase — every
    /// clause fails CLOSED (any doubt = not empty = keep the note):
    /// - `text` must be empty after trimming whitespace/newlines.
    /// - Rich content: `richPlain` is the decoded rich string (nil when the
    ///   note has no rich data at all) — if present it must also trim to
    ///   empty. `hasUndecodableRichData` = rich bytes exist but could not be
    ///   decoded: we cannot PROVE emptiness, so the note is not empty.
    /// - `rolledTitle` set (non-blank) = the user/AI titled it — intent, keep.
    /// - Shape annotations are content in their own right — keep.
    /// - A locked note is an explicit protection gesture — never discard.
    static func isDiscardablyEmpty(
        text: String,
        richPlain: String?,
        hasUndecodableRichData: Bool,
        rolledTitle: String?,
        hasShapeAnnotations: Bool,
        isLocked: Bool
    ) -> Bool {
        guard !isLocked else { return false }
        guard !hasShapeAnnotations else { return false }
        guard !hasUndecodableRichData else { return false }
        guard trimmedEmpty(text) else { return false }
        if let richPlain, !trimmedEmpty(richPlain) { return false }
        if let rolledTitle, !trimmedEmpty(rolledTitle) { return false }
        return true
    }

    private static func trimmedEmpty(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
// F2-EMPTY-PURE-END

// MARK: - NoteGroup model

// BACKUP-MODEL-PURE-BEGIN
// Foundation-only model — extracted by .harness/tests/s8-backup-roundtrip-test.sh
// (same sed-marker pattern as S6C-SINK-PURE). Keep free of AppKit references.
struct NoteGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentGroupID: UUID?   // nil == root
    var iconName: String
    var colorHex: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        parentGroupID: UUID? = nil,
        iconName: String = "folder",
        colorHex: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentGroupID = parentGroupID
        self.iconName = iconName
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}
// BACKUP-MODEL-PURE-END

// MARK: - GroupManager

@Observable
@MainActor
final class GroupManager {
    static let shared = GroupManager()

    private(set) var groups: [NoteGroup] = []
    private var saveTask: Task<Void, Never>?
    /// Cached ID of the special system "Inbox" group, created on first launch.
    private(set) var inboxID: UUID?
    /// Monotonically incrementing tick that SwiftUI views can observe to force
    /// a re-render even when `groups` content hasn't changed (e.g. after batch
    /// moveNote operations that only change NoteManager state).
    private(set) var _reloadTick: Int = 0

    private init() {}

    /// Trigger an observable change so any SwiftUI view observing GroupManager
    /// re-evaluates, even if the `groups` array itself didn't change.
    func notifyGroupsChanged() {
        _reloadTick += 1
    }

    // MARK: Lifecycle

    func load() {
        do {
            groups = try PersistenceService.loadGroups()
        } catch {
            groups = []
        }
        // Any cycles that slipped through a previous session would make
        // children(of:) / isDescendant loop forever. Break them before we
        // hand the tree to the UI.
        repairCycles()
        ensureInboxExists()
    }

    /// Detect parent->child cycles that would cause infinite recursion and
    /// reset the offending group's parent to nil (promote to root). Idempotent.
    private func repairCycles() {
        var changed = false
        for i in groups.indices {
            if Self.hasCycle(startID: groups[i].id, groups: groups) {
                groups[i].parentGroupID = nil
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    private static func hasCycle(startID: UUID, groups: [NoteGroup]) -> Bool {
        let lookup = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        var visited: Set<UUID> = []
        var current: UUID? = lookup[startID]?.parentGroupID
        while let id = current {
            if id == startID { return true }  // cycle back to self
            if visited.contains(id) { return true }  // cycle among ancestors
            visited.insert(id)
            if visited.count > 128 { return true }  // depth escape
            current = lookup[id]?.parentGroupID
        }
        return false
    }

    /// Guarantee the system-level "Inbox" group exists at root. This is the
    /// default archive destination when the user doesn't pick a group.
    func ensureInboxExists() {
        if let existing = groups.first(where: { $0.name == "Inbox" && $0.parentGroupID == nil }) {
            inboxID = existing.id
            return
        }
        let inbox = NoteGroup(name: "Inbox", parentGroupID: nil, iconName: "tray")
        groups.append(inbox)
        inboxID = inbox.id
        scheduleSave()
    }

    // MARK: CRUD

    @discardableResult
    func createGroup(name: String, parent: UUID? = nil, icon: String = "folder", colorHex: String? = nil) -> NoteGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "New Group" : trimmed
        let group = NoteGroup(name: finalName, parentGroupID: parent, iconName: icon, colorHex: colorHex)
        groups.append(group)
        scheduleSave()
        return group
    }

    /// Pick a SF Symbol icon name that best matches the group name using
    /// simple keyword heuristics. Falls back to a stable random choice from
    /// a curated list so AI-created groups always look distinct.
    static func iconForGroupName(_ name: String) -> String {
        let lower = name.lowercased()
        let keywordMap: [(keywords: [String], icon: String)] = [
            (["仕事", "work", "job", "業務", "プロジェクト", "project"], "briefcase"),
            (["アイデア", "idea", "発想", "ひらめき"], "lightbulb"),
            (["メモ", "note", "ノート", "memo"], "note.text"),
            (["スター", "star", "お気に入り", "favorite"], "star"),
            (["買い物", "shopping", "shop", "購入", "todo", "タスク", "task"], "cart"),
            (["旅行", "travel", "trip", "旅"], "airplane"),
            (["読書", "book", "read", "本", "文献"], "book"),
            (["音楽", "music", "song", "曲"], "music.note"),
            (["健康", "health", "体", "運動", "gym"], "heart"),
            (["学習", "learn", "study", "勉強", "学校"], "graduationcap"),
            (["コード", "code", "開発", "dev", "programming", "エンジニア"], "chevron.left.forwardslash.chevron.right"),
            (["会議", "meeting", "mtg", "ミーティング"], "person.2"),
            (["家", "home", "house", "自宅", "family"], "house"),
            (["食事", "food", "recipe", "料理", "レシピ"], "fork.knife"),
            (["お金", "money", "finance", "財務", "予算", "budget"], "yensign.circle"),
        ]
        for entry in keywordMap {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                return entry.icon
            }
        }
        // Stable random: hash the name for deterministic assignment.
        let fallbacks = ["sparkles", "paperplane", "bookmark", "tag", "folder.badge.plus",
                         "tray.and.arrow.down", "archivebox", "pin", "flag", "bell"]
        let idx = abs(name.hashValue) % fallbacks.count
        return fallbacks[idx]
    }

    /// Generate a deterministic but visually distinct hex color for a new group
    /// based on the group name. Uses a palette of warm/neutral tones that
    /// complement the Flote sticky-note aesthetic.
    static func colorHexForGroupName(_ name: String) -> String {
        let palette = [
            "#F4A261", "#E76F51", "#2A9D8F", "#457B9D", "#6A4C93",
            "#F4D35E", "#79B473", "#A8DADC", "#E9C46A", "#B07D62",
            "#D4A5A5", "#9ECFB0", "#A0C4D8", "#C9ADE7", "#F7B5CA",
        ]
        let idx = abs(name.hashValue) % palette.count
        return palette[idx]
    }

    func renameGroup(id: UUID, to newName: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[i].name = trimmed
        scheduleSave()
    }

    func moveGroup(id: UUID, toParent newParent: UUID?) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        // Prevent cycles: the new parent must not be a descendant of self.
        if let newParent = newParent, isDescendant(newParent, of: id) {
            return
        }
        groups[i].parentGroupID = newParent
        scheduleSave()
    }

    /// Delete a group. Its notes are promoted to the parent group (or become
    /// active if the deleted group was at root). Sub-groups are re-parented
    /// the same way — no data loss.
    func deleteGroup(id: UUID) {
        guard let deleting = groups.first(where: { $0.id == id }) else { return }
        // Don't allow deleting the Inbox.
        if id == inboxID { return }
        let newParent = deleting.parentGroupID

        // Re-parent sub-groups.
        for i in groups.indices where groups[i].parentGroupID == id {
            groups[i].parentGroupID = newParent
        }

        // Promote notes: move everything up one level. If the deleted group
        // was at root, they migrate to Inbox instead of leaving the tree.
        let targetParent = newParent ?? inboxID
        if let targetParent = targetParent {
            for note in NoteManager.shared.notes(inGroup: id) {
                NoteManager.shared.moveNote(id: note.id, toGroup: targetParent)
            }
        }

        groups.removeAll { $0.id == id }
        scheduleSave()
        // Notify observers so the Groups pane re-renders immediately.
        // Without this, panels that belonged to sub-groups of the deleted
        // group keep showing a stale groupID until the user switches tabs.
        notifyGroupsChanged()
    }

    // MARK: Query

    func group(byID id: UUID) -> NoteGroup? {
        groups.first(where: { $0.id == id })
    }

    /// Returns true when the group has at least one direct subgroup or at least
    /// one note that is not parked in Inbox. Used by the UI to decide whether
    /// to show a deletion confirmation dialog (D1: only prompt when non-empty).
    func groupHasChildren(id: UUID) -> Bool {
        let hasSubgroups = groups.contains { $0.parentGroupID == id }
        if hasSubgroups { return true }
        let noteCount = NoteManager.shared.notes(inGroup: id).count
        return noteCount > 0
    }

    /// Recursive count of all descendant subgroups (direct + indirect).
    func descendantSubgroupCount(of id: UUID) -> Int {
        var count = 0
        var queue = children(of: id)
        while !queue.isEmpty {
            count += queue.count
            queue = queue.flatMap { children(of: $0.id) }
        }
        return count
    }

    /// Total note count inside the group AND all its descendant subgroups.
    func totalNoteCount(of id: UUID) -> Int {
        var total = NoteManager.shared.notes(inGroup: id).count
        for child in children(of: id) {
            total += totalNoteCount(of: child.id)
        }
        return total
    }

    /// Top-level groups (parentGroupID == nil).
    var rootGroups: [NoteGroup] {
        groups.filter { $0.parentGroupID == nil }
            .sorted(by: Self.inboxFirstThenName)
    }

    /// Direct children of a given group.
    func children(of id: UUID) -> [NoteGroup] {
        groups.filter { $0.parentGroupID == id }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Whether `candidate` is the same as or a descendant of `ancestor`.
    /// Used to prevent parent/child cycles.
    private func isDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
        if candidate == ancestor { return true }
        var current: UUID? = candidate
        var hops = 0
        while let id = current, hops < 64 {
            if id == ancestor { return true }
            current = group(byID: id)?.parentGroupID
            hops += 1
        }
        return false
    }

    /// Sort comparator: Inbox first, then alphabetical.
    private static func inboxFirstThenName(_ a: NoteGroup, _ b: NoteGroup) -> Bool {
        if a.name == "Inbox" { return true }
        if b.name == "Inbox" { return false }
        return a.name.localizedCompare(b.name) == .orderedAscending
    }

    // MARK: Persistence

    func save() {
        do {
            try PersistenceService.saveGroups(groups)
        } catch {
            print("[Flote] Group save failed: \(error.localizedDescription)")
        }
    }

    /// Force any pending debounced save to flush now. Used on app termination.
    func flushSaveNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return
            }
            self?.save()
        }
    }
}

// MARK: - Groups tab selection state

@Observable
@MainActor
final class GroupsSelectionState {
    static let shared = GroupsSelectionState()
    /// Currently-focused group in the Groups tab. nil = show Inbox by default.
    var selectedGroupID: UUID?
    private init() {}
}

// MARK: - Learning (few-shot classification examples)

/// A single past classification decision. The model reads recent examples as
/// few-shot context so it learns which content the user parks in which group.
// BACKUP-MODEL-PURE-BEGIN
struct ClassificationExample: Codable, Identifiable {
    let id: UUID
    var noteText: String
    var groupName: String
    var recordedAt: Date

    init(noteText: String, groupName: String) {
        self.id = UUID()
        // Trim to first 200 chars so the prompt stays compact and we don't
        // leak very long notes into the LLM context.
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.noteText = trimmed.count > 200 ? String(trimmed.prefix(200)) : trimmed
        self.groupName = groupName
        self.recordedAt = Date()
    }
}
// BACKUP-MODEL-PURE-END

@Observable
@MainActor
final class LearningManager {
    static let shared = LearningManager()

    /// Hard cap so the prompt never grows unbounded and the file stays small.
    private let maxExamples = 100

    private(set) var examples: [ClassificationExample] = []
    private var saveTask: Task<Void, Never>?

    private init() {}

    // MARK: Lifecycle

    func load() {
        do {
            examples = try PersistenceService.loadLearning()
        } catch {
            examples = []
        }
    }

    // MARK: Recording

    /// Record a user-confirmed classification. Skips empty text / empty group
    /// / exact duplicate of the most recent example (common when the user
    /// drops the same note twice in a row).
    func record(noteText: String, groupName: String) {
        let trimmedText = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGroup = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !trimmedGroup.isEmpty else { return }
        if let last = examples.last,
           last.groupName == trimmedGroup,
           last.noteText.prefix(100) == trimmedText.prefix(100) {
            return
        }
        examples.append(ClassificationExample(
            noteText: trimmedText,
            groupName: trimmedGroup
        ))
        // Safe FIFO truncation — using suffix() sidesteps the possibility of
        // removeFirst overrunning the array if the count were ever off-by-one.
        if examples.count > maxExamples {
            examples = Array(examples.suffix(maxExamples))
        }
        scheduleSave()
    }

    /// Force any pending debounced save to flush now. Used on app termination.
    func flushSaveNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    // MARK: Query

    /// Return the N most recent examples for few-shot use, newest last.
    func recentExamples(limit: Int = 8) -> [ClassificationExample] {
        let slice = examples.suffix(limit)
        return Array(slice)
    }

    // MARK: Persistence

    func save() {
        do {
            try PersistenceService.saveLearning(examples)
        } catch {
            print("[Flote] Learning save failed: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return
            }
            self?.save()
        }
    }
}
