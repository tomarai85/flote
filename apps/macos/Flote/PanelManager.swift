import AppKit
import SwiftUI

// FLOTE-DECK-PURE-BEGIN
// (pure: Foundation-only — extracted verbatim by .harness/tests/
// s16-deck-test.sh, so the harness always compiles the SHIPPING logic.)

/// S16 deck (one window, many notes — Antinote's tab mechanism): pure
/// ordering/navigation over member IDs. Every wrap/successor rule lives
/// here and is tested standalone; PanelManager only wires the results to
/// panels and the model.
enum FloteDeck {
    /// Canonical member order: deckOrder ascending; a nil order sorts
    /// first (defensive — setDeck always writes one), ties broken by
    /// createdAt then uuidString so the order is total and stable across
    /// relaunches.
    static func orderedIDs(
        _ members: [(id: UUID, order: Int?, createdAt: Date)]
    ) -> [UUID] {
        members.sorted { a, b in
            let ao = a.order ?? Int.min, bo = b.order ?? Int.min
            if ao != bo { return ao < bo }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }.map(\.id)
    }

    /// Next member after `current`, wrapping past the end. nil when
    /// `current` is absent or the deck has fewer than 2 members.
    static func next(in deck: [UUID], after current: UUID) -> UUID? {
        guard deck.count >= 2, let i = deck.firstIndex(of: current) else { return nil }
        return deck[(i + 1) % deck.count]
    }

    /// Previous member before `current`, wrapping past the start.
    static func previous(in deck: [UUID], before current: UUID) -> UUID? {
        guard deck.count >= 2, let i = deck.firstIndex(of: current) else { return nil }
        return deck[(i + deck.count - 1) % deck.count]
    }

    /// Append slot for a new member: max existing order + 1 (empty = 0).
    static func nextOrder(existing: [Int?]) -> Int {
        (existing.compactMap { $0 }.max() ?? -1) + 1
    }

    /// Which member the panel shows after `removed` leaves the deck: its
    /// successor, wrapping past the end. nil when the deck had no other
    /// member (the panel closes — old single-note behavior) or `removed`
    /// was not a member.
    static func shownAfterRemoval(of removed: UUID, in deck: [UUID]) -> UUID? {
        guard let i = deck.firstIndex(of: removed) else { return nil }
        let rest = deck.enumerated().filter { $0.offset != i }.map(\.element)
        guard !rest.isEmpty else { return nil }
        return rest[i % rest.count]
    }

    /// 1-based position for the fleeting "2/5" indicator. nil when `id`
    /// is not a member.
    static func position(of id: UUID, in deck: [UUID]) -> (index: Int, count: Int)? {
        guard let i = deck.firstIndex(of: id) else { return nil }
        return (i + 1, deck.count)
    }

    /// ⌘⇧W "close other tabs": the members that leave (everything except
    /// `kept`, deck order preserved). Empty = no-op: `kept` absent, or the
    /// deck has no other member (deck of 1).
    static func othersToClose(keeping kept: UUID, in deck: [UUID]) -> [UUID] {
        guard deck.contains(kept) else { return [] }
        return deck.filter { $0 != kept }
    }

    /// ⌘⌥W detach: which member the deck panel shows after `detached`
    /// leaves to become its own sticky — the successor, wrapping past the
    /// end. nil = no-op: a deck of 1 has nothing to detach FROM (the note
    /// is already independent), and a non-member can't detach.
    static func successorAfterDetach(of detached: UUID, in deck: [UUID]) -> UUID? {
        guard deck.count >= 2 else { return nil }
        return shownAfterRemoval(of: detached, in: deck)
    }

    /// ⌘⇧] / ⌘⇧[ reorder: canonical member order after moving `id` by
    /// `offset` slots (+1 = right, -1 = left). nil = no-op: `id` absent,
    /// deck < 2, or the move runs off an edge (edges CLAMP — a move is a
    /// placement, not a cycle, so unlike ⌘]/⌘[ it never wraps).
    static func moved(_ id: UUID, by offset: Int, in deck: [UUID]) -> [UUID]? {
        guard deck.count >= 2, let i = deck.firstIndex(of: id) else { return nil }
        let j = i + offset
        guard j >= 0, j < deck.count, j != i else { return nil }
        var out = deck
        out.remove(at: i)
        out.insert(id, at: j)
        return out
    }
}
// FLOTE-DECK-PURE-END

extension Notification.Name {
    /// Posted one runloop after a deck switch, userInfo "noteID" = the
    /// newly shown note (so its fresh NoteView is mounted and listening).
    /// NoteView answers with the fleeting "2/5" position flash.
    static let floteDeckSwitched = Notification.Name("floteDeckSwitched")
}

@MainActor
final class PanelManager {

    static let shared = PanelManager()

