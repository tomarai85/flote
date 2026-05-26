import SwiftUI
import AppKit

// MARK: - Thin scroller

final class ThinScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat { 6 }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard !knobRect.isEmpty else { return }
        let pill = knobRect.insetBy(dx: 0.5, dy: 1)
        let path = NSBezierPath(roundedRect: pill, xRadius: 2.5, yRadius: 2.5)
        NSColor(red: 0.45, green: 0.40, blue: 0.32, alpha: 0.55).setFill()
        path.fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

// MARK: - Checkbox-aware NSTextView

/// Detects clicks on `[ ]` / `[x]` checkbox patterns and toggles them
/// in-place. All other mouse events pass through to standard NSTextView.
final class FloteTextView: NSTextView {
    var noteID: UUID?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let storage = textStorage, toggleCheckbox(near: index, in: storage) {
            // Let NSTextView's change tracking handle the delegate callback
            // naturally. Calling didChangeText() manually triggers a
            // fitPanelToContent → setFrame chain that crashes during layout.
            if let d = delegate as? RichTextEditor.Coordinator {
                let attrStr = NSAttributedString(attributedString: storage)
                let data = RichTextStorage.archive(attrStr)
                NoteManager.shared.updateRichText(
                    id: d.noteID, data: data, plainText: attrStr.string
                )
            }
            return
        }
        super.mouseDown(with: event)
    }

    // Undo registration for Organize moved to NoteManager.registerOrganizeUndo
    // in Round 2 Sprint A (C2). That path captures only value types (no self
    // reference) and is panel-close safe. The old closure-based helper here
    // was removed to prevent accidental reuse from a stale caller.

    private func toggleCheckbox(near index: Int, in storage: NSTextStorage) -> Bool {
        let text = storage.string as NSString
        let len = text.length
        guard len >= 3 else { return false }
        let safeIndex = min(index, len - 1)
        guard safeIndex >= 0 else { return false }
        let lineRange = text.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = text.substring(with: lineRange)
        let clickOffset = safeIndex - lineRange.location

        for (pattern, replacement) in [("[ ]", "[\u{2713}]"), ("[\u{2713}]", "[ ]"), ("[x]", "[\u{2713}]")] {
            guard let r = line.range(of: pattern) else { continue }
            let patStart = line.distance(from: line.startIndex, to: r.lowerBound)
            let patEnd = patStart + pattern.count
            // Only toggle if click is within or 1 char adjacent to the pattern.
            guard clickOffset >= patStart - 1 && clickOffset <= patEnd else { continue }
            // Wrap in beginEditing/endEditing so NSLayoutManager receives a
            // properly bracketed edit notification. Direct replaceCharacters
            // without this bracket can race with an in-progress layout pass
            // triggered by mouseDown (NSTextView calls ensureLayout before
            // delivering the event).
            storage.beginEditing()
            storage.replaceCharacters(
                in: NSRange(location: lineRange.location + patStart, length: pattern.count),
                with: replacement
            )
            storage.endEditing()
            return true
        }
        return false
    }
}

// Commands that the toolbar sends to the editor.
enum RichTextCommand: Equatable {
    case toggleBold
    case toggleItalic
    case toggleUnderline
    case toggleStrikethrough
    case highlight(NSColor)
    case textColor(NSColor)
    case removeHighlight

    static func == (lhs: RichTextCommand, rhs: RichTextCommand) -> Bool {
        switch (lhs, rhs) {
        case (.toggleBold, .toggleBold): return true
        case (.toggleItalic, .toggleItalic): return true
        case (.toggleUnderline, .toggleUnderline): return true
        case (.toggleStrikethrough, .toggleStrikethrough): return true
        case (.removeHighlight, .removeHighlight): return true
        case (.highlight(let a), .highlight(let b)): return a == b
        case (.textColor(let a), .textColor(let b)): return a == b
        default: return false
        }
    }
}

// Current formatting attributes at the cursor, published for toolbar state.
@Observable
@MainActor
final class RichTextState {
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var hasContentBelow = false
    weak var floteTextView: FloteTextView?
}

