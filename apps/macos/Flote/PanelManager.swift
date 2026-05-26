import AppKit
import SwiftUI

@MainActor
final class PanelManager {

    static let shared = PanelManager()

    private var panels: [UUID: FloatingPanel] = [:]
    private var observerTokens: [UUID: [NSObjectProtocol]] = [:]
    /// Set of note IDs currently animating stow/expand. Suppresses observer writes.
    private var animatingNoteIDs: Set<UUID> = []

    private init() {}

    // MARK: - Panel lifecycle

    func createPanel(for note: StickyNote) {
        guard panels[note.id] == nil else { return }

        // Force the unified fixed width so every panel is uniform regardless
        // of what was persisted. Height remains per-note (content-driven).
        let desiredSize = CGSize(
            width: FloatingPanel.fixedContentWidth,
            height: note.size.height
        )
        let position = Self.validatedPosition(
            for: note.position,
            size: desiredSize,
            noteID: note.id
        )
        let rect = NSRect(origin: position, size: desiredSize)
        let panel = FloatingPanel(
            contentRect: rect,
            content: NoteView(noteID: note.id)
        )
        panel.noteID = note.id
        panels[note.id] = panel
        // Show without stealing keyboard focus from other apps.
        // makeKeyAndOrderFront would hijack typing from the currently focused app.
        panel.orderFrontRegardless()

        // Observe window move/resize to sync back to model. Store tokens for cleanup.
        var tokens: [NSObjectProtocol] = []

        tokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            let noteID = note.id
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
            let noteID = note.id
            Task { @MainActor in
                guard self.panels[noteID] != nil,
                      NoteManager.shared.note(byID: noteID) != nil,
                      !self.animatingNoteIDs.contains(noteID) else { return }
                let size = panel.frame.size
                NoteManager.shared.updateSize(
                    id: noteID,
                    size: CGSize(width: size.width, height: size.height)
                )
            }
        })

        observerTokens[note.id] = tokens
    }

    func removePanel(for noteID: UUID) {
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
              note.stowState == .expanded else { return }
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
    }

    // MARK: - Focus

    func focusPanel(noteID: UUID) {
        guard let panel = panels[noteID] else { return }
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
    func reloadTextView(for noteID: UUID, data: Data?, plain: String) {
        // FloatingPanel uses contentView (NSHostingView) directly, not
        // contentViewController. Early guarding on .view meant this function
        // was an unconditional no-op after undo.
        guard let panel = panels[noteID],
              let content = panel.contentView else { return }
        // Walk the view hierarchy to find FloteTextView and reload.
        func findFloteTextView(in view: NSView) -> FloteTextView? {
            if let tv = view as? FloteTextView { return tv }
            for sub in view.subviews {
                if let found = findFloteTextView(in: sub) { return found }
            }
            return nil
        }
        if let tv = findFloteTextView(in: content) {
            if let d = data, let attrStr = RichTextStorage.unarchive(d) {
                tv.textStorage?.setAttributedString(attrStr)
            } else {
                tv.string = plain
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
