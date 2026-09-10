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

// MARK: - S16 deck root (one window, many notes)

/// Drives which deck member a panel's SwiftUI root renders. PanelManager
/// swaps notes by mutating `shownNoteID` — content-only; the window (its
/// frame, radius, hosting view, vibrancy) is never touched, so every
/// 2026-04-17 crash invariant (no frame animation, sizingOptions [],
/// safeAreaRegions []) holds through a switch.
final class DeckDisplayModel: ObservableObject {
    /// The deck member this panel currently renders.
    @Published var shownNoteID: UUID
    /// Slide direction of the LAST switch (+1 next / -1 previous / 0 =
    /// Reduce Motion, no slide). Deliberately NOT @Published: it must not
    /// trigger its own render — it's read while the shownNoteID change
    /// renders, and both the outgoing and incoming transitions use it.
    var direction: Int = 0

    init(shownNoteID: UUID) { self.shownNoteID = shownNoteID }
}

/// Root content of every FloatingPanel: the shown note, identity-keyed so
/// a deck switch tears down the old NoteView (its onDisappear runs —
/// ClipboardCollector stops, timers keep ticking; both by design) and
/// mounts a fresh one. The transition is opacity + an ≤8pt offset —
/// SwiftUI content animation inside the panel is safe; the window is not
/// part of it.
private struct DeckRootView: View {
    @ObservedObject var model: DeckDisplayModel

    var body: some View {
        let slide = CGFloat(model.direction) * 8
        ZStack {
            NoteView(noteID: model.shownNoteID)
                .id(model.shownNoteID)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: slide)),
                    removal: .opacity.combined(with: .offset(x: -slide))
                ))
        }
    }
}

final class FloatingPanel: NSPanel {

    /// App-level size SUGGESTIONS (Tom 2026-07-11: 小=今の大きさ/中/大).
    /// The preset is the DEFAULT geometry — new notes start here and
    /// non-user-resized panels follow it. A note the user drag-resized
    /// (userResized) owns its geometry and ignores presets entirely.
    enum SizePreset: String, CaseIterable {
        case small, medium, large

        static let defaultsKey = "floteNoteSizePreset"
        /// Pre-2026-07-11 width-only preset key, migrated on first read.
        static let legacyWidthKey = "floteNoteWidth"

        var size: CGSize {
            switch self {
            case .small:  return CGSize(width: 160, height: 120)  // the original footprint
            case .medium: return CGSize(width: 240, height: 200)
            case .large:  return CGSize(width: 320, height: 280)
            }
        }

        @MainActor
        var title: String {
            switch self {
            case .small:  return L("小（元のサイズ）", "Small (original)")
            case .medium: return L("中", "Medium")
            case .large:  return L("大", "Large")
            }
        }

        static var current: SizePreset {
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let preset = SizePreset(rawValue: raw) {
                return preset
            }
            // Migrate the retired width-only preset once.
            switch UserDefaults.standard.string(forKey: legacyWidthKey) {
            case "standard": return .medium
            case "wide":     return .large
            default:         return .small
            }
        }
    }

    /// Floor for USER drag-resizing (Tom 2026-07-11 screenshots: below
    /// this the top-bar buttons clip and the Organize pill truncates).
    /// Programmatic geometry (44x76 stow string, 48pt mini) is exempt —
    /// the clamp lives in windowWillResize and only fires for live drags.
    static let userMinSize = NSSize(width: 140, height: 90)

    /// Default width for panels that the user hasn't drag-resized.
    /// Open panels are re-fit by PanelManager.applySizePreset on change.
    static var fixedContentWidth: CGFloat { SizePreset.current.size.width }
    /// Legacy alias (kept for existing call sites).
    static var maxContentWidth: CGFloat { fixedContentWidth }

    /// The note this panel is SHOWING. Set at init and re-targeted by
    /// PanelManager.deckSwitch so native close actions (⌘W, menubar
    /// Close, etc.) and the move/resize observers always act on the
    /// visible deck member.
    var noteID: UUID?

