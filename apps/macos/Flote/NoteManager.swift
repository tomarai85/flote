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

    private init() {}

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
        let centerX = screen.midX - GoldenRatio.medium.width / 2
        let centerY = screen.midY - GoldenRatio.medium.height / 2
        let jitterX = CGFloat.random(in: -60...60)
        let jitterY = CGFloat.random(in: -40...40)

        let maxZ = notes.map(\.zOrder).max() ?? 0
        // Fresh notes intentionally have NO group assignment. They only get a
        // group home after Organize succeeds (content + title exist), so empty
        // scratch notes never clutter Inbox.
        let note = StickyNote(
            position: CGPoint(x: centerX + jitterX, y: centerY + jitterY),
            size: GoldenRatio.medium,
            colorTheme: nextColor(),
            zOrder: maxZ + 1,
            groupID: nil,
            isPanelOpen: true,
            sortedAt: nil
        )
        notes.append(note)
        rebuildIndex()
        scheduleSave()
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
            }
        }
        scheduleSave()
    }

    func deleteNote(id: UUID) {
        // Save to history only if the note has content.
        if let note = note(byID: id),
           !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addToHistory(note)
        }
        notes.removeAll { $0.id == id }
        rebuildIndex()
        scheduleSave()
    }

    // MARK: - History

    private(set) var history: [StickyNote] = []

    func loadHistory() {
        do {
            history = try PersistenceService.loadHistory()
        } catch {
            history = []
        }
    }

    private func addToHistory(_ note: StickyNote) {
        history.append(note)
        // Keep last 20 entries.
        if history.count > 20 {
            history.removeFirst(history.count - 20)
        }
        do {
            try PersistenceService.saveHistory(history)
        } catch {
            print("[Flote] History save failed: \(error.localizedDescription)")
        }
    }

    func restoreFromHistory(id: UUID) -> StickyNote? {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return nil }
        var note = history.remove(at: index)

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
        scheduleSave()
        do {
            try PersistenceService.saveHistory(history)
        } catch {
            print("[Flote] History save failed: \(error.localizedDescription)")
        }
        return note
    }

    func clearHistory() {
        history.removeAll()
        do {
            try PersistenceService.saveHistory(history)
        } catch {
            print("[Flote] History clear failed: \(error.localizedDescription)")
        }
    }

    func updateText(id: UUID, text: String) {
        guard let index = index(for: id) else { return }
        notes[index].text = text
        notes[index].modifiedAt = Date()
        scheduleSave()
    }

    func updateRolledTitle(id: UUID, title: String?) {
        guard let index = index(for: id) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[index].rolledTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        scheduleSave()
    }

    func updateRichText(id: UUID, data: Data?, plainText: String) {
        guard let index = index(for: id) else { return }
        notes[index].richTextData = data
        notes[index].text = plainText
        notes[index].modifiedAt = Date()
        scheduleSave()
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
            nm.cancelPendingSave()
            nm.save()
            // Re-render any open panel for this note.
            DispatchQueue.main.async {
                PanelManager.shared.reloadTextView(for: noteID, data: prevData, plain: prevPlain)
            }
        }
        um.setActionName("Organize")
    }

    func updatePosition(id: UUID, position: CGPoint) {
        guard let index = index(for: id) else { return }
        notes[index].position = position
        scheduleSave()
    }

    func updateSize(id: UUID, size: CGSize) {
        guard let index = index(for: id) else { return }
        notes[index].size = size
        scheduleSave()
    }

    func updateStowState(id: UUID, state: StowState) {
        guard let index = index(for: id) else { return }
        notes[index].stowState = state
        scheduleSave()
    }

    func updateColorTheme(id: UUID, theme: NoteColorTheme) {
        guard let index = index(for: id) else { return }
        notes[index].colorTheme = theme
        scheduleSave()
    }

    func bringToFront(id: UUID) {
        guard let index = index(for: id) else { return }
        let maxZ = notes.map(\.zOrder).max() ?? 0
        notes[index].zOrder = maxZ + 1
        scheduleSave()
    }

    // MARK: - Shape annotations

    func addShape(noteID: UUID, shape: ShapeAnnotation) {
        guard let index = index(for: noteID) else { return }
        notes[index].shapeAnnotations.append(shape)
        scheduleSave()
    }

    func removeShape(noteID: UUID, shapeID: UUID) {
        guard let index = index(for: noteID) else { return }
        notes[index].shapeAnnotations.removeAll { $0.id == shapeID }
        scheduleSave()
    }

    func updateShape(noteID: UUID, shape: ShapeAnnotation) {
        guard let noteIndex = index(for: noteID) else { return }
        guard let shapeIndex = notes[noteIndex].shapeAnnotations.firstIndex(where: { $0.id == shape.id }) else { return }
        notes[noteIndex].shapeAnnotations[shapeIndex] = shape
        scheduleSave()
    }

    // Persist the expanded geometry so we can restore it after stowing.
    func saveExpandedGeometry(id: UUID, size: CGSize, position: CGPoint) {
        guard let index = index(for: id) else { return }
        // Only overwrite if the note is currently expanded (avoid overwriting with stowed dims).
        guard notes[index].stowState == .expanded else { return }
        notes[index].expandedSize = size
        notes[index].expandedPosition = position
        scheduleSave()
    }

    // MARK: - Persistence

    func load() {
        do {
            notes = try PersistenceService.load()
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

    func save() {
        do {
            try PersistenceService.save(notes)
        } catch {
            print("[Flote] Save failed: \(error.localizedDescription)")
        }
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
            await self?.save()
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
        scheduleSave()
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
        scheduleSave()
    }

    /// Archive a note: park it in Inbox if it has no group, then close the
    /// panel. The note itself is never deleted — it stays retrievable from
    /// the Groups tab. Used by ⌘W and the archive hotkey.
    func archiveNote(id: UUID) {
        guard let i = index(for: id) else { return }
        let hasContent = !notes[i].text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        // Empty scratch notes are thrown away entirely (nothing worth archiving).
        if !hasContent {
            deleteNote(id: id)
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

    /// Move a note to the specified group and record a learning example so
    /// future AI sorts pick up the user's preference. Passing the same group
    /// as the current one is a no-op (no learning noise).
    func moveNote(id: UUID, toGroup groupID: UUID) {
        guard let i = index(for: id) else { return }
        if notes[i].groupID == groupID { return }
        notes[i].groupID = groupID
        notes[i].sortedAt = Date()
        scheduleSave()

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
        var changed = false
        for i in notes.indices where notes[i].groupID == nil {
            let hasContent = !notes[i].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard hasContent else { continue }
            notes[i].groupID = inboxID
            if notes[i].sortedAt == nil {
                notes[i].sortedAt = Date()
            }
            changed = true
        }
        if changed { scheduleSave() }
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
}

// MARK: - NoteGroup model

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
            await self?.save()
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
            await self?.save()
        }
    }
}