    private var panels: [UUID: FloatingPanel] = [:]
    private var observerTokens: [UUID: [NSObjectProtocol]] = [:]
    /// Set of note IDs currently animating stow/expand. Suppresses observer writes.
    private var animatingNoteIDs: Set<UUID> = []
    /// Note IDs whose panels were hidden by the global "hide all" toggle
    /// (⌥⇧A, Antinote ⌥A / Noticky ⌘⇧H class). PURELY VISUAL: orderOut only —
    /// isPanelOpen and every other model field stay untouched, so the panels
    /// come back exactly where they were. In-memory only by design: a
    /// relaunch always starts with every open note visible.
    private var hiddenBySummonToggle: Set<UUID> = []

    private init() {}

    // MARK: - Bulk show/hide toggle (⌥⇧A)

    /// One press hides every visible panel; the next press brings them all
    /// back. "Get my screen back NOW" — the most-used gesture in this app
    /// class, so it must never wedge: panels mid-animation are skipped when
    /// hiding (StowAnimator owns their frame; orderOut mid-flight leaves the
    /// animator writing to an invisible window and the completion state is
    /// anyone's guess). Strings (rolledUp) and minis hide and restore too.
    func toggleAllNotesVisibility() {
        if hiddenBySummonToggle.isEmpty {
            hideAllPanels()
        } else {
            showToggleHiddenPanels()
        }
    }

    private func hideAllPanels() {
        for (id, panel) in panels {
            guard !animatingNoteIDs.contains(id) else { continue }
            guard panel.isVisible else { continue }
            panel.orderOut(nil)
            hiddenBySummonToggle.insert(id)
        }
    }

    /// Restore everything the toggle hid, exactly where it was (orderOut
    /// never moved the frames). orderFrontRegardless mirrors createPanel:
    /// show without stealing keyboard focus from the app the user is in.
    private func showToggleHiddenPanels() {
        for id in hiddenBySummonToggle {
            panels[id]?.orderFrontRegardless()
        }
        hiddenBySummonToggle.removeAll()
    }

    /// A panel is being summoned by direct user action while the toggle has
    /// panels hidden — the user clearly wants notes visible again. Restore
    /// the whole hidden set (a lone unhidden note next to invisibly-"open"
    /// siblings is the confusing state, and a reset WITHOUT restore would
    /// wedge the hidden panels: visible=false with no toggle path back).
    private func clearSummonToggleForUserAction() {
        guard !hiddenBySummonToggle.isEmpty else { return }
        showToggleHiddenPanels()
    }

    // MARK: - Panel lifecycle

    /// `focus: true` = the creation was a direct user ask (hotkey /
    /// menu-bar / Settings button) — the note starts ready to type when the
    /// pref allows. Launch restore keeps the default `false`: restoring
    /// panels must never steal the keyboard from whatever the user was doing.
    func createPanel(for note: StickyNote, focus: Bool = false) {
        guard panels[note.id] == nil else { return }

        // S16 deck redirect: the note is a hidden member of a deck whose
        // panel is already on screen. "Opening" it means switching that
        // panel to it — never a second window for the same deck. This is
        // the single funnel all open paths share (search palette, Groups
        // tab, menu-bar recents all call createPanel), and it also
        // self-heals a corrupt restore where two members claim
        // isPanelOpen (the second createPanel lands here and the deck
        // converges on one panel).
        if let sibling = deckSiblingWithPanel(of: note.id) {
            // Same user intent as focusPanel: surface the deck's panel
            // (and un-hide the ⌥⇧A set) so the switch is actually seen.
            clearSummonToggleForUserAction()
            deckSwitch(from: sibling, to: note.id, direction: 1)
            panels[note.id]?.orderFrontRegardless()
            if focus, NoteManager.newNoteFocusEnabled {
                panels[note.id]?.makeKey()
            }
            return
        }

        // A note opening while the ⌥⇧A toggle has panels hidden means the
        // user wants notes on screen again — restore the hidden set (no-op
        // at launch restore: the set starts empty every run).
        clearSummonToggleForUserAction()

        // Preset width for preset-managed notes; a user-resized note owns
        // its geometry and reopens exactly as the user left it.
        let minS = FloatingPanel.userMinSize
        let desiredSize = CGSize(
            width: note.userResized
                ? max(note.size.width, minS.width) : FloatingPanel.fixedContentWidth,
            height: max(note.size.height, note.userResized ? minS.height : 0)
        )
        let position = Self.validatedPosition(
            for: note.position,
            size: desiredSize,
            noteID: note.id
        )
        let rect = NSRect(origin: position, size: desiredSize)
        // The panel builds its own SwiftUI root (DeckRootView) around the
        // note ID — deck switches later swap that root's content without
        // ever touching the window (S16).
        let panel = FloatingPanel(contentRect: rect, noteID: note.id)
        // S6 lock: a locked note's panel is excluded from screen capture /
        // screen sharing from the moment it exists.
        panel.sharingType = note.isLocked ? .none : .readOnly
        panels[note.id] = panel
        // Show without stealing keyboard focus from other apps.
        // makeKeyAndOrderFront would hijack typing from the currently focused app.
        panel.orderFrontRegardless()
        if focus && NoteManager.newNoteFocusEnabled {
            // User-initiated creation: ready to type. .nonactivatingPanel
            // takes key status without activating Flote, so the previous
            // app stays frontmost — only the keyboard moves to the note.
            panel.makeKey()
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel else { return }
                MainActor.assumeIsolated {
                    guard self.panels[note.id] != nil else { return }
                    if let content = panel.contentView,
                       let tv = Self.findTextView(in: content) {
                        panel.makeFirstResponder(tv)
                    }
                }
            }
        }