struct RichTextEditor: NSViewRepresentable {
    let noteID: UUID
    @Binding var pendingCommand: RichTextCommand?
    let textState: RichTextState
    // Incremented to signal that the editor should reload content from the model.
    var reloadTrigger: Int = 0
    // Passed from parent so SwiftUI tracks font changes and calls updateNSView.
    var fontFamily: AppFont = .hiraginoSans

    func makeCoordinator() -> Coordinator {
        Coordinator(noteID: noteID, textState: textState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FloteTextView()
        textView.noteID = noteID
        textView.autoresizingMask = [.width, .height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let scrollView = NSScrollView()
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textState.floteTextView = textView

        textView.isRichText = true
        textView.allowsUndo = true

        // Respect the user's font preference set in Settings > Appearance.
        let baseFont = FontPreference.shared.current.nsFont(size: 11, weight: .regular)
        textView.font = baseFont
        textView.textColor = NSColor(red: 0.22, green: 0.18, blue: 0.14, alpha: 1.0)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2.5
        textView.defaultParagraphStyle = paragraphStyle

        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false

        // Load existing content
        if let note = NoteManager.shared.note(byID: noteID),
           let data = note.richTextData,
           let attrStr = RichTextStorage.unarchive(data) {
            textView.textStorage?.setAttributedString(attrStr)
            // Existing rich text carries its ORIGINAL font size (often 13pt
            // from earlier builds). User-visible size changes in Settings
            // only affect default input size, not pre-baked attributes, so
            // notes saved before today still render at their old size.
            // Rescale every font span to the current default while keeping
            // family and traits (bold/italic).
            Self.rescaleToDefaultSize(textView)
        } else if let note = NoteManager.shared.note(byID: noteID),
                  !note.text.isEmpty {
            textView.string = note.text
        }

        // Resize panel to fit initial content (deferred until layout is ready).
        let capturedNoteID = noteID
        DispatchQueue.main.async { [weak textView] in
            guard let tv = textView,
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height
            PanelManager.shared.fitPanelToContent(noteID: capturedNoteID, textHeight: h)
        }

        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        let thinScroller = ThinScroller()
        thinScroller.scrollerStyle = .overlay
        scrollView.verticalScroller = thinScroller
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none

        context.coordinator.startObservingScroll(scrollView: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Live-update the body font family when the user changes it in Settings.
        // N1: instead of overwriting the font attribute for the entire range
        // (which destroys per-run bold/italic traits), enumerate existing font
        // spans and swap the family while preserving each span's trait mask.
        if let tv = scrollView.documentView as? NSTextView,
           let storage = tv.textStorage {
            let newFont = fontFamily.nsFont(size: 11, weight: .regular)
            if let newFamilyName = newFont.familyName,
               tv.font?.familyName != newFamilyName {
                tv.font = newFont
                // Swap family on each existing font span, keeping size + traits.
                let fullRange = NSRange(location: 0, length: storage.length)
                let fm = NSFontManager.shared
                storage.beginEditing()
                storage.enumerateAttribute(.font, in: fullRange, options: []) { value, subRange, _ in
                    let existing = (value as? NSFont) ?? NSFont.systemFont(ofSize: 11)
                    // `convert(_:toFamily:)` keeps the same point size and applies
                    // the closest available variant (bold, italic, bold-italic…).
                    let swapped = fm.convert(existing, toFamily: newFamilyName)
                    storage.addAttribute(.font, value: swapped, range: subRange)
                }
                storage.endEditing()
            }
        }

        if let command = pendingCommand {
            context.coordinator.apply(command: command)
            DispatchQueue.main.async { self.pendingCommand = nil }
        }

        // Reload content when reloadTrigger changes (e.g. after organize).
        if reloadTrigger != context.coordinator.lastReloadTrigger {
            context.coordinator.lastReloadTrigger = reloadTrigger
            if let tv = scrollView.documentView as? NSTextView,
               let note = NoteManager.shared.note(byID: noteID) {
                // If IME is composing (e.g. Japanese input in progress),
                // skip the replacement this tick — it would destroy the
                // marked-text range and corrupt the composition.
                if tv.hasMarkedText() {
                    context.coordinator.lastReloadTrigger = reloadTrigger - 1
                    return
                }
                // Clear the undo manager before replacing content to prevent
                // ⌘Z from crashing with stale undo state.
                tv.undoManager?.removeAllActions()
                // Use beginEditing/endEditing for atomic storage updates.
                // This batches all attribute changes into a single layout pass,
                // which is especially important for large documents (M6).
                if let storage = tv.textStorage {
                    storage.beginEditing()
                    if let data = note.richTextData,
                       let attrStr = RichTextStorage.unarchive(data) {
                        storage.setAttributedString(attrStr)
                    } else {
                        storage.setAttributedString(NSAttributedString(string: note.text))
                    }
                    storage.endEditing()
                }
                // Same rescale as makeNSView's initial load path: ensure
                // reloaded content honors the current default point size
                // instead of whatever size the attributes were stored at.
                Self.rescaleToDefaultSize(tv)
                // Resize to fit the newly-loaded content, and THEN force
                // typingAttributes. Setting typingAttributes before the layout
                // pass is futile — NSTextView resets them during layout to
                // match the attributes at the insertion point.
                let capturedNoteID = noteID
                DispatchQueue.main.async { [weak tv] in
                    guard let tv = tv,
                          let lm = tv.layoutManager,
                          let tc = tv.textContainer else { return }
                    lm.ensureLayout(for: tc)
                    let h = lm.usedRect(for: tc).height
                    PanelManager.shared.fitPanelToContent(noteID: capturedNoteID, textHeight: h)

                    let userFont = FontPreference.shared.current.nsFont(size: 11, weight: .regular)
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.lineSpacing = 2.5
                    tv.typingAttributes = [
                        .font: userFont,
                        .foregroundColor: NSColor(red: 0.22, green: 0.18, blue: 0.14, alpha: 1.0),
                        .paragraphStyle: paraStyle
                    ]

                    // Brief scroll indicator flash after content reload so the
                    // user knows there's more content below.
                    if let sv = tv.enclosingScrollView, h > sv.frame.height {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            sv.flashScrollers()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Font size migration

    /// Rescale every font span in the text view's storage to the current
    /// default point size while preserving the family and traits (bold /
    /// italic). Rich text stored before a font-size change still carries
    /// the old size baked into its attributes; without this rescale, the
    /// user would have to re-run Organize on every note to see the new
    /// size. Called from makeNSView (initial load) and updateNSView
    /// (reloadTrigger bump after Organize).
    @MainActor
    static func rescaleToDefaultSize(_ tv: NSTextView) {
        guard let storage = tv.textStorage, storage.length > 0 else { return }
        let targetSize = FontPreference.shared.current
            .nsFont(size: 11, weight: .regular).pointSize
        let fm = NSFontManager.shared
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let existing = value as? NSFont else { return }
            if abs(existing.pointSize - targetSize) < 0.1 { return }
            // convert(toSize:) preserves family + traits (bold, italic).
            let resized = fm.convert(existing, toSize: targetSize)
            storage.addAttribute(.font, value: resized, range: range)
        }
        storage.endEditing()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let noteID: UUID
        let textState: RichTextState
        weak var textView: NSTextView?
        var lastReloadTrigger: Int = 0
        // nonisolated(unsafe) lets deinit (which is implicitly nonisolated)
        // access this property without a Swift 6 concurrency error. The token
        // is only read in deinit for removal, never concurrently mutated.
        nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

        init(noteID: UUID, textState: RichTextState) {
            self.noteID = noteID
            self.textState = textState
        }

        deinit {
            if let obs = scrollObserver {
                NotificationCenter.default.removeObserver(obs)
                scrollObserver = nil
            }
        }

        func startObservingScroll(scrollView: NSScrollView) {
            guard scrollObserver == nil else { return }
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let sv = scrollView else { return }
                self.updateOverflowIndicator(sv)
            }
            updateOverflowIndicator(scrollView)
        }

        func updateOverflowIndicator(_ scrollView: NSScrollView) {
            let contentHeight = scrollView.documentView?.frame.height ?? 0
            let visibleHeight = scrollView.contentView.bounds.height
            let scrollY = scrollView.contentView.bounds.origin.y
            let bottomGap = contentHeight - visibleHeight - scrollY
            textState.hasContentBelow = bottomGap > 4
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView,
                  let storage = tv.textStorage else { return }
            let attrStr = NSAttributedString(attributedString: storage)
            let data = RichTextStorage.archive(attrStr)
            let plainText = attrStr.string
            NoteManager.shared.updateRichText(id: noteID, data: data, plainText: plainText)
            notifyContentSizeChanged(tv)
            // Keep the rolled-up title in sync with live edits — but ONLY when
            // the body still carries a `## タイトル` section. Clearing the title
            // on every edit would wipe user-set titles (set via right-click on
            // the rolled scroll) or titles inherited from a prior Organize run.
            if let title = Self.extractTitle(from: plainText) {
                NoteManager.shared.updateRolledTitle(id: noteID, title: title)
            }
        }

        private static func extractTitle(from text: String) -> String? {
            let lines = text.components(separatedBy: "\n")
            var seenHeader = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if seenHeader {
                    if trimmed.isEmpty { continue }
                    if trimmed.hasPrefix("##") { return nil }
                    return trimmed
                        .trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
                }
                if trimmed.hasPrefix("## タイトル") || trimmed.hasPrefix("# タイトル") {
                    seenHeader = true
                }
            }
            return nil
        }

        /// Tell the panel to resize based on text content height.
        private var pendingResize: DispatchWorkItem?

        private func notifyContentSizeChanged(_ tv: NSTextView) {
            pendingResize?.cancel()
            let id = noteID
            // Snapshot length on the current thread before the async hop so
            // we don't capture tv strongly in the closure.
            let textLength = tv.textStorage?.length ?? 0
            let work = DispatchWorkItem { [weak tv] in
                guard let tv, let lm = tv.layoutManager,
                      let tc = tv.textContainer else { return }
                // For large documents, only lay out the first 2000 characters
                // so the UI thread isn't blocked by a full O(n) layout pass on
                // every keystroke. The panel height converges quickly because
                // the first 2000 chars already fill the visible area.
                if textLength > 5000 {
                    lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(2000, textLength)))
                } else {
                    lm.ensureLayout(for: tc)
                }
                let h = lm.usedRect(for: tc).height
                PanelManager.shared.fitPanelToContent(noteID: id, textHeight: h)
            }
            pendingResize = work
            // Coalesce rapid-fire keystrokes into ~60Hz resize ticks. With
            // plain `.async`, every character kicks a full ensureLayout +
            // setFrame cycle which stalls the UI thread on large notes.
            // 16ms delay lets the same run-loop pass dedupe multiple calls
            // via `work.cancel()` above.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            updateTextState(from: tv)
        }

        private func updateTextState(from tv: NSTextView) {
            let attrs: [NSAttributedString.Key: Any]
            if tv.selectedRange().length > 0,
               let storage = tv.textStorage {
                attrs = storage.attributes(at: tv.selectedRange().location, effectiveRange: nil)
            } else {
                attrs = tv.typingAttributes
            }

            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            let traits = NSFontManager.shared.traits(of: font)

            textState.isBold = traits.contains(.boldFontMask)
            textState.isItalic = traits.contains(.italicFontMask)
            textState.isUnderline = (attrs[.underlineStyle] as? Int) != nil && (attrs[.underlineStyle] as? Int) != 0
            textState.isStrikethrough = (attrs[.strikethroughStyle] as? Int) != nil && (attrs[.strikethroughStyle] as? Int) != 0
        }

        func apply(command: RichTextCommand) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()

            // When no text is selected, modify typingAttributes for future input.
            if range.length == 0 {
                applyToTypingAttributes(command: command, textView: tv)
                updateTextState(from: tv)
                return
            }

            switch command {
            case .toggleBold:
                applyFontTrait(.boldFontMask, in: range, storage: storage)

            case .toggleItalic:
                applyFontTrait(.italicFontMask, in: range, storage: storage)

            case .toggleUnderline:
                toggleAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue as AnyObject, in: range, storage: storage)

            case .toggleStrikethrough:
                toggleAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue as AnyObject, in: range, storage: storage)

            case .highlight(let color):
                storage.addAttribute(.backgroundColor, value: color, range: range)

            case .removeHighlight:
                storage.removeAttribute(.backgroundColor, range: range)

            case .textColor(let color):
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }

            // Persist after applying formatting
            let attrStr = NSAttributedString(attributedString: storage)
            let data = RichTextStorage.archive(attrStr)
            let plainText = attrStr.string
            NoteManager.shared.updateRichText(id: noteID, data: data, plainText: plainText)

            updateTextState(from: tv)
        }

        private func applyToTypingAttributes(command: RichTextCommand, textView tv: NSTextView) {
            var attrs = tv.typingAttributes
            let fm = NSFontManager.shared

            switch command {
            case .toggleBold:
                let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
                let traits = fm.traits(of: font)
                if traits.contains(.boldFontMask) {
                    attrs[.font] = fm.convert(font, toNotHaveTrait: .boldFontMask)
                } else {
                    attrs[.font] = fm.convert(font, toHaveTrait: .boldFontMask)
                }

            case .toggleItalic:
                let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
                let traits = fm.traits(of: font)
                if traits.contains(.italicFontMask) {
                    attrs[.font] = fm.convert(font, toNotHaveTrait: .italicFontMask)
                } else {
                    attrs[.font] = fm.convert(font, toHaveTrait: .italicFontMask)
                }

            case .toggleUnderline:
                if let current = attrs[.underlineStyle] as? Int, current != 0 {
                    attrs.removeValue(forKey: .underlineStyle)
                } else {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }

            case .toggleStrikethrough:
                if let current = attrs[.strikethroughStyle] as? Int, current != 0 {
                    attrs.removeValue(forKey: .strikethroughStyle)
                } else {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }

            case .highlight(let color):
                attrs[.backgroundColor] = color

            case .removeHighlight:
                attrs.removeValue(forKey: .backgroundColor)

            case .textColor(let color):
                attrs[.foregroundColor] = color
            }

            tv.typingAttributes = attrs
        }

        // Toggle font traits (bold, italic) across the selected range.
        private func applyFontTrait(_ trait: NSFontTraitMask, in range: NSRange, storage: NSTextStorage) {
            let fm = NSFontManager.shared

            // Check if the entire range already has this trait.
            var allHave = true
            storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                let traits = fm.traits(of: font)
                if !traits.contains(trait) {
                    allHave = false
                    stop.pointee = true
                }
            }

            storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                let baseFont = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                let newFont: NSFont
                if allHave {
                    newFont = fm.convert(baseFont, toNotHaveTrait: trait)
                } else {
                    newFont = fm.convert(baseFont, toHaveTrait: trait)
                }
                storage.addAttribute(.font, value: newFont, range: subRange)
            }
        }

        // Toggle integer-valued attributes (underline, strikethrough).
        private func toggleAttribute(_ key: NSAttributedString.Key, value: AnyObject, in range: NSRange, storage: NSTextStorage) {
            var allHave = true
            storage.enumerateAttribute(key, in: range, options: []) { existing, _, stop in
                if existing == nil || (existing as? Int) == 0 {
                    allHave = false
                    stop.pointee = true
                }
            }
            if allHave {
                storage.removeAttribute(key, range: range)
            } else {
                storage.addAttribute(key, value: value, range: range)
            }
        }

    }
}
