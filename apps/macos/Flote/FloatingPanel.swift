import AppKit
import SwiftUI

/// Hosting view that accepts first-mouse events so clicks on an inactive
/// panel immediately deliver the click to SwiftUI instead of being consumed
/// to make the panel key. Without this, the first tap on a rolled-up note
/// (when the panel is not the key window) gets eaten by the key-window
/// activation and the onTapGesture does not fire — causing the user's
/// "sometimes doesn't respond" symptom.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FloatingPanel: NSPanel {

    /// Fixed width enforced for every note panel so all notes look uniform.
    /// Height auto-sizes to content; width never varies per-note.
    static let fixedContentWidth: CGFloat = 160
    /// Legacy alias (kept for existing call sites).
    static let maxContentWidth: CGFloat = fixedContentWidth

    /// The note this panel represents. Set by PanelManager after init so
    /// native close actions (⌘W, menubar Close, etc.) know which note to
    /// archive through NoteManager.archiveNote.
    var noteID: UUID?

    init(contentRect: NSRect, content: some View) {
        super.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )

        // Floating behaviour　
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false

        // Visual style
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear

        let hostingView = FirstClickHostingView(rootView:
            content
                .frame(
                    minWidth: 20, maxWidth: .infinity,
                    minHeight: 28, maxHeight: .infinity
                )
        )
        // Disable NSHostingView's default window-resize behavior. Default is
        // `.preferredContentSize` which makes the hosting view push its
        // SwiftUI-preferred size onto the window. Combined with our manual
        // setFrame in StowAnimator/fitToContentHeight, it produces a KVO
        // feedback loop: setFrame -> hosting view sees size drift ->
        // updateAnimatedWindowSize -> NSScrollView.didChangeValueForKey ->
        // _postWindowNeedsLayout -> setFrame -> ... crashes in
        // __NSWindowGetDisplayCycleObserverForLayout_block_invoke.
        // Confirmed by crash reports Flote-2026-04-17-132651.ips and
        // Flote-2026-04-17-155547.ips, both abort() inside display cycle
        // flush. We own the panel's frame exclusively, so tell the hosting
        // view to stay out of it.
        hostingView.sizingOptions = []
        // Also suppress safe-area propagation. During animator().setFrame,
        // NSView emits invalidateSafeAreaInsets KVO on the hosting view,
        // which routes back into SwiftUI's ViewGraphRootValueUpdater and
        // causes setNeedsUpdateConstraints to recurse while the window's
        // layout pass is still running. With no safe-area regions to
        // invalidate, the KVO path short-circuits. macOS 13.3+. Crash
        // Flote-2026-04-17-181410.ips confirmed this second trigger.
        if #available(macOS 13.3, *) {
            hostingView.safeAreaRegions = []
        }
        hostingView.wantsLayer = true
        // Match NoteView's SwiftUI clipShape (cornerRadius: 12, continuous).
        // Using the same radius avoids a visible step at the top edge.
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
        setContentSize(contentRect.size)

        // Allow stow roll (40px) and mini (48px).
        minSize = NSSize(width: 20, height: 28)
    }

    // Required for text editing to work inside a non-activating panel.
    override var canBecomeKey: Bool { true }
    // Floating panel should not become the main window — prevents the app from
    // stealing activation when the panel is clicked. canBecomeKey alone is
    // sufficient for text editing (firstResponder and key window are separate).
    override var canBecomeMain: Bool { false }

    // When focus leaves this panel (user clicks another panel, another app,
    // the desktop, etc.), force any in-progress text editing to commit.
    // Without this, the rolled-title AutoFocusTextField keeps its visual
    // caret and field-editor look because .nonactivatingPanel doesn't fire
    // the field-editor's endEditing automatically on key loss — the user
    // reported this as "Enter を押さないと編集モードが終わらない".
    override func resignKey() {
        super.resignKey()
        // endEditing(for: nil) walks the field-editor chain and asks the
        // active control to commit. For our AutoFocusTextField this ends
        // up calling controlTextDidEndEditing → onFocusLost → commitTitleEdit,
        // so the draft is persisted and isEditingRolledTitle flips false.
        // Harmless when no editing is in progress (no-op).
        endEditing(for: nil)
    }

    // MARK: - Archive-on-close

    /// Archive (close panel, keep note in its group) instead of the system
    /// default "close + discard window". Routed here from ⌘W, the menubar
    /// Close Window command, and the global archive hotkey.
    override func performClose(_ sender: Any?) {
        archiveAndClose()
    }

    /// Public entry used by both `performClose` and the global archive
    /// hotkey. If the panel has no associated note (shouldn't happen in
    /// practice), falls back to a plain window close.
    func archiveAndClose() {
        guard let id = noteID else {
            close()
            return
        }
        NoteManager.shared.archiveNote(id: id)
        PanelManager.shared.removePanel(for: id)
    }

    // MARK: - Content-driven resize

    /// Resize the panel height to fit the given content height, keeping width
    /// at `fixedContentWidth`. The top-left corner stays fixed.
    /// Height is capped at 85% of the screen so the note never extends below
    /// the visible area. When capped, the RichTextEditor's internal scroll
    /// view handles the overflow.
    private var isResizing = false

    func fitToContentHeight(_ contentHeight: CGFloat) {
        guard !isResizing else { return }
        isResizing = true
        defer { isResizing = false }

        let width = FloatingPanel.fixedContentWidth
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let maxHeight = floor(screenHeight * 0.85)
        let height = min(max(contentHeight, 80), maxHeight)

        let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
        let newFrame = NSRect(
            x: topLeft.x,
            y: topLeft.y - height,
            width: width,
            height: height
        )
        setFrame(newFrame, display: false, animate: false)
    }
}