        // Observe window move/resize to sync back to model. Store tokens for cleanup.
        var tokens: [NSObjectProtocol] = []

        tokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            // S16 deck-aware: attribute the move to whichever note the
            // panel is SHOWING right now — deck switches re-target the
            // panel (panel.noteID) without re-registering observers.
            guard let noteID = panel.noteID else { return }
            Task { @MainActor in
                // Verify panel still exists AND note still exists before writing.
                // Prevents stale writes after removePanel/deleteNote.
                guard self.panels[noteID] != nil,
                      NoteManager.shared.note(byID: noteID) != nil,
                      !self.animatingNoteIDs.contains(noteID) else { return }
                let origin = panel.frame.origin
                NoteManager.shared.updatePosition(
                    id: noteID,
                    position: CGPoint(x: origin.x, y: origin.y)
                )
            }
        })

        tokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            // S16 deck-aware: same dynamic re-targeting as didMove above.
            guard let noteID = panel.noteID else { return }
            // Read on the notification turn: by the time the Task hops back
            // to the MainActor the drag may already have ended.
            let isUserDrag = panel.inLiveResize
            Task { @MainActor in
                guard self.panels[noteID] != nil,
                      NoteManager.shared.note(byID: noteID) != nil,
                      !self.animatingNoteIDs.contains(noteID) else { return }
                let size = panel.frame.size
                NoteManager.shared.updateSize(
                    id: noteID,
                    size: CGSize(width: size.width, height: size.height)
                )
                // Free resize: an edge drag hands the note ownership of its
                // geometry — presets and content auto-fit stop touching it.
                if isUserDrag { NoteManager.shared.markUserResized(id: noteID) }
            }
        })

        observerTokens[note.id] = tokens
    }

    func removePanel(for noteID: UUID) {
        // A closed panel must not linger in the toggle-hidden set: a stale
        // id there would flip the next ⌥⇧A press into a "show" for a panel
        // that no longer exists instead of hiding the rest.
        hiddenBySummonToggle.remove(noteID)
        guard let panel = panels[noteID] else { return }
        // Suppress any in-flight observer Tasks that might fire after removal.
        animatingNoteIDs.insert(noteID)
        observerTokens[noteID]?.forEach { NotificationCenter.default.removeObserver($0) }
        observerTokens.removeValue(forKey: noteID)
        panel.orderOut(nil)
        panels.removeValue(forKey: noteID)
        animatingNoteIDs.remove(noteID)
    }

    /// Whether a floating panel currently exists for this note. Used by the
    /// Groups tab to decide between "create a fresh panel" and "focus the
    /// existing one".
    /// StowAnimator owns this panel's frame right now (S7-3 radius guard).
    func isAnimating(noteID: UUID) -> Bool {
        animatingNoteIDs.contains(noteID)
    }

    func hasPanel(noteID: UUID) -> Bool {
        panels[noteID] != nil
    }

    func updatePanelPosition(noteID: UUID) {
        guard let panel = panels[noteID],
              let note = NoteManager.shared.note(byID: noteID)
        else { return }
        let origin = NSPoint(x: note.position.x, y: note.position.y)
        panel.setFrameOrigin(origin)
    }

    /// Resize the panel to fit the text content height.
    /// Skips when a stow/expand animation is already in progress — fitting
    /// mid-animation would instantly jump the frame and break the transition.
    func fitPanelToContent(noteID: UUID, textHeight: CGFloat) {
        guard !animatingNoteIDs.contains(noteID) else { return }
        guard let panel = panels[noteID] else { return }
        guard let note = NoteManager.shared.note(byID: noteID),
              note.stowState == .expanded,
              // A user-resized note owns its height; overflow scrolls.
              !note.userResized else { return }
        // Chrome: topBar row1(22) + spacing(2) + row2 Organize(~24) + text pads(14).
        let totalHeight = textHeight + 62
        // Temporarily suppress the resize observer so the auto-fit doesn't
        // spam saves, but use a different flag to avoid blocking stow.
        animatingNoteIDs.insert(noteID)
        panel.fitToContentHeight(totalHeight)
        NoteManager.shared.updateSize(
            id: noteID,
            size: CGSize(width: panel.frame.width, height: panel.frame.height)
        )
        DispatchQueue.main.async { [weak self] in
            self?.animatingNoteIDs.remove(noteID)
        }
    }

    // MARK: - Animation guard

    /// Suppresses observer writes during animated stow/expand transitions.
    func beginAnimating(noteID: UUID) {
        animatingNoteIDs.insert(noteID)
    }

    func endAnimating(noteID: UUID) {
        animatingNoteIDs.remove(noteID)
        // A radius change during this panel's flight was skipped by the
        // animation gate — settle it now that the flight is over (r3 minor).
        panels[noteID]?.applyCornerRadiusIfSafe()
    }

    // MARK: - Focus

    func focusPanel(noteID: UUID) {
        // A palette/recents click during a 0.45s balloon flight must not
        // start an overlapping transition (Evaluator r3 #4) — the flight's
        // completion re-shows the panel; focusing can wait for the next tap.
        guard !animatingNoteIDs.contains(noteID) else { return }
        guard let panel = panels[noteID] else { return }
        // Explicit user summon while the ⌥⇧A toggle has panels hidden —
        // same intent as opening a note: bring the hidden set back.
        clearSummonToggleForUserAction()
        // If stowed, expand first.
        if let note = NoteManager.shared.note(byID: noteID) {
            switch note.stowState {
            case .rolledUp:
                StowAnimator.shared.expand(panel: panel, noteID: noteID)
            case .mini:
                StowAnimator.shared.expandFromMini(panel: panel, noteID: noteID)
            case .expanded:
                break
            }
        }
        NoteManager.shared.bringToFront(id: noteID)
        // focusPanel is called by explicit user action (clicking a note row
        // in Settings or MenuBar). Flote is already the active app at that
        // point, so making the panel key is fine — it only shifts key status
        // between Flote's own windows, not from another app.
        panel.makeKeyAndOrderFront(nil)
    }

    /// Frames of every OTHER stowed string panel (balloon-stow collision
    /// avoidance — strings hang side by side, never stacked).
    func stringPanelFrames(excluding noteID: UUID) -> [NSRect] {
        panels.compactMap { id, panel in
            guard id != noteID,
                  NoteManager.shared.note(byID: id)?.stowState == .rolledUp
            else { return nil }
            return panel.frame
        }
    }

    /// Size preset changed in Settings: re-fit every open PRESET-MANAGED
    /// panel to the new suggestion (instant setFrame, top-left anchored).
    /// User-resized notes own their geometry and are never touched.
    func applySizePreset() {
        let preset = FloatingPanel.SizePreset.current.size
        for (id, panel) in panels where !animatingNoteIDs.contains(id) {
            // Strings (44pt) and minis (48pt) own their geometry — only
            // expanded notes follow the preset (Evaluator r3 #3).
            guard let note = NoteManager.shared.note(byID: id),
                  note.stowState == .expanded, !note.userResized else { continue }
            var f = panel.frame
            let height = max(f.height, preset.height)
            guard abs(f.width - preset.width) > 0.5 || abs(f.height - height) > 0.5 else { continue }
            f.origin.y -= (height - f.height)   // keep top-left anchored
            f.size = CGSize(width: preset.width, height: height)
            panel.setFrame(f, display: true, animate: false)
        }
    }

    /// Legacy name (pre-2026-07-11 call sites).
    func applyWidthPreset() { applySizePreset() }

    /// Menu-bar 整列 (Codex UX gap): pack every open panel into neat
    /// top-to-bottom columns on the main screen, left to right. Instant
    /// setFrame only — no animator on SwiftUI-backed panels (crash
    /// invariant), and skip panels mid-animation. Positions persist through
    /// the normal didMove observers.
    func tidyVisiblePanels() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let margin: CGFloat = 24
        let gap: CGFloat = 16
        // Stable, reading-order sort: current top-left, rows first.
        let ordered = panels.filter { id, _ in
            !animatingNoteIDs.contains(id)
                // Strings (balloon stow) live at the top edge by design and
                // minis are deliberate dots — tidy packs only expanded notes.
                && NoteManager.shared.note(byID: id)?.stowState == .expanded
        }
            .sorted { a, b in
                let fa = a.value.frame, fb = b.value.frame
                if abs(fa.maxY - fb.maxY) > 40 { return fa.maxY > fb.maxY }
                return fa.minX < fb.minX
            }
        var x = screen.minX + margin
        var topY = screen.maxY - margin
        var columnWidth: CGFloat = 0
        for (_, panel) in ordered {
            let size = panel.frame.size
            if topY - size.height < screen.minY + margin,
               topY < screen.maxY - margin {
                // Column full — start the next one.
                x += columnWidth + gap
                topY = screen.maxY - margin
                columnWidth = 0
            }
            let origin = NSPoint(x: x, y: topY - size.height)
            panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
            columnWidth = max(columnWidth, size.width)
            topY -= size.height + gap
        }
    }

    // MARK: - Stow controls

    // Toggle between expanded and folded states.
    func toggleStow(noteID: UUID) {
        // Ignore rapid clicks while an animation is in flight. Overlapping
        // setFrame calls leave the panel frozen at an intermediate size with
        // SwiftUI content collapsed (the bug reported: 巻取り高速連打).
        guard !animatingNoteIDs.contains(noteID) else { return }
        guard let panel = panels[noteID],
              let note = NoteManager.shared.note(byID: noteID)
        else { return }

        switch note.stowState {
        case .expanded:
            StowAnimator.shared.rollUp(panel: panel, noteID: noteID)
        case .rolledUp:
            StowAnimator.shared.expand(panel: panel, noteID: noteID)
        case .mini:
            // Direct mini → rolledUp transition (M4 / D3).
            // The roll-up button while in mini goes straight to rolledUp
            // without an intermediate expand.
            StowAnimator.shared.miniToRolledUp(panel: panel, noteID: noteID)
        }
    }

    // Toggle between expanded and mini states.
    // When already rolledUp, go directly to mini (D3: 1-step direct transition).
    func toggleMini(noteID: UUID) {
        guard !animatingNoteIDs.contains(noteID) else { return }
        guard let panel = panels[noteID],
              let note = NoteManager.shared.note(byID: noteID)
        else { return }

        switch note.stowState {
        case .expanded:
            StowAnimator.shared.shrinkToMini(panel: panel, noteID: noteID)
        case .mini:
            StowAnimator.shared.expandFromMini(panel: panel, noteID: noteID)
        case .rolledUp:
            // Direct rolledUp → mini transition (M4 / D3).
            // Bypasses expand so the intermediate state never flashes.
            StowAnimator.shared.rollUpToMini(panel: panel, noteID: noteID)
        }
    }

    // MARK: - Deck (S16 one-window-many-notes)
    //
    // A panel can host a SEQUENCE of notes (the deck — Antinote's tabs).
    // The deck is model state (StickyNote.deckID/deckOrder); the panel
    // only ever shows ONE member. Switching = swapping the SwiftUI root's
    // content. CRASH INVARIANT: the panel's frame is NEVER animated and
    // never even changes on a switch — the incoming note adopts it.

    enum DeckMove { case next, previous, first }

    /// ⌘] / ⌘[ / two-finger swipe / ⌘1 on the focused panel. No-op for a
    /// solo note (deck < 2), while stowed/mini, or mid-animation.
    func deckNavigate(from noteID: UUID, move: DeckMove) {
        guard !animatingNoteIDs.contains(noteID),
              NoteManager.shared.note(byID: noteID)?.stowState == .expanded
        else { return }
        let deck = NoteManager.shared.deckMemberIDs(with: noteID)
        let target: UUID?
        var direction = 1
        switch move {
        case .next:
            target = FloteDeck.next(in: deck, after: noteID)
        case .previous:
            target = FloteDeck.previous(in: deck, before: noteID)
            direction = -1
        case .first:
            // Jump to front (⌘1): the deck's first note, sliding "back".
            target = deck.first != noteID ? deck.first : nil
            direction = -1
        }
        guard let target else { return }
        deckSwitch(from: noteID, to: target, direction: direction)
    }

    /// Indicator dot click: jump straight to a member.
    func deckJump(from currentID: UUID, to targetID: UUID) {
        guard currentID != targetID,
              !animatingNoteIDs.contains(currentID),
              NoteManager.shared.note(byID: currentID)?.stowState == .expanded
        else { return }
        let deck = NoteManager.shared.deckMemberIDs(with: currentID)
        guard let fromIdx = deck.firstIndex(of: currentID),
              let toIdx = deck.firstIndex(of: targetID) else { return }
        deckSwitch(from: currentID, to: targetID,
                   direction: toIdx > fromIdx ? 1 : -1)
    }

    /// ⌘T (panel-local, NOT global): a new blank note appended to THIS
    /// panel's deck and shown — the "new tab". A solo note becomes a deck
    /// of two (it gets a fresh deckID at order 0).
    func deckNewNote(from noteID: UUID) {
        guard panels[noteID] != nil,
              !animatingNoteIDs.contains(noteID),
              let current = NoteManager.shared.note(byID: noteID),
              current.stowState == .expanded else { return }
        let deckID: UUID
        if let existing = current.deckID {
            deckID = existing
        } else {
            deckID = UUID()
            NoteManager.shared.setDeck(id: noteID, deckID: deckID, order: 0)
        }
        let orders = NoteManager.shared.deckMembers(deckID: deckID).map(\.deckOrder)
        let fresh = NoteManager.shared.createNote()
        NoteManager.shared.setDeck(id: fresh.id, deckID: deckID,
                                   order: FloteDeck.nextOrder(existing: orders))
        deckSwitch(from: noteID, to: fresh.id, direction: 1)
    }

    /// Deck-aware "put the SHOWN note away" — the single tail shared by
    /// ⌘W / the archive button (`archive: true`) and AI-sort put-away
    /// (`archive: false`; the caller already grouped + closed the note).
    /// The departing note LEAVES the deck (fields cleared — ⌘] must never
    /// cycle back to an archived note); the panel advances to the next
    /// member, or goes away entirely when the deck had no other member
    /// (deck of 1 = the old single-note behavior, unchanged).
    func closeShownNote(noteID: UUID, archive: Bool) {
        guard !animatingNoteIDs.contains(noteID) else { return }
        let deck = NoteManager.shared.deckMemberIDs(with: noteID)
        let successor = FloteDeck.shownAfterRemoval(of: noteID, in: deck)
        if archive {
            // May DISCARD a strictly-empty note outright (F2 hygiene) —
            // its deck fields die with it; setDeck below is then a no-op.
            NoteManager.shared.archiveNote(id: noteID)
        }
        NoteManager.shared.setDeck(id: noteID, deckID: nil, order: nil)
        if let successor, panels[noteID] != nil {
            deckSwitch(from: noteID, to: successor, direction: 1)
        } else {
            removePanel(for: noteID)
        }
    }

    /// ⌘W-family close for ANY one deck member (dot-row × / dot menu
    /// このタブを閉じる). The SHOWN member takes the normal ⌘W path (the
    /// panel advances, deck-of-1 closes it); a HIDDEN member just leaves
    /// quietly — archived, deck fields cleared, shown note untouched.
    /// Closing = archiving, NEVER deleting: the note stays retrievable
    /// from the Groups tab (only a strictly-empty note is discarded — F2
    /// hygiene, nothing to recover).
    func deckCloseTab(_ memberID: UUID, shownID: UUID) {
        guard !animatingNoteIDs.contains(shownID) else { return }
        if memberID == shownID {
            closeShownNote(noteID: shownID, archive: true)
            return
        }
        guard NoteManager.shared.deckMemberIDs(with: shownID).contains(memberID)
        else { return }
        NoteManager.shared.archiveNote(id: memberID)
        NoteManager.shared.setDeck(id: memberID, deckID: nil, order: nil)
    }

    /// ⌘⇧W / dot menu 他のタブをすべて閉じる: archive every deck member
    /// EXCEPT `keeping`; the kept note stays on the panel and the deck
    /// collapses to 1 (dots disappear; like every collapse-to-1 the
    /// survivor keeps its deckID — harmless, ⌘T reuses it). NO confirm
    /// dialog BY DESIGN: closing archives (recoverable from the Groups
    /// tab), so a dialog would tax the common case to guard a reversible
    /// action. From the dot menu `keeping` may be a HIDDEN member — the
    /// panel switches to it first, then the rest leave. Deck of 1 = no-op.
    func deckCloseOthers(keeping keptID: UUID, shownID: UUID) {
        guard !animatingNoteIDs.contains(shownID),
              panels[shownID] != nil,
              NoteManager.shared.note(byID: shownID)?.stowState == .expanded
        else { return }
        let deck = NoteManager.shared.deckMemberIDs(with: shownID)
        let others = FloteDeck.othersToClose(keeping: keptID, in: deck)
        guard !others.isEmpty else { return }
        if keptID != shownID {
            // Surface the kept note before its siblings (including the
            // currently shown one) leave. deckJump's direction math and
            // guards apply unchanged.
            deckJump(from: shownID, to: keptID)
        }
        for member in others {
            // Archive first (may DISCARD a strictly-empty note — its deck
            // fields die with it and setDeck becomes a no-op), then leave
            // the deck so ⌘]/dots never cycle to an archived note.
            NoteManager.shared.archiveNote(id: member)
            NoteManager.shared.setDeck(id: member, deckID: nil, order: nil)
        }
    }

    /// ⌘⌥W / dot menu 独立した付箋に戻す: `memberID` LEAVES the deck and
    /// becomes an independent sticky in its own panel at a slight cascade
    /// offset. Content is never touched — only the two deck fields clear
    /// (detach can't lose text). Detaching the SHOWN member advances the
    /// deck panel to the next member first; a HIDDEN member pops out
    /// without disturbing the shown note. Deck of 1 = no-op (the note is
    /// already independent).
    func deckDetach(_ memberID: UUID, shownID: UUID) {
        guard !animatingNoteIDs.contains(shownID),
              let panel = panels[shownID],
              NoteManager.shared.note(byID: shownID)?.stowState == .expanded,
              NoteManager.shared.note(byID: memberID) != nil
        else { return }
        let deck = NoteManager.shared.deckMemberIDs(with: shownID)
        guard FloteDeck.successorAfterDetach(of: memberID, in: deck) != nil
        else { return }   // deck of 1 or non-member: no-op

        let wasKey = panel.isKeyWindow
        if memberID == shownID,
           let successor = FloteDeck.successorAfterDetach(of: memberID, in: deck) {
            deckSwitch(from: shownID, to: successor, direction: 1)
        }
        NoteManager.shared.setDeck(id: memberID, deckID: nil, order: nil)
        // Slight cascade off the deck panel so the detached sticky visibly
        // "comes out of" it. createPanel re-validates against the screen,
        // so an off-screen offset self-corrects.
        let origin = panel.frame.origin
        NoteManager.shared.updatePosition(
            id: memberID,
            position: CGPoint(x: origin.x + 28, y: origin.y - 28))
        // Same contract as every other open path (Groups tab, palette,
        // recents): the model flips isPanelOpen, THEN the panel appears.
        NoteManager.shared.openPanel(noteID: memberID)
        guard let fresh = NoteManager.shared.note(byID: memberID) else { return }
        createPanel(for: fresh)
        // Keyboard follows the note being edited: ⌘⌥W was typed INTO the
        // shown note, so its detached panel keeps the user typing there
        // (createPanel's focus flag is gated on the new-note pref, which
        // must not govern a detach — done manually, same pattern).
        if memberID == shownID, wasKey, let newPanel = panels[memberID] {
            newPanel.makeKey()
            DispatchQueue.main.async { [weak self, weak newPanel] in
                guard let self, let newPanel else { return }
                MainActor.assumeIsolated {
                    guard self.panels[memberID] === newPanel,
                          let content = newPanel.contentView,
                          let tv = Self.findTextView(in: content, noteID: memberID)
                    else { return }
                    newPanel.makeFirstResponder(tv)
                }
            }
        }
    }

    /// ⌘⇧] / ⌘⇧[: move the SHOWN note one slot right/left in the deck
    /// order. Edges clamp (no wrap — see FloteDeck.moved); the result is
    /// renumbered 0..n-1 into deckOrder, so the order persists across
    /// relaunches. Content never moves — this is pure model reordering;
    /// the dots re-render via Observation and the fleeting "2/5" flash
    /// re-fires so the move is visible.
    func deckMoveShown(_ noteID: UUID, offset: Int) {
        guard !animatingNoteIDs.contains(noteID),
              let note = NoteManager.shared.note(byID: noteID),
              note.stowState == .expanded,
              let deckID = note.deckID
        else { return }
        let deck = NoteManager.shared.deckMemberIDs(with: noteID)
        guard let reordered = FloteDeck.moved(noteID, by: offset, in: deck)
        else { return }
        for (slot, member) in reordered.enumerated() {
            NoteManager.shared.setDeck(id: member, deckID: deckID, order: slot)
        }
        // Same next-runloop discipline as deckSwitch: the flash handler
        // reads the ALREADY-updated order.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .floteDeckSwitched, object: nil,
                userInfo: ["noteID": noteID])
        }
    }

    /// The live-panel sibling of a hidden deck member (nil for solo notes
    /// and closed decks). Drives the createPanel redirect.
    private func deckSiblingWithPanel(of noteID: UUID) -> UUID? {
        NoteManager.shared.deckMemberIDs(with: noteID)
            .first { $0 != noteID && panels[$0] != nil }
    }

    /// Core switch. The window is untouched except alpha-less content:
    /// everything keyed by the shown note (panels dict, observers, ⌥⇧A
    /// hidden set, panel.noteID, capture exclusion) re-targets, the model
    /// records the new shown member, and the SwiftUI root swaps content
    /// with a subtle opacity+offset(≤8pt) slide (Reduce Motion = instant).
    private func deckSwitch(from old: UUID, to new: UUID, direction: Int) {
        guard old != new,
              let panel = panels[old],
              panels[new] == nil,
              !animatingNoteIDs.contains(old),
              let newNote = NoteManager.shared.note(byID: new) else { return }

        panels.removeValue(forKey: old)
        panels[new] = panel
        if let tokens = observerTokens.removeValue(forKey: old) {
            observerTokens[new] = tokens
        }
        if hiddenBySummonToggle.remove(old) != nil {
            hiddenBySummonToggle.insert(new)
        }
        panel.noteID = new
        // S6 lock: capture exclusion follows the incoming note from the
        // moment it can render.
        panel.sharingType = newNote.isLocked ? .none : .readOnly

        // Model: exactly ONE deck member is "open" (launch restore then
        // re-creates just the shown note's panel). The incoming note
        // adopts the panel's frame — sync it explicitly so a relaunch
        // reopens the deck exactly here (a switch moves nothing, so the
        // normal didMove/didResize observers never see it).
        NoteManager.shared.closePanel(noteID: old)
        NoteManager.shared.openPanel(noteID: new)
        NoteManager.shared.updatePosition(id: new, position: panel.frame.origin)
        NoteManager.shared.updateSize(id: new, size: panel.frame.size)
        NoteManager.shared.bringToFront(id: new)

        // Content swap — SwiftUI-only; the WINDOW frame is not touched
        // (crash invariant; see FloatingPanel's 2026-04-17 notes).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.deckModel.direction = 0
            panel.deckModel.shownNoteID = new
        } else {
            panel.deckModel.direction = direction
            withAnimation(.easeOut(duration: 0.18)) {
                panel.deckModel.shownNoteID = new
            }
        }

        // Keyboard follows the deck: when the panel is key (⌘T/⌘] were
        // typed into it), the incoming editor becomes first responder once
        // mounted. Matched by noteID — the outgoing text view is still in
        // the hierarchy while its removal transition runs.
        if panel.isKeyWindow {
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel else { return }
                MainActor.assumeIsolated {
                    guard self.panels[new] === panel,
                          let content = panel.contentView,
                          let tv = Self.findTextView(in: content, noteID: new)
                    else { return }
                    panel.makeFirstResponder(tv)
                }
            }
        }

        // Fleeting "2/5" flash — posted on the NEXT runloop so the
        // incoming NoteView is mounted and its onReceive is live.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .floteDeckSwitched, object: nil,
                userInfo: ["noteID": new])
        }
    }

    // MARK: - Undo support

    /// Look up the UndoManager attached to the panel hosting this note. Returns
    /// nil if the panel has been closed. Preferred over `NSApp.keyWindow?.undoManager`
    /// because the latter misroutes undo to Settings or another note when the
    /// user's focus shifted after Organize completed.
    func undoManager(for noteID: UUID) -> UndoManager? {
        panels[noteID]?.undoManager
    }


    /// Ask the FloteTextView inside a panel (if open) to reload its content
    /// after an undo restore. Called from NoteManager.registerOrganizeUndo so
    /// the text view stays in sync with the model without holding a strong
    /// reference to the view.
    /// S6 Touch ID lock: window-level capture exclusion follows the flag.
    func applyLockState(noteID: UUID, locked: Bool) {
        panels[noteID]?.sharingType = locked ? .none : .readOnly
    }

    /// Walk a panel's view hierarchy to its FloteTextView.
    static func findTextView(in view: NSView) -> FloteTextView? {
        if let tv = view as? FloteTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    /// S16: like findTextView, but matched to a specific note — during a
    /// deck switch BOTH the outgoing and incoming editors are briefly in
    /// the hierarchy (removal transition), and focus must land on the
    /// incoming one.
    static func findTextView(in view: NSView, noteID: UUID) -> FloteTextView? {
        if let tv = view as? FloteTextView, tv.noteID == noteID { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub, noteID: noteID) { return found }
        }
        return nil
    }

    /// The note's live text view IFF it is mid-IME-composition; nil when
    /// the panel is closed or composition is not active. Read-only probe
    /// for writers (ClipboardCollector) that must not clobber composition.
    func textViewIfComposing(noteID: UUID) -> FloteTextView? {
        guard let panel = panels[noteID], let content = panel.contentView,
              let tv = Self.findTextView(in: content), tv.hasMarkedText()
        else { return nil }
        return tv
    }

    func reloadTextView(for noteID: UUID, data: Data?, plain: String) {
        // FloatingPanel uses contentView (NSHostingView) directly, not
        // contentViewController. Early guarding on .view meant this function
        // was an unconditional no-op after undo.
        guard let panel = panels[noteID],
              let content = panel.contentView else { return }
        if let tv = Self.findTextView(in: content) {
            if let d = data, let attrStr = RichTextStorage.unarchive(d) {
                tv.textStorage?.setAttributedString(attrStr)
            } else {
                tv.string = plain
            }
            // Programmatic reloads (Organize/verbs/undo/demo) bypass the
            // typing-time detectors — re-run entity detection on the new text.
            if !tv.string.isEmpty, !tv.hasMarkedText() {
                tv.checkTextInDocument(nil)
            }
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                let height = lm.usedRect(for: tc).height
                PanelManager.shared.fitPanelToContent(noteID: noteID, textHeight: height)
            }
        }
    }

    // MARK: - Geometry validation

    /// Ensure the proposed panel frame intersects at least one connected screen's
    /// visible area. Falls back to a staggered position on the main screen when
    /// the persisted coordinate is off-screen (disconnected external display,
    /// corrupted geometry, etc.). Persists the corrected position immediately.
    private static func validatedPosition(
        for position: CGPoint,
        size: CGSize,
        noteID: UUID
    ) -> CGPoint {
        // A panel is "on screen" only when its origin point (bottom-left corner)
        // sits inside some screen's visible frame AND the panel top doesn't
        // extend far above the visible area. This catches Dock-clipped panels
        // (y < 0), disconnected external displays, and oversize heights.
        let onScreen = NSScreen.screens.contains { screen in
            let vf = screen.visibleFrame
            let originInside = vf.contains(position)
            let topOK = (position.y + size.height) <= vf.maxY + 20
            return originInside && topOK
        }
        if onScreen { return position }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return position }
        let vf = screen.visibleFrame
        // Stagger each rescued note so they don't overlap at a single point.
        let offset = CGFloat(abs(noteID.hashValue % 10) * 28)
        let clampedHeight = min(size.height, vf.height - 80)
        let fallback = CGPoint(
            x: max(vf.minX + 40, vf.midX - size.width / 2 + offset - 200),
            y: max(vf.minY + 40, vf.midY - clampedHeight / 2 - offset + 100)
        )
        NoteManager.shared.updatePosition(id: noteID, position: fallback)
        return fallback
    }
}