    /// S16: the deck display model behind this panel's SwiftUI root.
    /// PanelManager mutates it to switch notes (content swap only).
    let deckModel: DeckDisplayModel

    init(contentRect: NSRect, noteID: UUID) {
        self.deckModel = DeckDisplayModel(shownNoteID: noteID)
        super.init(
            contentRect: contentRect,
            styleMask: [
                .nonactivatingPanel,
                .fullSizeContentView,
                // Free resize (Tom 2026-07-11): borderless windows grow
                // edge-drag handles with .resizable. User drags are detected
                // via inLiveResize in PanelManager's didResize observer and
                // flip the note to userResized (self-owned geometry).
                .resizable
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
        // S3: behind-window vibrancy needs non-opaque compositing, and the
        // user-facing 透明度 slider drives whole-panel alpha.
        isOpaque = false
        alphaValue = CGFloat(AppearanceSettings.shared.panelOpacity)

        self.noteID = noteID

        let hostingView = FirstClickHostingView(rootView:
            DeckRootView(model: deckModel)
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
        // Match NoteView's SwiftUI clipShape (same app-level constant).
        // Using the same radius avoids a visible step at the top edge.
        hostingView.layer?.cornerRadius = AppearanceSettings.shared.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        hostingView.autoresizingMask = [.width, .height]

        // S3 frosted float: a behind-window NSVisualEffectView sits under the
        // SwiftUI content; NoteView's tint is translucent so the desktop
        // frost shows through. The effect view carries the SAME constant
        // corner 12 (crash invariant: radius never varies, never animates).
        // PanelManager.reloadTextView still finds FloteTextView — it recurses
        // contentView.subviews, and hostingView is a subview of the wrapper.
        let effectView = NSVisualEffectView()
        // .popover is a LIGHT frost; .hudWindow (first attempt) is a DARK
        // HUD material that swallowed the pastel tint (Tom rejected it).
        // Appearance pinned to aqua: notes are paper and stay light even
        // when the system is in dark mode.
        effectView.material = .popover
        effectView.appearance = NSAppearance(named: .aqua)
        effectView.blendingMode = .behindWindow
        // .active always: the note must stay frosted when it loses key
        // (nonactivating panels lose key constantly by design).
        effectView.state = AppearanceSettings.shared.useVibrancy ? .active : .inactive
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = AppearanceSettings.shared.cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: contentRect.size)
        effectView.frame = hostingView.frame
        // 2026-07-11 restructure (Tom: the string's "pill" was ugly): frost
        // and SwiftUI content are SIBLINGS under a clear container, so
        // applyChrome can hide the frost ALONE and the rolled-up string
        // renders with no background at all. (The old nesting meant hiding
        // the frost hid the string too — the documented maskImage dead end.)
        let container = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        container.wantsLayer = true
        container.addSubview(effectView)
        container.addSubview(hostingView, positioned: .above, relativeTo: effectView)
        self.vibrancyView = effectView
        contentView = container
        setContentSize(contentRect.size)

        // Live-apply 透明度 / すりガラス changes from Settings.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .floteAppearanceChanged, object: nil, queue: .main
        ) { [weak self] note in
            self?.applyTranslucencySettings()
            // S7-3 角丸: applied ONLY on the explicit Settings change and
            // ONLY while this panel is not mid-animation (StowAnimator owns
            // frames during a flight; a radius change there is the crash
            // recipe). Panels mid-flight pick the value up on next apply.
            if (note.userInfo?["key"] as? String) == "cornerRadius" {
                self?.applyCornerRadiusIfSafe()
            }
        }
        // Accessibility: システム設定 > 透明度を下げる. Live-react — the
        // user should never have to relaunch to get solid notes.
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyTranslucencySettings()
        }
        applyTranslucencySettings()

        // Allow stow roll (40px) and mini (48px).
        minSize = NSSize(width: 20, height: 28)

        // ARC discipline: the default (true) makes any close() over-release
        // the panel. PanelManager owns lifetime; close must never dealloc.
        isReleasedWhenClosed = false

        // Free-resize bounds: self-delegation for windowWillResize (no other
        // component claims the panel delegate).
        delegate = self

        // Forensics (2026-07-11 vanish bug): if ANYTHING closes this panel,
        // log who did it — Tom's roll-up press kills the window with no
        // model update, and only his interactive flow triggers it.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: self, queue: .main
        ) { [weak self] _ in
            NSLog("[Flote] PANEL WILL CLOSE noteID=%@\n%@",
                  self?.noteID?.uuidString ?? "?",
                  Thread.callStackSymbols.joined(separator: "\n"))
        }
    }
    private var closeObserver: NSObjectProtocol?

    /// S7-3: push the app-level radius into both AppKit layers, skipping
    /// panels whose frames are currently owned by StowAnimator.
    func applyCornerRadiusIfSafe() {
        guard let id = noteID, !PanelManager.shared.isAnimating(noteID: id) else { return }
        let r = AppearanceSettings.shared.cornerRadius
        // Since the container/siblings restructure, frost AND hostingView
        // both clip content — a Settings radius change must hit every
        // sibling or they visibly disagree until relaunch (eval-regression
        // finding 4).
        contentView?.layer?.cornerRadius = r
        contentView?.subviews.forEach { $0.layer?.cornerRadius = r }
    }

    /// Balloon-string chrome: while stowed as a string, the window frost
    /// and shadow would draw a ghost box around the transparent SwiftUI
    /// string — hide both. Every other state restores the normal chrome.
    func applyChrome(for state: StowState) {
        let isString = state == .rolledUp
        isStringChrome = isString
        hasShadow = !isString
        if isString {
            // Siblings since 2026-07-11: the frost vanishes outright — the
            // string hangs bare (no pill). Full window alpha so the cord
            // never inherits the opacity slider's translucency.
            vibrancyView?.isHidden = true
            vibrancyView?.state = .inactive
            alphaValue = 1.0
        } else {
            vibrancyView?.isHidden = false
            applyTranslucencySettings()
        }
        invalidateShadow()
    }

    /// True while dressed as a balloon string (applyChrome). Appearance
    /// changes must not re-frost the bare string (Evaluator r3 #5).
    private var isStringChrome = false

    /// Reduce Transparency wins over BOTH user knobs: the frost goes
    /// inactive (solid designed fallback, same as すりガラス off) and the
    /// panel is forced fully opaque regardless of the opacity slider.
    private func applyTranslucencySettings() {
        guard !isStringChrome else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        alphaValue = reduce ? 1.0 : CGFloat(AppearanceSettings.shared.panelOpacity)
        vibrancyView?.state =
            (!reduce && AppearanceSettings.shared.useVibrancy) ? .active : .inactive
    }

    /// S3: the frost layer under the SwiftUI content (nil before init done).
    private weak var vibrancyView: NSVisualEffectView?
    private var appearanceObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    deinit {
        if let obs = appearanceObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    override func orderOut(_ sender: Any?) {
        NSLog("[Flote] panel orderOut noteID=%@", noteID?.uuidString ?? "?")
        super.orderOut(sender)
    }

    override func orderFrontRegardless() {
        NSLog("[Flote] panel orderFrontRegardless noteID=%@", noteID?.uuidString ?? "?")
        super.orderFrontRegardless()
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

    // MARK: - S16 deck input (panel-local, window level)
    //
    // ⌘] / ⌘[ / ⌘T / ⌘1 / ⌘W / ⌘⇧W / ⌘⌥W / ⌘⇧] / ⌘⇧[ and the two-finger
    // horizontal swipe are DECK gestures owned by the window: intercepted
    // in sendEvent BEFORE the view hierarchy, so the editor never sees
    // them. No conflicts by audit: FloteTextView binds only ⌘B/I/U, ⌘⇧V,
    // ⌘⏎ and ⌘+/=/−/0 — no brackets, no T, no 1, no W in any modifier
    // set, no scrollWheel; the app has no Format menu to claim ⌘T.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if handleDeckKey(event) { return }
        case .scrollWheel:
            if handleDeckSwipe(event) { return }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// The shown note IFF deck gestures apply right now: panel expanded
    /// (the string/mini faces have no deck UI), not mid-animation, and —
    /// for key gestures — not mid-IME-composition (the keyboard belongs
    /// to the input method then).
    private func deckGestureNoteID(requireKeyboardIdle: Bool = false) -> UUID? {
        guard let id = noteID,
              !PanelManager.shared.isAnimating(noteID: id),
              NoteManager.shared.note(byID: id)?.stowState == .expanded
        else { return nil }
        if requireKeyboardIdle,
           PanelManager.shared.textViewIfComposing(noteID: id) != nil {
            return nil
        }
        return id
    }

    /// ⌘] next / ⌘[ previous (wrap) / ⌘1 jump to front / ⌘T new blank
    /// note in THIS deck. Tab command set (2026-07-12, keyboard-first per
    /// product owner): ⌘W close tab / ⌘⇧W close other tabs / ⌘⌥W detach
    /// to own sticky / ⌘⇧] ⌘⇧[ move tab right/left. Deck-only keys pass
    /// through untouched on a solo note; ⌘T always works (it is what
    /// CREATES the deck) and ⌘W always works (deck of 1 = archive + close
    /// panel, the old single-note behavior).
    private func handleDeckKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cheap modifier pre-filter FIRST: deckGestureNoteID walks the view
        // hierarchy (IME probe), which must never run on plain typing.
        guard mods == .command
                || mods == [.command, .shift]
                || mods == [.command, .option],
              let chars = event.charactersIgnoringModifiers,
              let id = deckGestureNoteID(requireKeyboardIdle: true)
        else { return false }
        let inDeck = NoteManager.shared.deckMemberIDs(with: id).count >= 2

        if mods == .command {
            switch chars {
            case "]":
                guard inDeck else { return false }
                PanelManager.shared.deckNavigate(from: id, move: .next)
                return true
            case "[":
                guard inDeck else { return false }
                PanelManager.shared.deckNavigate(from: id, move: .previous)
                return true
            case "1":
                guard inDeck else { return false }
                PanelManager.shared.deckNavigate(from: id, move: .first)
                return true
            case "t":
                PanelManager.shared.deckNewNote(from: id)
                return true
            case "w":
                // Deterministic at the window: this accessory app has no
                // guaranteed File▸Close menu item to route ⌘W through, and
                // the deck's close must not depend on one. Same tail as
                // performClose/archiveAndClose; falls through (stowed /
                // mid-IME) to the legacy path unchanged.
                PanelManager.shared.closeShownNote(noteID: id, archive: true)
                return true
            default:
                return false
            }
        }

        if mods == [.command, .shift] {
            // charactersIgnoringModifiers keeps Shift applied: on ANSI/JIS
            // the bracket keys arrive as "}"/"{" and W as "W" — accept the
            // unshifted twins too for layouts that don't shift them.
            switch chars {
            case "]", "}":
                guard inDeck else { return false }
                PanelManager.shared.deckMoveShown(id, offset: +1)
                return true
            case "[", "{":
                guard inDeck else { return false }
                PanelManager.shared.deckMoveShown(id, offset: -1)
                return true
            case "w", "W":
                guard inDeck else { return false }
                PanelManager.shared.deckCloseOthers(keeping: id, shownID: id)
                return true
            default:
                return false
            }
        }

        if mods == [.command, .option] {
            // Option is ignored by charactersIgnoringModifiers, so ⌘⌥W
            // arrives as plain "w".
            if chars.lowercased() == "w" {
                guard inDeck else { return false }
                PanelManager.shared.deckDetach(id, shownID: id)
                return true
            }
            return false
        }

        return false
    }

    // Two-finger horizontal swipe = deck navigation (Antinote's trackpad
    // gesture). deltaX-dominance is decided ONCE at gesture start; a
    // vertical scroll passes through to the editor untouched. One
    // navigation per gesture, and a consumed gesture's momentum tail is
    // swallowed so the editor never receives half a gesture.
    private var swipeTracking = false
    private var swipeTriggered = false
    private var swipeAccumX: CGFloat = 0
    private var swipeSwallowMomentum = false

    private func handleDeckSwipe(_ event: NSEvent) -> Bool {
        let phase = event.phase
        let momentum = event.momentumPhase

        if phase == .began {
            swipeSwallowMomentum = false
            swipeTracking = false
            swipeTriggered = false
            swipeAccumX = 0
            guard let id = deckGestureNoteID(),
                  NoteManager.shared.deckMemberIDs(with: id).count >= 2,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            else { return false }
            swipeTracking = true
            swipeAccumX = event.scrollingDeltaX
            return true
        }
        if swipeTracking {
            if phase == .changed {
                swipeAccumX += event.scrollingDeltaX
                if !swipeTriggered, abs(swipeAccumX) >= 50,
                   let id = deckGestureNoteID() {
                    swipeTriggered = true
                    // Natural scrolling: fingers moving left (negative
                    // deltaX) pull the NEXT note in — turning a page.
                    PanelManager.shared.deckNavigate(
                        from: id, move: swipeAccumX < 0 ? .next : .previous)
                }
                return true
            }
            if phase == .ended || phase == .cancelled {
                swipeTracking = false
                swipeSwallowMomentum = true
                return true
            }
            return true // unexpected phase mid-gesture: keep consuming
        }
        if swipeSwallowMomentum, momentum != [] {
            if momentum == .ended || momentum == .cancelled {
                swipeSwallowMomentum = false
            }
            return true
        }
        return false
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
    /// S16 deck-aware: archives the SHOWN note; a deck panel advances to
    /// the next member instead of closing (deck of 1 = old behavior).
    func archiveAndClose() {
        guard let id = noteID else {
            close()
            return
        }
        PanelManager.shared.closeShownNote(noteID: id, archive: true)
    }

    // MARK: - Content-driven resize

    /// Resize the panel height to fit the given content height, keeping the
    /// panel's CURRENT width (preset-driven or user-dragged). The top-left
    /// corner stays fixed. Height is capped at 85% of the screen so the note
    /// never extends below the visible area. When capped, the
    /// RichTextEditor's internal scroll view handles the overflow.
    /// PanelManager gates the call: user-resized notes are never auto-fit.
    private var isResizing = false

    func fitToContentHeight(_ contentHeight: CGFloat) {
        guard !isResizing else { return }
        isResizing = true
        defer { isResizing = false }

        // Never fight an in-flight user drag.
        guard !inLiveResize else { return }
        let width = frame.width
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let maxHeight = floor(screenHeight * 0.85)
        // 小 keeps the historical 80pt floor (小 = "今の大きさ", unchanged
        // behavior); 中/大 hold their preset height so they stay airy.
        let preset = FloatingPanel.SizePreset.current
        let minHeight = min(preset == .small ? 80 : preset.size.height, maxHeight)
        let height = min(max(contentHeight, minHeight), maxHeight)

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

// MARK: - Free-resize bounds (Tom 2026-07-11: min/max must exist)

extension FloatingPanel: NSWindowDelegate {
    /// Clamp USER drags to sane bounds: floor = every top-bar control
    /// visible (140x90); ceiling = 60% of screen width, 85% height.
    /// Programmatic geometry (stow string 44x76, mini 48pt, fit) passes
    /// through untouched — the clamp fires only during a live drag.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender.inLiveResize else { return frameSize }
        let vf = (sender.screen ?? NSScreen.main)?.visibleFrame
        let maxW = min(CGFloat(640), vf.map { floor($0.width * 0.6) } ?? 640)
        let maxH = vf.map { floor($0.height * 0.85) } ?? 900
        return NSSize(
            width: min(max(frameSize.width, Self.userMinSize.width), maxW),
            height: min(max(frameSize.height, Self.userMinSize.height), maxH)
        )
    }
}
