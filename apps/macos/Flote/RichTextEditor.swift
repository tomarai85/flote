import SwiftUI
import AppKit
import Vision

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

// MARK: - Checkbox-rendering layout manager

/// Renders `[ ]` / `[✓]` checkbox tokens as Things-style circular checkboxes
/// at DISPLAY time only. The backing NSTextStorage always keeps the literal
/// `[ ]` / `[✓]` characters, so persistence (RichTextStorage archives), the
/// plain-text mirror (note.text), Organize output, and export are untouched.
/// This class never mutates storage:
/// - Token glyphs are hidden with a TEMPORARY `.foregroundColor: .clear`
///   attribute. NSLayoutManager temporary attributes live in the layout
///   manager, outside the attributed string — they can never appear in
///   `NSAttributedString(attributedString: storage)` and therefore never
///   reach `RichTextStorage.archive` or the undo stack.
/// - The circle + checkmark are vector-drawn OVER the hidden token's rect in
///   `drawGlyphs(forGlyphRange:at:)`.
/// - Lines whose first checkbox is `[✓]` get strikethrough + faded ink,
///   also as temporary attributes only.
/// Legacy `[x]` tokens are intentionally left as literal text: the existing
/// click handler converts them to `[✓]` (checked) on tap, so rendering them
/// as an already-checked circle would make that tap look like a no-op.
final class FloteLayoutManager: NSLayoutManager {

    private static let uncheckedToken = "[ ]"
    private static let checkedToken = "[\u{2713}]"
    private static let tokenLength = 3

    // MARK: Appearance redraw (S3c paper rules)

    override init() {
        super.init()
        startObservingAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        startObservingAppearance()
    }

    /// 罫線/方眼 are drawn in `drawBackground` below from live
    /// AppearanceSettings values; a Settings change must invalidate the
    /// text view display or the old ruling stays until the next keystroke.
    /// Selector-based observer: auto-unregistered on dealloc, no token to
    /// manage in deinit.
    private func startObservingAppearance() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceDidChange(_:)),
            name: .floteAppearanceChanged,
            object: nil
        )
    }

    @objc private func appearanceDidChange(_ note: Notification) {
        guard let key = note.userInfo?["key"] as? String,
              key == "paperType" || key == "paperStrength" || key == "appTheme" else { return }
        // AppearanceSettings posts from @MainActor mutations, so this always
        // arrives on the main thread.
        MainActor.assumeIsolated {
            if key == "appTheme", let storage = textStorage {
                // Done-line ink is BAKED into temporary attributes — a theme
                // switch must restyle, not just redraw.
                refreshCheckboxStyling(around: NSRange(location: 0, length: storage.length))
            }
            firstTextView?.needsDisplay = true
        }
    }

    // MARK: Theme ink (Evaluator #2)

    /// Text ink for THIS layout manager's note: app-wide theme wins, else
    /// the note's own legacy hue — mirrors NoteView.themePalette
    /// (light-pinned: notes are paper).
    @MainActor
    private func themeInk(alpha: Double = 1.0) -> NSColor {
        FloteInk.text(
            legacyTheme: (firstTextView as? FloteTextView)?.legacyThemeRaw,
            alpha: alpha)
    }

    /// Checkbox fill accent for this note's theme (per-entry 3:1 contrast).
    @MainActor
    private func themeAccent() -> NSColor {
        FloteInk.accent(legacyTheme: (firstTextView as? FloteTextView)?.legacyThemeRaw)
    }

    // MARK: Token scanning

    /// All checkbox tokens inside `range` of `text`, in document order.
    static func checkboxTokens(
        in text: NSString, range: NSRange
    ) -> [(range: NSRange, checked: Bool)] {
        guard range.length >= tokenLength else { return [] }
        var found: [(range: NSRange, checked: Bool)] = []
        for (token, checked) in [(uncheckedToken, false), (checkedToken, true)] {
            var search = range
            while search.length >= tokenLength {
                let hit = text.range(of: token, options: [], range: search)
                if hit.location == NSNotFound { break }
                found.append((range: hit, checked: checked))
                let next = NSMaxRange(hit)
                search = NSRange(location: next, length: NSMaxRange(range) - next)
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    // MARK: Edit tracking → temporary-attribute styling

    override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorageEditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        super.processEditing(
            for: textStorage, edited: editMask, range: newCharRange,
            changeInLength: delta, invalidatedRange: invalidatedCharRange
        )
        // Only character edits can create/destroy/move tokens. Attribute-only
        // edits (bold, rescaleToDefaultSize, font-family swap) change nothing
        // here — temporary attribute ranges track storage edits automatically,
        // the same way spell-check underlines stay glued to their word.
        // Restyling here (not in drawGlyphs) avoids the
        // addTemporaryAttribute → invalidateDisplay → redraw feedback loop.
        guard editMask.contains(.editedCharacters) else { return }
        refreshCheckboxStyling(around: newCharRange)
    }

    private func refreshCheckboxStyling(around charRange: NSRange) {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        // Clamp defensively, then widen to whole paragraphs so a partial edit
        // restyles every token/line it could have affected.
        var safe = charRange
        if safe.location == NSNotFound || safe.location > text.length {
            safe = NSRange(location: text.length, length: 0)
        }
        if NSMaxRange(safe) > text.length {
            safe.length = text.length - safe.location
        }
        let paragraphs = text.paragraphRange(for: safe)

        // Reset ONLY the attributes this class manages, scoped to the edited
        // paragraphs. Other temporary attributes (e.g. spell-check underline
        // via .underlineStyle/.spellingState) are untouched.
        removeTemporaryAttribute(.foregroundColor, forCharacterRange: paragraphs)
        removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: paragraphs)

        // Restyling runs on the main thread (text edits / the appearance
        // observer); assumeIsolated bridges to the @MainActor theme.
        let doneInk = MainActor.assumeIsolated { themeInk(alpha: 0.55) }
        let marked = currentMarkedRange()
        text.enumerateSubstrings(
            in: paragraphs, options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let tokens = Self.checkboxTokens(in: text, range: lineRange)
            guard !tokens.isEmpty else { return }
            // Done-line styling: strikethrough + faded ink when the line's
            // FIRST checkbox is checked (Things-style completed task).
            // Start AFTER the token and its following whitespace — striking
            // the separator space drew a dash hanging left of the text
            // (Tom's 2026-07-10 screenshot).
            if tokens[0].checked {
                var styleLoc = NSMaxRange(tokens[0].range)
                let lineEnd = NSMaxRange(lineRange)
                while styleLoc < lineEnd,
                      let scalar = Unicode.Scalar(text.character(at: styleLoc)),
                      CharacterSet.whitespaces.contains(scalar) {
                    styleLoc += 1
                }
                let styleRange = NSRange(location: styleLoc, length: max(0, lineEnd - styleLoc))
                if styleRange.length > 0 {
                    self.addTemporaryAttributesSkippingMarkedText(
                        [
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: doneInk,
                        ],
                        range: styleRange, marked: marked
                    )
                }
            }
            // Hide token glyphs (circle is drawn in drawGlyphs). Explicit
            // strikethrough 0 so the done-line strike never crosses the
            // drawn circle.
            for token in tokens {
                self.addTemporaryAttributesSkippingMarkedText(
                    [.foregroundColor: NSColor.clear, .strikethroughStyle: 0],
                    range: token.range, marked: marked
                )
            }
        }
    }

    /// Never restyle inside an active IME composition (Japanese input):
    /// temporary attributes on the marked range would fight the input
    /// method's own composition styling. Ranges outside the marked range
    /// are styled normally; composition end fires another character edit,
    /// which restyles the paragraph fully.
    private func addTemporaryAttributesSkippingMarkedText(
        _ attrs: [NSAttributedString.Key: Any], range: NSRange, marked: NSRange
    ) {
        guard marked.location != NSNotFound,
              NSIntersectionRange(range, marked).length > 0 else {
            addTemporaryAttributes(attrs, forCharacterRange: range)
            return
        }
        let before = NSRange(
            location: range.location,
            length: max(0, marked.location - range.location)
        )
        let afterStart = NSMaxRange(marked)
        let after = NSRange(
            location: afterStart,
            length: max(0, NSMaxRange(range) - afterStart)
        )
        if before.length > 0 { addTemporaryAttributes(attrs, forCharacterRange: before) }
        if after.length > 0 { addTemporaryAttributes(attrs, forCharacterRange: after) }
    }

    private func currentMarkedRange() -> NSRange {
        guard let tv = firstTextView, tv.hasMarkedText() else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return tv.markedRange()
    }

    // MARK: Drawing

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let text = storage.string as NSString
        var charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        // Widen so tokens straddling the drawn range's edges render whole.
        let lo = max(0, charRange.location - (Self.tokenLength - 1))
        let hi = min(text.length, NSMaxRange(charRange) + (Self.tokenLength - 1))
        guard hi > lo else { return }
        charRange = NSRange(location: lo, length: hi - lo)
        let tokens = Self.checkboxTokens(in: text, range: charRange)
        guard !tokens.isEmpty else { return }

        // drawGlyphs is always invoked on the main thread (AppKit view
        // drawing); assumeIsolated bridges to the @MainActor theme.
        let (accent, stroke) = MainActor.assumeIsolated {
            (themeAccent(), themeInk(alpha: 0.35))
        }
        NSGraphicsContext.saveGraphicsState()
        for token in tokens {
            let glyphs = glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
            guard glyphs.length > 0,
                  let container = textContainer(
                    forGlyphAt: glyphs.location, effectiveRange: nil
                  )
            else { continue }
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            drawCheckboxCircle(in: rect, checked: token.checked, accent: accent, stroke: stroke)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCheckboxCircle(
        in tokenRect: NSRect, checked: Bool, accent: NSColor, stroke: NSColor
    ) {
        let maxSide = min(tokenRect.width, tokenRect.height)
        guard maxSide > 5 else { return }
        // Scales with the token's rendered size (font size changes included),
        // capped so large fonts don't produce cartoonish circles.
        let side = min(maxSide - 2, 13)
        let circleRect = NSRect(
            x: tokenRect.midX - side / 2,
            y: tokenRect.midY - side / 2,
            width: side,
            height: side
        )
        if checked {
            accent.setFill()
            NSBezierPath(ovalIn: circleRect).fill()
            // Checkmark in FLIPPED text-view coordinates (y grows downward).
            let check = NSBezierPath()
            check.lineWidth = max(1.4, side * 0.13)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            let w = circleRect.width
            let h = circleRect.height
            let ox = circleRect.minX
            let oy = circleRect.minY
            check.move(to: NSPoint(x: ox + 0.27 * w, y: oy + 0.53 * h))
            check.line(to: NSPoint(x: ox + 0.44 * w, y: oy + 0.69 * h))
            check.line(to: NSPoint(x: ox + 0.73 * w, y: oy + 0.34 * h))
            NSColor.white.setStroke()
            check.stroke()
        } else {
            let strokeWidth: CGFloat = 1.5
            let path = NSBezierPath(
                ovalIn: circleRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
            )
            path.lineWidth = strokeWidth
            stroke.setStroke()
            path.stroke()
        }
    }

    // MARK: Baseline-aligned paper ruling (S3c)

    /// Rule pitch fallback when no fragment metric is available (≈ the
    /// default 11pt body line + 2.5 line spacing).
    private static let fallbackRulePitch: CGFloat = 19

    /// 罫線/方眼 horizontal rules are drawn from REAL line fragments, so
    /// every rule sits exactly under its text line BY CONSTRUCTION — a
    /// constant pitch can never track font metrics, IME line heights, or
    /// mixed-size spans (Tom 2026-07-10: 「横の線がずれる」). Dots stay in
    /// SwiftUI's PaperPatternView (not line-coupled), as does the
    /// fully-EMPTY note (no fragments exist to align to — see
    /// NoteView.noteSurfaceBackground).
    ///
    /// Discipline: this is a pure draw pass — NO storage or attribute
    /// mutation, and drawing is scoped to the passed glyph range's
    /// fragments (drawBackground runs once per draw chunk; ruling outside
    /// the chunk would double-stroke). The one extension — ruling the empty
    /// region below the text — is drawn only by the chunk that owns the
    /// document tail.
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        // drawBackground is always invoked on the main thread (AppKit view
        // drawing); assumeIsolated bridges to the @MainActor settings.
        MainActor.assumeIsolated {
            drawPaperRules(forGlyphRange: glyphsToShow, at: origin)
        }
    }

    @MainActor
    private func drawPaperRules(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let settings = AppearanceSettings.shared
        let paper = settings.paperType
        guard paper == .lines || paper == .grid,
              numberOfGlyphs > 0,
              let tv = firstTextView else { return }
        let alpha = min(1.0, PaperType.defaultPatternOpacity * settings.paperStrength)
        guard alpha > 0.001 else { return }

        let scale = max(tv.window?.backingScaleFactor ?? 2, 1)
        /// Pixel-grid snap + half-pixel offset: a hairline stroke fills
        /// exactly one physical pixel row (same recipe as PaperPatternView).
        func snapped(_ v: CGFloat) -> CGFloat { ((v * scale).rounded() + 0.5) / scale }

        // Rules span the full note width, edge to edge like printed paper
        // (stopping at the container inset would leave bare margins).
        let maxX = tv.bounds.width
        guard maxX > 0 else { return }
        let path = NSBezierPath()
        path.lineWidth = 1 / scale

        var chunkTop = CGFloat.greatestFiniteMagnitude
        var chunkBottom: CGFloat = 0
        var lastPitch: CGFloat = 0
        var drewAnything = false

        func addRule(underFragment rect: NSRect) {
            let y = snapped(origin.y + rect.maxY)
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: maxX, y: y))
            chunkTop = min(chunkTop, origin.y + rect.minY)
            chunkBottom = max(chunkBottom, origin.y + rect.maxY)
            lastPitch = rect.height
            drewAnything = true
        }

        // One rule under EACH line fragment in this chunk.
        if glyphsToShow.length > 0 {
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, _, _ in
                addRule(underFragment: rect)
            }
        }

        // Tail-owner extension: rule the empty region below the text (the
        // extra fragment = caret line after a trailing newline, then
        // constant-pitch continuation) so the paper never goes blank under
        // the last written line.
        if NSMaxRange(glyphsToShow) >= numberOfGlyphs {
            if extraLineFragmentRect.height > 0 {
                addRule(underFragment: extraLineFragmentRect)
            } else if !drewAnything {
                // Degenerate tail chunk (empty glyph range): anchor to the
                // document's real last fragment WITHOUT ruling it — the
                // chunk that owns it draws that rule.
                let lastRect = lineFragmentRect(forGlyphAt: numberOfGlyphs - 1,
                                                effectiveRange: nil)
                chunkTop = origin.y + lastRect.maxY
                chunkBottom = chunkTop
                lastPitch = lastRect.height
            }
            if lastPitch < 4 { lastPitch = Self.fallbackRulePitch }
            let bottomLimit = max(tv.bounds.height,
                                  tv.enclosingScrollView?.contentView.bounds.height ?? 0)
            var y = chunkBottom + lastPitch
            while y < bottomLimit {
                path.move(to: NSPoint(x: 0, y: snapped(y)))
                path.line(to: NSPoint(x: maxX, y: snapped(y)))
                chunkBottom = y
                drewAnything = true
                y += lastPitch
            }
        }

        guard drewAnything else { return }

        // 方眼 verticals: SQUARE cells at any body size — ride the same
        // measured fragment pitch the horizontals use (S16: text size is
        // user-adjustable now, so any fixed pattern pitch goes non-square
        // the moment the user steps off the default). Fragment-truth has
        // the same trade-off as the horizontals: a chunk whose last
        // fragment is a heading measures that line, but the body is
        // normalized to ONE size by rescaleToDefaultSize, so chunks agree
        // in practice. Fixed pitch remains the degenerate-chunk fallback.
        // Each chunk strokes only its own y-extent so chunks tile without
        // double-drawing; the first chunk stretches to the note's top edge.
        if paper == .grid {
            let top: CGFloat = glyphsToShow.location == 0 ? 0 : chunkTop
            let spacing = lastPitch >= 4 ? lastPitch : PaperType.grid.patternSpacing
            var x = spacing
            while x < maxX {
                let sx = snapped(x)
                path.move(to: NSPoint(x: sx, y: top))
                path.line(to: NSPoint(x: sx, y: chunkBottom))
                x += spacing
            }
        }

        // Theme ink — same base as the checkbox stroke and the typing ink,
        // so the ruling harmonizes with the text it sits under.
        themeInk(alpha: alpha).setStroke()
        path.stroke()
    }
}

// MARK: - Checkbox-aware NSTextView

// S7C-CALC-PURE-BEGIN
/// S7-5 inline calculator (Antinote parity): typing "=" after an
/// arithmetic expression inserts the result. Also: unit conversion
/// ("58cm to in=") and sum/avg/合計/平均 trigger lines — see the marked
/// sections below. Pure recursive-descent parser — NSExpression is
/// deliberately avoided (it throws ObjC exceptions on malformed input,
/// uncatchable from Swift = crash).
/// Grammar: expr = term (('+'|'-') term)* ; term = factor (('*'|'/') factor)* ;
/// factor = number | '(' expr ')' | '-' factor. Numbers accept , as a
/// thousands separator. Division by zero and any parse residue = nil.
enum FloteCalc {

    /// Humans type multiplication as x/× and division as ÷ ("34x213=" —
    /// live-fired by Tom 2026-07-11; ASCII * only is programmer dialect).
    /// × and ÷ are unambiguous math glyphs → always mapped. ASCII x/X maps
    /// ONLY between digit-ish neighbors, so identifiers ("S7x5", "0xFF"
    /// stays hex-shaped and fails closed) never turn into arithmetic.
    /// "% of" is Antinote's colloquial form ("50% of 200") — mapped to
    /// multiplication only right after a percent literal, so prose "of"
    /// never becomes an operator.
    static func normalizedOperators(_ line: String) -> String {
        var s = line
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "**", with: "^")
        s = s.replacingOccurrences(
            of: #"(?<=[0-9).])\s*[xX]\s*(?=[0-9(.])"#,
            with: "*",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"(?<=%)\s*of\s*(?=[0-9(.])"#,
            with: "*",
            options: .regularExpression
        )
        // Word functions → single-glyph internal tokens, so the tail scan
        // stays letter-free (letters in the scan would swallow prose like
        // "milk 2*3" — live-fired regression class). Only the glued
        // "name(" form converts; bare prose "sqrt" stays text.
        for (word, glyph) in [("sqrt(", "√("), ("cbrt(", "∛("),
                              ("log2(", "⌈("), ("log(", "⌊("),
                              ("ceil(", "⌉("), ("floor(", "⌋(")] {
            s = s.replacingOccurrences(of: word, with: glyph)
        }
        return s
    }

    /// The candidate expression = the line's tail after the last character
    /// that cannot be part of an expression (so "買い物 3*480" works).
    static func expressionCandidate(inLineBeforeCaret rawLine: String) -> String? {
        let line = normalizedOperators(rawLine)
        let allowed = Set("0123456789+-*/(). ,%^!√∛⌊⌈⌉⌋")
        var tail = [Character]()
        var boundary: Character? = nil
        for ch in line.reversed() {
            if allowed.contains(ch) { tail.append(ch) } else { boundary = ch; break }
        }
        let raw = String(tail.reversed())
        // "S7-5" is an identifier, not arithmetic: reject ONLY when the tail
        // is GLUED to a letter/digit (no whitespace between) — "買い物 3*480"
        // has a space before the expression and stays valid (r3 minor).
        if let b = boundary, b.isLetter || b.isNumber,
           raw.first?.isWhitespace != true { return nil }
        let candidate = raw.trimmingCharacters(in: .whitespaces)
        // Must contain at least one operator AND one digit — a bare number
        // followed by "=" is prose ("答えは42="), not a calculation request.
        guard candidate.rangeOfCharacter(
                  from: CharacterSet(charactersIn: "+-*/%^!√∛⌊⌈⌉⌋")) != nil,
              candidate.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        // A lone trailing % with no operator is prose ("進捗80%="), not math.
        if candidate.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^")) == nil,
           candidate.hasSuffix("%") { return nil }
        return candidate
    }

    /// Parsed value: `pct` marks a percent literal so the ADDITIVE rule can
    /// apply Antinote's colloquial semantics — "100+15%" means 100 plus 15%
    /// OF 100 (= 115), while "50%*200" is plain 0.5*200 (= 100).
    private struct Val {
        var v: Double
        var pct: Bool
    }

    /// nil = not a valid complete expression (fail closed — never guess).
    /// Grammar: expr = term (('+'|'-') term)* ; term = power (('*'|'/') power)* ;
    /// power = factor ('^' factor)* right-assoc ; factor = ['-'] (number|'('expr')') ['%'].
    static func evaluate(_ expression: String) -> Double? {
        let chars = Array(expression.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: ""))
        // 128, not 64: substitute() now injects FULL-precision values
        // ("(0.333333333333)" = 16 chars per variable), so a multi-variable
        // line needs the headroom. Still a hard runaway-input cap.
        guard !chars.isEmpty, chars.count <= 128 else { return nil }
        var pos = 0

        func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

        func number() -> Double? {
            var digits = ""
            while let c = peek(), c.isNumber || c == "." {
                digits.append(c); pos += 1
            }
            return digits.isEmpty ? nil : Double(digits)
        }

        // Prefix functions (Antinote §2): √ ∛ and the parenthesized word
        // forms mapped to glyphs by normalizedOperators. All fail closed on
        // domain errors (negative sqrt, log of <=0).
        func applyFunction(_ glyph: Character, _ v: Double) -> Double? {
            switch glyph {
            case "√": return v >= 0 ? v.squareRoot() : nil
            case "∛": return cbrt(v)
            case "⌊": return v > 0 ? log10(v) : nil
            case "⌈": return v > 0 ? log2(v) : nil
            case "⌉": return v.rounded(.up)
            case "⌋": return v.rounded(.down)
            default:  return nil
            }
        }

        // n! / n!! — integers only, capped so Double stays exact-ish.
        func factorial(_ v: Double, double: Bool) -> Double? {
            guard v == v.rounded(), v >= 0, v <= (double ? 30 : 20) else { return nil }
            var n = Int(v), acc = 1.0
            while n > 1 { acc *= Double(n); n -= double ? 2 : 1 }
            return acc
        }

        func factor() -> Val? {
            if peek() == "-" { pos += 1; return factor().map { Val(v: -$0.v, pct: $0.pct) } }
            if let g = peek(), "√∛⌊⌈⌉⌋".contains(g) {
                pos += 1
                guard let inner = factor(), let r = applyFunction(g, inner.v),
                      r.isFinite else { return nil }
                return Val(v: r, pct: false)
            }
            var base: Double
            if peek() == "(" {
                pos += 1
                guard let v = expr(), peek() == ")" else { return nil }
                pos += 1
                base = v.v
            } else {
                guard let n = number() else { return nil }
                base = n
            }
            while peek() == "!" {
                pos += 1
                let isDouble = peek() == "!"
                if isDouble { pos += 1 }
                guard let f = factorial(base, double: isDouble) else { return nil }
                base = f
            }
            if peek() == "%" {
                pos += 1
                return Val(v: base / 100, pct: true)
            }
            return Val(v: base, pct: false)
        }

        func power() -> Val? {
            guard let b = factor() else { return nil }
            guard peek() == "^" else { return b }
            pos += 1
            guard let e = power() else { return nil }   // right-assoc
            let r = pow(b.v, e.v)
            guard r.isFinite else { return nil }
            return Val(v: r, pct: false)
        }

        func term() -> Val? {
            guard var v = power() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                pos += 1
                guard let r = power() else { return nil }
                if op == "*" { v = Val(v: v.v * r.v, pct: false) }
                else {
                    guard r.v != 0 else { return nil }
                    v = Val(v: v.v / r.v, pct: false)
                }
            }
            return v
        }

        func expr() -> Val? {
            guard var v = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                pos += 1
                guard let r = term() else { return nil }
                // Colloquial percent: "100+15%" = 100 + (100*0.15) = 115,
                // "200-10%" = 180. A non-percent right side adds normally.
                let delta = r.pct ? v.v * r.v : r.v
                v = Val(v: op == "+" ? v.v + delta : v.v - delta, pct: false)
            }
            return v
        }

        guard let result = expr(), pos == chars.count,
              result.v.isFinite else { return nil }
        return result.v
    }

    /// Reactive variables (Antinote flagship: "build custom calculators in
    /// seconds"). A definition line is `name : value-or-expr` — the name
    /// needs at least one letter (so "15:30 会議" or "3 : 4" never become
    /// variables) and no calc operators. Full-width ： accepted. Anything
    /// after the first "=" in the body is a previously rendered result and
    /// is ignored.
    static func variableDefinition(inLine rawLine: String)
        -> (name: String, expression: String)? {
        let line = rawLine.replacingOccurrences(of: "：", with: ":")
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        var expr = String(line[line.index(after: colon)...])
        if let eq = expr.firstIndex(of: "=") { expr = String(expr[..<eq]) }
        expr = expr.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, !expr.isEmpty, expr.count <= 64,
              name.rangeOfCharacter(from: .letters) != nil,
              name.rangeOfCharacter(
                  from: CharacterSet(charactersIn: "+-*/^%()=:")) == nil
        else { return nil }
        return (name, expr)
    }

    /// Top-to-bottom variable table; later definitions may use earlier
    /// variables ("a : 2 / b : a*3"), and a re-definition wins. A body that
    /// doesn't evaluate to a number (prose "メモ : 買い物") is not a variable.
    static func variables(inText text: String) -> [(name: String, value: Double)] {
        var table: [(name: String, value: Double)] = []
        for line in text.components(separatedBy: .newlines) {
            guard let def = variableDefinition(inLine: line) else { continue }
            let body = substitute(variables: table, in: def.expression)
            guard let v = evaluate(normalizedOperators(body)) else { continue }
            table.removeAll { $0.name == def.name }
            table.append((def.name, v))
        }
        return table
    }

    /// Longest-name-first textual substitution: each variable occurrence
    /// becomes its parenthesized FULL-precision value (formatFullPrecision,
    /// never the 2dp display form — chained variables must not lose
    /// precision through display rounding). Names that only appear inside
    /// other words break the parse and fail closed, never guess.
    static func substitute(
        variables: [(name: String, value: Double)], in text: String) -> String {
        guard !variables.isEmpty else { return text }
        var s = text
        for v in variables.sorted(by: { $0.name.count > $1.name.count }) {
            s = s.replacingOccurrences(
                of: v.name, with: "(\(formatFullPrecision(v.value)))")
        }
        return s
    }

    /// "408" not "408.0"; up to 6 fractional digits, trailing zeros trimmed.
    /// NOT the answer format (that is formatAnswer) — this is the precision
    /// used by formatAnswer's tiny-magnitude escape hatch.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// FULL-precision plain-decimal rendering — INTERNAL substitution only,
    /// never displayed. The DISPLAYED answer is 2dp (formatAnswer); the
    /// value a variable carries into the next expression must not pass
    /// through display rounding ("幅 : 1/3" then "幅*3=" is 1.00, never
    /// 0.99). 12 fractional digits ≈ Double's usable precision for
    /// calculator-range values; integers render exact; plain decimal
    /// always (evaluate's number() reads digits and "." only — an exponent
    /// form would fail the parse).
    static func formatFullPrecision(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var s = String(format: "%.12f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: Unit conversion (Antinote parity: "10km to mi =")

    /// Dimension of a unit — conversions never cross dimensions
    /// ("10km to kg" fails closed).
    private enum Dimension { case length, area, mass, volume, temperature }

    /// Linear units convert through a canonical base (m / kg / L) via
    /// `toBase`. Temperature is AFFINE (offset + scale), not linear —
    /// convert(_:from:to:) special-cases it and `toBase` is unused there.
    private struct CalcUnit {
        let dim: Dimension
        let toBase: Double
        let label: String
    }

    /// Alias → unit. Keys are lowercase (ASCII lookup lowercases first);
    /// JP aliases have no case. `"` is Antinote's inches shorthand.
    private static let unitTable: [String: CalcUnit] = {
        var table: [String: CalcUnit] = [:]
        func add(_ names: [String], _ dim: Dimension, _ toBase: Double, _ label: String) {
            for n in names { table[n] = CalcUnit(dim: dim, toBase: toBase, label: label) }
        }
        // Length, base = meter.
        add(["mm", "ミリ"], .length, 0.001, "mm")
        add(["cm", "センチ"], .length, 0.01, "cm")
        add(["m", "メートル"], .length, 1, "m")
        add(["km", "キロ"], .length, 1000, "km")
        add(["in", "inch", "inches", "\"", "インチ"], .length, 0.0254, "in")
        add(["ft", "feet", "フィート"], .length, 0.3048, "ft")
        add(["yd"], .length, 0.9144, "yd")
        add(["mi", "mile", "miles", "マイル"], .length, 1609.344, "mi")
        // Area, base = square meter. 坪 (tsubo) is the spec-flagged P1 unit
        // for this JP user base (spec §3: "全単位表を持つこと自体が仕様").
        add(["sqm", "m2", "平米", "㎡"], .area, 1, "sqm")
        add(["sqkm", "km2"], .area, 1_000_000, "sqkm")
        add(["sqft", "ft2"], .area, 0.09290304, "sqft")
        add(["acre"], .area, 4046.8564224, "acre")
        add(["ha", "ヘクタール"], .area, 10_000, "ha")
        add(["tsubo", "坪"], .area, 3.305785, "tsubo")
        // Mass, base = kilogram.
        add(["mg"], .mass, 0.000001, "mg")
        add(["g", "グラム"], .mass, 0.001, "g")
        add(["kg", "キログラム"], .mass, 1, "kg")
        add(["t"], .mass, 1000, "t")
        add(["ton", "トン"], .mass, 1000, "ton")
        add(["stone"], .mass, 6.35029, "stone")
        add(["oz"], .mass, 0.028349523125, "oz")
        add(["lb", "lbs", "pound", "pounds"], .mass, 0.45359237, "lb")
        // Volume, base = liter ("l" and "L" both display as "L").
        add(["ml"], .volume, 0.001, "ml")
        add(["l", "リットル"], .volume, 1, "L")
        add(["gal"], .volume, 3.785411784, "gal")
        add(["cup", "カップ"], .volume, 0.24, "cup")
        add(["tbsp"], .volume, 0.015, "tbsp")
        add(["tsp"], .volume, 0.005, "tsp")
        add(["floz"], .volume, 0.0295735, "floz")
        add(["pint"], .volume, 0.473176, "pint")
        add(["quart"], .volume, 0.946353, "quart")
        // Temperature — affine, handled in convert(); toBase unused.
        add(["c", "celsius"], .temperature, 1, "°C")
        add(["f", "fahrenheit"], .temperature, 1, "°F")
        return table
    }()

    /// `<number> <unit> to <unit>` anchored at the END of the line.
    /// Alternatives are sorted longest-first because ICU alternation is
    /// first-match, not longest-match ("inches" must win over "in",
    /// "キログラム" over "キロ"/"グラム").
    private static let conversionRegex: NSRegularExpression? = {
        let names = unitTable.keys
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let unit = "(" + names.joined(separator: "|") + ")"
        let number = "([+-]?[0-9][0-9,]*(?:\\.[0-9]+)?)"
        let pattern = number + "\\s*" + unit + "\\s+to\\s+" + unit + "\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Parses the conversion request at the line's tail ("58cm to in",
    /// "10 km to mi", "10\" to cm", "10キロ to マイル"). Antinote's
    /// limitation is kept deliberately: a conversion never combines with
    /// arithmetic in one line — a glued identifier ("S710km") or a
    /// preceding operator ("10+5km") fails the WHOLE line closed.
    /// Unit validity/dimension is checked by convert(_:from:to:).
    static func conversionCandidate(inLineBeforeCaret line: String)
        -> (value: Double, from: String, to: String)? {
        guard let regex = conversionRegex else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(
            in: line, options: [],
            range: NSRange(location: 0, length: ns.length)) else { return nil }
        // Boundary protection (same spirit as expressionCandidate): the
        // character right before the number must not glue it to an
        // identifier or an arithmetic expression.
        if gluedToPrefix(m.range, in: ns) { return nil }
        let numberText = ns.substring(with: m.range(at: 1))
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(numberText) else { return nil }
        return (value,
                ns.substring(with: m.range(at: 2)),
                ns.substring(with: m.range(at: 3)))
    }

    /// True when the character immediately before `range` glues it to an
    /// identifier or arithmetic ("S710km…", "10+5 USD…") — the shared
    /// boundary rule for every tail-anchored request form (units,
    /// currency, currency-amount, rate-only).
    private static func gluedToPrefix(_ range: NSRange, in ns: NSString) -> Bool {
        guard range.location > 0 else { return false }
        let prevRange = ns.rangeOfComposedCharacterSequence(at: range.location - 1)
        guard let prev = ns.substring(with: prevRange).first else { return false }
        return prev.isLetter || prev.isNumber || "+-*/^%.(".contains(prev)
    }

    /// nil = unknown unit or cross-dimension request (fail closed).
    /// Linear dimensions go through the base unit; temperature is affine
    /// (°C→°F = ×9/5 +32 — NOT a ratio: -40 °F = -40 °C).
    static func convert(value: Double, from: String, to: String)
        -> (result: Double, unitLabel: String)? {
        guard let f = unitTable[from.lowercased()],
              let t = unitTable[to.lowercased()],
              f.dim == t.dim else { return nil }
        let result: Double
        if f.dim == .temperature {
            let celsius = f.label == "°F" ? (value - 32) * 5 / 9 : value
            result = t.label == "°F" ? celsius * 9 / 5 + 32 : celsius
        } else {
            result = value * f.toBase / t.toBase
        }
        guard result.isFinite else { return nil }
        return (result, t.label)
    }

    /// The exact STRING the view inserts after "=" for a conversion line
    /// ("22.83 in" — formatAnswer + the target unit's canonical label), or
    /// nil — keeps the view layer dumb. Called with the RAW line (no
    /// variable substitution): unit tokens must never be rewritten by a
    /// same-named variable.
    static func conversionResult(inLineBeforeCaret line: String) -> String? {
        guard let cand = conversionCandidate(inLineBeforeCaret: line),
              let out = convert(value: cand.value, from: cand.from, to: cand.to)
        else { return nil }
        return formatAnswer(out.result) + " " + out.unitLabel
    }

    // MARK: Currency + crypto conversion (Antinote: "10 USD to JPY = 1,492.84 JPY")

    /// Alias → ISO-4217 / ticker code. Keys are lowercase (lookup lowercases
    /// ASCII first; JP aliases have no case). Fiat = the frankfurter.dev
    /// (ECB reference) set — ~31 currencies, an honest subset, NOT the
    /// "200+" a paid API would give. Crypto = the 4 majors the CoinGecko
    /// free tier is polled for (BTC/ETH/SOL/DOGE).
    /// ¥/￥ ambiguity (JPY vs CNY): mapped to JPY — this user base is JP,
    /// and 元/人民元 cover CNY explicitly.
    static let currencyAliases: [String: String] = {
        var table: [String: String] = [:]
        func add(_ names: [String], _ code: String) {
            for n in names { table[n] = code }
        }
        // Fiat with symbol / JP-name aliases.
        add(["usd", "$", "ドル", "米ドル"], "USD")
        add(["eur", "€", "ユーロ"], "EUR")
        add(["jpy", "¥", "￥", "円", "日本円"], "JPY")
        add(["gbp", "£", "ポンド"], "GBP")
        add(["krw", "₩", "ウォン"], "KRW")
        add(["cny", "元", "人民元"], "CNY")
        add(["aud", "豪ドル"], "AUD")
        add(["chf", "スイスフラン"], "CHF")
        add(["hkd", "香港ドル"], "HKD")
        // Rest of the ECB set, ISO code only.
        for code in ["bgn", "brl", "cad", "czk", "dkk", "huf", "idr", "ils",
                     "inr", "isk", "mxn", "myr", "nok", "nzd", "php", "pln",
                     "ron", "sek", "sgd", "thb", "try", "zar"] {
            table[code] = code.uppercased()
        }
        // Crypto tickers + names.
        add(["btc", "₿", "bitcoin", "ビットコイン"], "BTC")
        add(["eth", "ethereum", "イーサリアム"], "ETH")
        add(["sol", "solana", "ソラナ"], "SOL")
        add(["doge", "dogecoin", "ドージコイン"], "DOGE")
        return table
    }()

    /// Canonical code for an alias token (nil = not a currency).
    static func currencyCode(for token: String) -> String? {
        currencyAliases[token.lowercased()]
    }

    /// `<number> <currency> to <currency>` anchored at the END of the line
    /// ("10 USD to JPY", "10ドル to 円", "0.1 BTC to USD"). Longest-first
    /// for the same reason as conversionRegex (ICU alternation is
    /// first-match: "米ドル" must win over "ドル").
    private static let currencyPostfixRegex: NSRegularExpression? = {
        let names = currencyAliases.keys
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let cur = "(" + names.joined(separator: "|") + ")"
        let number = "([+-]?[0-9][0-9,]*(?:\\.[0-9]+)?)"
        let pattern = number + "\\s*" + cur + "\\s+to\\s+" + cur + "\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Symbol-prefix form "$10 to JPY" — the prefix position is idiomatic
    /// for SYMBOLS only; letter codes stay postfix ("USD10" reads as an
    /// identifier, not money — fail closed).
    private static let currencyPrefixRegex: NSRegularExpression? = {
        let names = currencyAliases.keys
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let cur = "(" + names.joined(separator: "|") + ")"
        let symbols = ["$", "€", "£", "¥", "￥", "₩", "₿"]
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let sym = "(" + symbols.joined(separator: "|") + ")"
        let number = "([0-9][0-9,]*(?:\\.[0-9]+)?)"
        let pattern = sym + "\\s*" + number + "\\s+to\\s+" + cur + "\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Parses the currency request at the line's tail. Returns the RAW
    /// from/to tokens — convertCurrency resolves aliases (mirrors the
    /// conversionCandidate/convert split). Boundary rule identical to the
    /// unit path: a glued identifier ("S710 USD…") or a preceding operator
    /// ("10+5 USD…") fails the WHOLE line closed.
    static func currencyConversionCandidate(inLineBeforeCaret line: String)
        -> (value: Double, from: String, to: String)? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        // (regex, number group, from group); the "to" target is group 3
        // in both shapes.
        let attempts: [(NSRegularExpression?, Int, Int)] = [
            (currencyPostfixRegex, 1, 2),
            (currencyPrefixRegex, 2, 1),
        ]
        for (regex, numberGroup, fromGroup) in attempts {
            guard let regex,
                  let m = regex.firstMatch(in: line, options: [], range: full)
            else { continue }
            if gluedToPrefix(m.range, in: ns) { continue }
            let numberText = ns.substring(with: m.range(at: numberGroup))
                .replacingOccurrences(of: ",", with: "")
            guard let value = Double(numberText) else { continue }
            return (value,
                    ns.substring(with: m.range(at: fromGroup)),
                    ns.substring(with: m.range(at: 3)))
        }
        return nil
    }

    // MARK: Currency without an explicit target — "$10 =" / "10 USD =" /
    // rate-only "USD to JPY =" (spec §4 manual examples: "$10 = 14.00 CAD",
    // "USD to CAD = 1.39 CAD")

    /// UserDefaults key for the primary–secondary currency pair. No
    /// Settings UI in this slice (deferred) — the default serves the JP
    /// user base; the view layer reads the key and passes the raw string
    /// into currencyResult (pure layer never touches UserDefaults).
    static let currencyPairDefaultsKey = "floteCurrencyPair"
    static let defaultCurrencyPair = "USD-JPY"

    /// "USD-JPY" → (USD, JPY); aliases resolve ("usd-円" works). A
    /// malformed / unknown / same-code pair resolves to the DEFAULT pair —
    /// a corrupt preference downgrades to the default target, it never
    /// kills the feature (the amount itself still converts correctly).
    static func resolvedCurrencyPair(_ raw: String?) -> (primary: String, secondary: String) {
        if let raw {
            let parts = raw.split(separator: "-").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2,
               let p = currencyCode(for: parts[0]),
               let s = currencyCode(for: parts[1]),
               p != s {
                return (p, s)
            }
        }
        return ("USD", "JPY")
    }

    /// `<number> <currency>` with NO target, anchored at the END of the
    /// line ("10 USD", "1000円", "10ドル").
    private static let currencyAmountPostfixRegex: NSRegularExpression? = {
        let names = currencyAliases.keys
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let cur = "(" + names.joined(separator: "|") + ")"
        let number = "([+-]?[0-9][0-9,]*(?:\\.[0-9]+)?)"
        let pattern = number + "\\s*" + cur + "\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// `<symbol><number>` with NO target ("$10", "¥1000") — prefix
    /// position is symbols-only, same rationale as currencyPrefixRegex.
    private static let currencyAmountPrefixRegex: NSRegularExpression? = {
        let symbols = ["$", "€", "£", "¥", "￥", "₩", "₿"]
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let sym = "(" + symbols.joined(separator: "|") + ")"
        let number = "([0-9][0-9,]*(?:\\.[0-9]+)?)"
        let pattern = sym + "\\s*" + number + "\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Parses a no-target currency amount at the line's tail. Returns the
    /// RAW from token (currencyResult resolves it and picks the target
    /// from the configured pair). Boundary rule identical to the other
    /// tail forms.
    static func currencyAmountCandidate(inLineBeforeCaret line: String)
        -> (value: Double, from: String)? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        let attempts: [(NSRegularExpression?, Int, Int)] = [
            (currencyAmountPostfixRegex, 1, 2),
            (currencyAmountPrefixRegex, 2, 1),
        ]
        for (regex, numberGroup, fromGroup) in attempts {
            guard let regex,
                  let m = regex.firstMatch(in: line, options: [], range: full)
            else { continue }
            if gluedToPrefix(m.range, in: ns) { continue }
            let numberText = ns.substring(with: m.range(at: numberGroup))
                .replacingOccurrences(of: ",", with: "")
            guard let value = Double(numberText) else { continue }
            return (value, ns.substring(with: m.range(at: fromGroup)))
        }
        return nil
    }

    /// `<currency> to <currency>` with NO number, anchored at the END —
    /// the rate-only form ("USD to JPY =" → the 1-unit rate).
    private static let currencyRateRegex: NSRegularExpression? = {
        let names = currencyAliases.keys
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let cur = "(" + names.joined(separator: "|") + ")"
        let pattern = cur + "\\s+to\\s+" + cur + "\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Parses the rate-only request. Returns RAW tokens. Two-layer
    /// boundary: the immediate glue rule, PLUS "no digit/operator anywhere
    /// right before the pair" — "10+5 USD to JPY" is a FAILED amount
    /// request (arithmetic never combines with a conversion) and must stay
    /// closed, never resurrect as a 1-unit rate.
    static func currencyRateCandidate(inLineBeforeCaret line: String)
        -> (from: String, to: String)? {
        guard let regex = currencyRateRegex else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(
            in: line, options: [],
            range: NSRange(location: 0, length: ns.length)) else { return nil }
        if gluedToPrefix(m.range, in: ns) { return nil }
        let before = ns.substring(to: m.range.location)
            .trimmingCharacters(in: .whitespaces)
        if let last = before.last,
           last.isNumber || "+-*/^%.(".contains(last) { return nil }
        return (ns.substring(with: m.range(at: 1)),
                ns.substring(with: m.range(at: 2)))
    }

    /// True when the line's tail is ANY currency request shape — the
    /// view-layer gate that decides whether the rates lookup (which may
    /// kick a background refresh) runs at all, and whether a recalc leaves
    /// an existing rendered result alone when rates are unavailable.
    static func isCurrencyRequest(inLineBeforeCaret line: String) -> Bool {
        currencyConversionCandidate(inLineBeforeCaret: line) != nil
            || currencyAmountCandidate(inLineBeforeCaret: line) != nil
            || currencyRateCandidate(inLineBeforeCaret: line) != nil
    }

    /// nil = unknown code, missing rate, or non-positive rate (fail
    /// closed). `rates` is PASSED IN (pure = harness-testable; RatesService
    /// supplies it at the view-layer call site): rates[code] = units of
    /// `code` per 1 USD, so crypto entries are stored inverted
    /// (1 / USD price) and both directions run through one dictionary.
    static func convertCurrency(value: Double, from: String, to: String,
                                rates: [String: Double])
        -> (result: Double, code: String)? {
        guard let f = currencyCode(for: from), let t = currencyCode(for: to),
              let rf = rates[f], let rt = rates[t],
              rf > 0, rt > 0 else { return nil }
        let result = value / rf * rt
        guard result.isFinite else { return nil }
        return (result, t)
    }

    /// THE answer formatter — every numeric answer Flote renders (plain
    /// math, unit conversion, currency, sum/avg; count stays a
    /// preformatted string). Antinote's rendering, landing-page verified
    /// (spec Appendix C): thousands separators AND exactly 2 decimals,
    /// ALWAYS — "14,323.17 km", "5,149,100.00", "266.25". Small integers
    /// also render 2dp ("42.00"): the LP has no small-integer
    /// counter-example, and one consistent rule beats two. Single escape
    /// hatch: a nonzero value that %.2f would collapse to "0.00" (sub-cent
    /// crypto — 100 USD in BTC) falls back to format()'s 6-digit
    /// precision, because "0.00 BTC" is a lie.
    static func formatAnswer(_ value: Double) -> String {
        let rendered = String(format: "%.2f", value)
        if value != 0, rendered == "0.00" || rendered == "-0.00" {
            return groupedThousands(format(value))
        }
        return groupedThousands(rendered)
    }

    /// "1234567.89" → "1,234,567.89". Pure string surgery on the integer
    /// part; sign and fraction pass through untouched.
    static func groupedThousands(_ s: String) -> String {
        var body = s
        let negative = body.hasPrefix("-")
        if negative { body.removeFirst() }
        let pieces = body.split(separator: ".", maxSplits: 1,
                                omittingEmptySubsequences: false)
        var intPart = String(pieces[0])
        var grouped = ""
        while intPart.count > 3 {
            let cut = intPart.index(intPart.endIndex, offsetBy: -3)
            grouped = "," + intPart[cut...] + grouped
            intPart = String(intPart[..<cut])
        }
        grouped = intPart + grouped
        if pieces.count > 1 { grouped += "." + pieces[1] }
        return (negative ? "-" : "") + grouped
    }

    /// Staleness verdict for a cached rates snapshot — PURE
    /// ((fetchedAt, now) → policy) so the harness can unit-test it with no
    /// network and no wall clock.
    /// - fresh (< 24h): serve, no refetch — Antinote refreshes daily too.
    /// - staleUsable (24h – 7d): serve BUT kick a refetch — a day-old FX
    ///   rate beats inserting nothing while the network is down.
    /// - expired (> 7d, or fetchedAt in the future beyond 1h clock-skew
    ///   grace = corrupt cache): unusable — a week-old rate is a lie;
    ///   fail closed.
    enum RatesPolicy { case fresh, staleUsable, expired }
    static func ratesPolicy(fetchedAt: Date, now: Date) -> RatesPolicy {
        let age = now.timeIntervalSince(fetchedAt)
        if age < -3600 { return .expired }
        if age <= 24 * 3600 { return .fresh }
        if age <= 7 * 24 * 3600 { return .staleUsable }
        return .expired
    }

    /// The exact STRING the view inserts after "=" for ANY currency line,
    /// or nil — keeps the view layer dumb, like conversionResult. Three
    /// request shapes, most-specific first:
    ///   1. explicit target — "10 USD to JPY" / "$10 to 円" → "1,492.84 JPY"
    ///   2. amount, no target — "$10" / "10 USD" / "1000円" → converted to
    ///      the OTHER side of the configured pair (`pair` = the raw
    ///      floteCurrencyPair string, default USD-JPY): $10 → JPY,
    ///      1000円 → USD; a currency in NEITHER side targets the pair's
    ///      secondary (deterministic, documented).
    ///   3. rate only — "USD to JPY" → "149.28 JPY per USD" (1-unit rate).
    /// rates == nil (no usable cache: never fetched, or > 7 days stale)
    /// fails the WHOLE request closed — the calculator inserts nothing
    /// rather than a guessed number. Called with the RAW line (no variable
    /// substitution), same rationale as units.
    static func currencyResult(
        inLineBeforeCaret line: String,
        rates: [String: Double]?,
        pair rawPair: String?) -> String? {
        guard let rates else { return nil }
        if let cand = currencyConversionCandidate(inLineBeforeCaret: line) {
            guard let out = convertCurrency(value: cand.value, from: cand.from,
                                            to: cand.to, rates: rates)
            else { return nil }
            return formatAnswer(out.result) + " " + out.code
        }
        if let cand = currencyAmountCandidate(inLineBeforeCaret: line) {
            guard let from = currencyCode(for: cand.from) else { return nil }
            let pair = resolvedCurrencyPair(rawPair)
            let to = from == pair.secondary ? pair.primary : pair.secondary
            guard let out = convertCurrency(value: cand.value, from: from,
                                            to: to, rates: rates)
            else { return nil }
            return formatAnswer(out.result) + " " + out.code
        }
        if let cand = currencyRateCandidate(inLineBeforeCaret: line) {
            guard let fromCode = currencyCode(for: cand.from),
                  let out = convertCurrency(value: 1, from: cand.from,
                                            to: cand.to, rates: rates)
            else { return nil }
            return formatAnswer(out.result) + " " + out.code + " per " + fromCode
        }
        return nil
    }

    // MARK: Aggregates (Antinote sum/avg keywords, mapped to a trigger line)

    enum Aggregate { case sum, avg }

    /// A line that IS the aggregate trigger: exactly `sum` / `avg` /
    /// `合計` / `平均` (ASCII case-insensitive), optionally preceded by
    /// whitespace and/or one checkbox token. Anything else on the line =
    /// not a trigger (fail closed — "sum today" stays prose).
    static func aggregateKeyword(inLineBeforeCaret rawLine: String) -> Aggregate? {
        var s = rawLine.trimmingCharacters(in: .whitespaces)
        for token in ["[ ]", "[\u{2713}]"] where s.hasPrefix(token) {
            s = String(s.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        switch s.lowercased() {
        case "sum", "合計": return .sum
        case "avg", "平均": return .avg
        default: return nil
        }
    }

    /// Number extraction for aggregates: thousands commas, decimals,
    /// negatives. The lookbehind rejects digit runs glued to a larger
    /// token — identifiers ("S7"), decimal tails, thousands-group tails,
    /// and hyphenated compounds ("S7-5", "2026-07-10") fail closed.
    private static let aggregateNumberRegex = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_.,\\-])-?[0-9][0-9,]*(?:\\.[0-9]+)?")

    /// Sum/average over every number in the note text ABOVE the trigger
    /// line. The view passes the text with .floteCalcResult runs already
    /// STRIPPED (results are derived, never data). Exclusions here:
    /// `//` comment lines (Antinote rule) and the NAME side of a variable
    /// definition (body numbers count). nil when no numbers (fail closed).
    static func aggregate(_ op: Aggregate, overTextAbove text: String) -> Double? {
        guard let regex = aggregateNumberRegex else { return nil }
        var numbers: [Double] = []
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            var scanText = rawLine
            if variableDefinition(inLine: rawLine) != nil {
                // Body only — same slicing as variableDefinition: after the
                // first colon, before any "=" (a rendered-result tail).
                let norm = rawLine.replacingOccurrences(of: "：", with: ":")
                if let colon = norm.firstIndex(of: ":") {
                    var body = String(norm[norm.index(after: colon)...])
                    if let eq = body.firstIndex(of: "=") { body = String(body[..<eq]) }
                    scanText = body
                }
            }
            let ns = scanText as NSString
            let matches = regex.matches(
                in: scanText, options: [],
                range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let token = ns.substring(with: m.range)
                    .replacingOccurrences(of: ",", with: "")
                if let v = Double(token) { numbers.append(v) }
            }
        }
        guard !numbers.isEmpty else { return nil }
        let total = numbers.reduce(0, +)
        switch op {
        case .sum: return total
        case .avg: return total / Double(numbers.count)
        }
    }

    // MARK: Count (Antinote §5 count keyword — landing: "Count items,
    // lines, words, and reading ease")

    /// A line that IS the count trigger: exactly `count` / `カウント`
    /// (ASCII case-insensitive), same shape rules as aggregateKeyword —
    /// optional whitespace and/or one leading checkbox token, anything
    /// else = prose (fail closed: "count today" never triggers).
    static func isCountKeyword(inLineBeforeCaret rawLine: String) -> Bool {
        var s = rawLine.trimmingCharacters(in: .whitespaces)
        for token in ["[ ]", "[\u{2713}]"] where s.hasPrefix(token) {
            s = String(s.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        switch s.lowercased() {
        case "count", "カウント": return true
        default: return false
        }
    }

    struct CountSummary: Equatable {
        var lines: Int   // non-empty, non-// lines
        var words: Int   // CJK-aware, see wordCount
        var items: Int   // checkbox lines ([ ] / [✓], optional - / * bullet)
    }

    /// Counts over the note text ABOVE the trigger line. Same exclusion
    /// rules as aggregate(): the view passes text with .floteCalcResult
    /// runs already STRIPPED (results are derived, never data), and `//`
    /// comment lines are excluded from every count. nil when there are no
    /// countable lines (fail closed — "count=" in an empty note falls
    /// through as literal typing, mirroring sum/avg).
    /// Reading ease is DELIBERATELY not computed: Flesch-style scores are
    /// syllable-estimation over English text and meaningless for Japanese
    /// (spec §5 Flote mapping says switch JP to character counts — which
    /// is exactly what the CJK word proxy below is).
    static func countSummary(overTextAbove text: String) -> CountSummary? {
        var lines = 0, words = 0, items = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("//") { continue }
            lines += 1
            // Checkbox item: first token is [ ] or [✓], optionally behind
            // a - / * bullet (Flote's own auto-continued list form is
            // "- [ ] "). Marker tokens are stripped from the word scan —
            // "[", "]" glyphs are structure, not words.
            var body = trimmed
            for bullet in ["- ", "* "] where body.hasPrefix(bullet) {
                body = String(body.dropFirst(bullet.count))
                break
            }
            for token in ["[ ]", "[\u{2713}]"] where body.hasPrefix(token) {
                items += 1
                body = String(body.dropFirst(token.count))
                break
            }
            words += wordCount(inLine: body)
        }
        guard lines > 0 else { return nil }
        return CountSummary(lines: lines, words: words, items: items)
    }

    /// CJK-aware word counting. Japanese has no word spaces, so each
    /// Hiragana / Katakana / Han character counts as ONE word (the
    /// standard character proxy — documented deviation from Antinote's
    /// English-centric metric); every maximal run of other non-separator
    /// characters counts as one word ("今日はmeeting" = 3 + 1 = 4).
    /// Separators: whitespace + CJK/full-width punctuation (。、！？（）…).
    static func wordCount(inLine line: String) -> Int {
        var count = 0
        var inRun = false
        for s in line.unicodeScalars {
            if isCJKWordScalar(s) {
                if inRun { count += 1; inRun = false }
                count += 1
            } else if isWordSeparator(s) {
                if inRun { count += 1; inRun = false }
            } else {
                inRun = true
            }
        }
        if inRun { count += 1 }
        return count
    }

    private static func isCJKWordScalar(_ s: Unicode.Scalar) -> Bool {
        if s.value == 0x30FB { return false }   // ・ katakana middle dot = separator
        switch s.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana (incl. ー 0x30FC)
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF66...0xFF9F:   // halfwidth katakana
            return true
        default: return false
        }
    }

    private static func isWordSeparator(_ s: Unicode.Scalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(s) { return true }
        if s.value == 0x30FB { return true }    // ・
        switch s.value {
        case 0x3000...0x303F,   // CJK punctuation 。、「」…
             0xFF01...0xFF0F,   // full-width ！＂＃…／
             0xFF1A...0xFF20,   // full-width ：；＜…＠
             0xFF3B...0xFF40,   // full-width ［＼…｀
             0xFF5B...0xFF65:   // full-width ｛｜｝～ + halfwidth 。「」、
            return true
        default: return false
        }
    }

    /// The exact result STRING for a count line — the aggregate cascade
    /// formats Doubles; count is the one aggregate whose answer is text.
    /// "12行 / 84語 / 5項目" (JP) / "12 lines / 84 words / 5 items" (EN,
    /// singular-aware). Pure: the view passes the language flag.
    static func formatCount(_ c: CountSummary, japanese: Bool) -> String {
        if japanese {
            return "\(c.lines)行 / \(c.words)語 / \(c.items)項目"
        }
        func plural(_ n: Int, _ noun: String) -> String {
            "\(n) \(noun)\(n == 1 ? "" : "s")"
        }
        return "\(plural(c.lines, "line")) / \(plural(c.words, "word")) / \(plural(c.items, "item"))"
    }
}
// S7C-CALC-PURE-END

// S9-PASTE-PURE-BEGIN
/// §12 Formatting-strip on paste (Antinote parity): ⌘V inserts CLEAN text.
/// This is the pure String → String pipeline — Foundation-only, no AppKit,
/// no UserDefaults, no side effects — so the test harness can extract and
/// compile it standalone (same discipline as the calc region above).
///
/// The pipeline transforms ONLY the incoming pasted string. It never sees
/// note storage, so existing content (checkbox tokens, calc runs, links)
/// is structurally out of reach.
///
/// Always applied: line-ending normalization (CRLF / CR → LF — Windows and
/// classic-Mac clipboards otherwise leave invisible \r in the note).
/// Everything else is opt-in via Options:
/// - stripListMarkers: one leading bullet per line (`- ` `* ` `•` `・`
///   `1. ` `1) `). `-`/`*` and numbers require a following space so "-5",
///   "*emphasis*", "1.5kg" stay content. Markdown task lists keep their
///   box: "- [ ] milk" → "[ ] milk" (a native Flote checkbox).
/// - stripIndent: leading spaces / tabs / U+3000 (JP 字下げ) per line.
/// - collapseBlankLines: 3+ consecutive newlines → 2 (max one blank line);
///   whitespace-only lines count as blank.
/// - stripMarkdown: `#` headings, `>` quotes, **bold**, __bold__, *italic*,
///   _italic_, ~~strike~~, `code`, [text](url) and ![alt](url) → text.
///   DESIGN DECISION (Antinote's clean philosophy): the visible text is
///   kept and the URL is DROPPED — a pasted sticky should read like prose,
///   not like a link dump. Emphasis delimiters are flanking-checked so
///   arithmetic ("2*3*4") and snake_case never mangle.
enum FlotePasteStrip {

    /// Shipped defaults: indent + blank-line hygiene ON (they are what
    /// makes a paste look native in a sticky), list markers OFF (Flote's
    /// own checklists use `- [ ]` markers — stripping them by default
    /// would eat the user's structure), markdown OFF (conservative:
    /// rewriting content characters is opt-in).
    struct Options {
        var stripListMarkers = false
        var stripIndent = true
        var collapseBlankLines = true
        var stripMarkdown = false
    }

    static func process(_ text: String, options: Options = Options()) -> String {
        guard !text.isEmpty else { return text }
        var s = normalizedNewlines(text)
        if options.stripMarkdown { s = strippedMarkdown(s) }
        if options.stripListMarkers || options.stripIndent {
            s = s.components(separatedBy: "\n").map { line -> String in
                var l = line
                if options.stripListMarkers { l = strippedListMarker(l) }
                if options.stripIndent { l = String(splitIndent(l).rest) }
                return l
            }.joined(separator: "\n")
        }
        if options.collapseBlankLines { s = collapsedBlankLines(s) }
        return s
    }

    /// CRLF / lone CR → LF. Order matters: CRLF first, or "\r\n" would
    /// become "\n\n".
    static func normalizedNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Leading whitespace of one line: spaces, tabs, and U+3000 (全角
    /// space — the JP indentation character).
    static func splitIndent(_ line: String) -> (indent: Substring, rest: Substring) {
        var idx = line.startIndex
        while idx < line.endIndex {
            let c = line[idx]
            guard c == " " || c == "\t" || c == "\u{3000}" else { break }
            idx = line.index(after: idx)
        }
        return (line[..<idx], line[idx...])
    }

    /// Removes ONE leading list marker from the line (after any indent,
    /// which is preserved here — indent removal is stripIndent's job).
    static func strippedListMarker(_ line: String) -> String {
        let (indent, rest) = splitIndent(line)
        // "- " / "* ": the space is required — "-5 degrees" and
        // "*emphasis*" are content, not bullets.
        for bullet in ["- ", "* "] where rest.hasPrefix(bullet) {
            return String(indent) + String(rest.dropFirst(bullet.count))
        }
        // • / ・ are unambiguous bullet glyphs; the space after is
        // optional ("・項目" is the common JP form).
        if let first = rest.first, first == "•" || first == "・" {
            var body = rest.dropFirst()
            if body.first == " " { body = body.dropFirst() }
            return String(indent) + String(body)
        }
        // Numbered: ASCII digits + "." or ")" + a REQUIRED space —
        // "1.5kg" and "3.14" stay content. Digit run capped like
        // listPrefix(of:) so a pathological run can't scan forever.
        var digits = 0
        var scan = rest
        while let c = scan.first, ("0"..."9").contains(c), digits < 6 {
            digits += 1
            scan = scan.dropFirst()
        }
        if digits > 0, let mark = scan.first, mark == "." || mark == ")",
           scan.dropFirst().first == " " {
            return String(indent) + String(scan.dropFirst(2))
        }
        return line
    }

    /// 3+ consecutive newlines → exactly 2 (one blank line). Lines that
    /// contain only whitespace count as blank, so "a\n \t\n\nb" collapses
    /// even when stripIndent is off.
    static func collapsedBlankLines(_ s: String) -> String {
        regexReplace(s, "\n(?:[ \t\u{3000}]*\n){2,}", "\n\n")
    }

    /// Markdown syntax → visible text. Conservative flanking rules:
    /// - `*`: opening/closing must not touch a digit or another `*`, so
    ///   arithmetic ("2*3*4", "1200*3") is never treated as emphasis.
    /// - `_`: must not touch a word character — snake_case_names survive.
    /// - `**`/`__`/`~~`: content must start and end non-space.
    /// [text](url) / ![alt](url): keeps text, DROPS the url (documented
    /// decision — see the enum doc comment).
    static func strippedMarkdown(_ text: String) -> String {
        var s = text
        // ATX headings ("# Title") and blockquotes ("> quote"), per line.
        s = regexReplace(s, "(?m)^[ \t]{0,3}#{1,6}[ \t]+", "")
        s = regexReplace(s, "(?m)^[ \t]{0,3}>[ \t]?", "")
        // Images and links: ![alt](url) / [text](url) → alt / text.
        s = regexReplace(s, "!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1")
        // Bold / strikethrough (double delimiters) before single-char
        // emphasis, so "**x**" never half-matches as italic.
        s = regexReplace(s, "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*", "$1")
        s = regexReplace(s, "__(?=\\S)(.+?)(?<=\\S)__", "$1")
        s = regexReplace(s, "~~(?=\\S)(.+?)(?<=\\S)~~", "$1")
        // Italic. `.` does not match \n, so emphasis never spans lines.
        s = regexReplace(s, "(?<![0-9*])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![0-9*])", "$1")
        s = regexReplace(s, "(?<![\\w_])_(?=[^\\s_])(.+?)(?<=[^\\s_])_(?![\\w_])", "$1")
        // Inline code.
        s = regexReplace(s, "`([^`\n]+)`", "$1")
        return s
    }

    static func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
// S9-PASTE-PURE-END

/// UserDefaults-backed prefs for the §12 paste strip. Deliberately OUTSIDE
/// the pure region — the pipeline above must stay side-effect free for the
/// standalone test harness. Missing key = shipped default (same pattern as
/// floteInlineCalc).
enum FlotePastePrefs {
    static let stripAttributesKey = "flotePasteStripAttributes"
    static let stripListMarkersKey = "flotePasteStripListMarkers"
    static let stripIndentKey = "flotePasteStripIndent"
    static let collapseBlankLinesKey = "flotePasteCollapseBlankLines"
    static let stripMarkdownKey = "flotePasteStripMarkdown"

    static func bool(_ key: String, defaultOn: Bool) -> Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil else { return defaultOn }
        return d.bool(forKey: key)
    }

    /// Master switch (default ON): ⌘V inserts plain text that adopts the
    /// note's typingAttributes — no alien fonts/colors from web or Word.
    /// OFF = ⌘V behaves like stock NSTextView paste and the line cleanups
    /// below are inert (they only exist on the processed path).
    static var stripAttributesEnabled: Bool { bool(stripAttributesKey, defaultOn: true) }

    static var currentOptions: FlotePasteStrip.Options {
        FlotePasteStrip.Options(
            stripListMarkers: bool(stripListMarkersKey, defaultOn: false),
            stripIndent: bool(stripIndentKey, defaultOn: true),
            collapseBlankLines: bool(collapseBlankLinesKey, defaultOn: true),
            stripMarkdown: bool(stripMarkdownKey, defaultOn: false))
    }
}

// S7L-LINK-PURE-BEGIN
/// §10 Link auto-shrink (Antinote parity, landing: "Auto-shrink links with
/// smart endings — expand and edit with ease. ⌘⏎ to open."). This is the
/// PURE string layer — Foundation-only, no AppKit — extracted standalone by
/// the test harness (same discipline as the calc / paste regions).
///
/// The view layer replaces the VISIBLE text of a long bare-URL link run
/// with `domain/…/smart-ending` (e.g. `github.com/…/pull/1234`) while the
/// FULL url stays in the `.link` attribute and in `.floteShrunkLink` (the
/// exact original string, for caret-expansion and copy). Display shrinks;
/// data never does.
enum FloteLinkShrink {

    /// Visible URLs at or under this length stay as they are — short links
    /// are already readable (spec: "longer than ~40 chars").
    static let minShrinkLength = 40

    /// True when a link run's VISIBLE text is the URL itself (user-typed /
    /// pasted and auto-detected) rather than a custom label. The detector
    /// normalizes: it may add a scheme ("example.com/a" → link
    /// "http://example.com/a") or a trailing slash — those still count as
    /// bare. A real label ("release notes" → link https://…) never matches.
    static func isBareURLText(_ visible: String, linkURL: String) -> Bool {
        if visible == linkURL { return true }
        for scheme in ["https://", "http://"] {
            if linkURL == scheme + visible { return true }
            if linkURL == scheme + visible + "/" { return true }
        }
        if linkURL == visible + "/" { return true }
        return false
    }

    /// The smart-short display form for a bare URL, or nil = leave alone
    /// (too short, unparseable, non-http(s), or shrinking would not gain
    /// enough to be worth the indirection — fail closed, never guess).
    ///
    /// Form: `domain/…/ending` with the scheme and any leading `www.`
    /// stripped, query/fragment dropped. The ending is the LAST path
    /// segment; a purely numeric or ≤3-char tail is meaningless alone
    /// ("…/1234"), so its parent segment is included ("pull/1234" — the
    /// "smart" part). When nothing was actually elided the separator
    /// honestly degrades to a plain "/" ("github.com/pull/1234").
    /// Percent-encoding is displayed decoded (ja.wikipedia slugs read as
    /// 東京, not %E6%9D%B1…).
    static func smartShort(for urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > minShrinkLength, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let comps = URLComponents(string: withScheme),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var domain = comps.host, !domain.isEmpty else { return nil }
        if domain.hasPrefix("www.") { domain = String(domain.dropFirst(4)) }
        let segments = comps.path.split(separator: "/").map(String.init)
            .filter { !$0.isEmpty }
        let short: String
        if segments.isEmpty {
            // Domain + query/fragment only ("google.com/?q=…"): the domain
            // plus an honest elision mark.
            short = domain + "/…"
        } else {
            var consumed = 1
            var ending = segments[segments.count - 1]
            if segments.count >= 2,
               ending.allSatisfy({ $0.isNumber }) || ending.count <= 3 {
                ending = segments[segments.count - 2] + "/" + ending
                consumed = 2
            }
            // A single monster slug would defeat the shrink — cap it.
            if ending.count > 32 { ending = String(ending.prefix(31)) + "…" }
            short = segments.count > consumed
                ? domain + "/…/" + ending
                : domain + "/" + ending
        }
        // Only shrink when it actually buys readability.
        guard short.count + 8 <= trimmed.count else { return nil }
        return short
    }
}
// S7L-LINK-PURE-END

// S11-MD-PURE-BEGIN
/// §MD Invisible-markdown v1 (rival P1 — SideNotes/Noticky class, minimal
/// scope): PURE range finder — Foundation-only, no AppKit — extracted
/// standalone by the test harness (same discipline as the calc / paste /
/// link regions). Given ONE line of text it returns the markdown spans to
/// style: `#`/`##`/`###` headings, `**bold**`, `*italic*`, `` `code` ``.
///
/// v1 contract = style the CONTENT, DIM the syntax. Markers stay visible
/// (actual marker-hiding is a v2 with caret complexity). The view layer
/// applies fonts/colors; this layer only finds ranges — all in UTF-16
/// units of the line string (JP-safe: NSString indexing throughout).
///
/// Fail-closed rules (each one exists because of a real false-positive):
/// - Heading needs 1-3 `#` at column 0 AND a separator space AND non-blank
///   content ("#hashtag", "#### four", bare "#" never style).
/// - `*` runs of 3+ are inert (no ***nesting*** guesses in v1).
/// - Bold/italic content must not start/end with whitespace and must
///   contain at least one NON-ARITHMETIC char — digits, decimal/thousands
///   punctuation, whitespace and operator glyphs don't count, so
///   "2*3*4=", "2**3.5**4" and friends never turn into styling.
/// - Only ASCII `*` and `` ` `` are markers — JP ＊/｀ are prose.
/// - code > bold > italic: earlier kinds consume their whole span
///   (markers + content); later kinds never fire across consumed text
///   ("**a `b` c**" = code only — nesting is v2, not a guess).
/// - Unterminated markers never style ("**abc", "`x").
enum FloteMarkdown {

    enum SpanKind: Equatable {
        /// The `#`-run of a heading line (rendered dim, keeps heading font).
        case headingMarks(level: Int)
        /// Heading content after the separator (+3/+2/+1 pt, heavier).
        case headingText(level: Int)
        /// Inline marker chars to DIM: `**`, `*`, `` ` ``.
        case syntax
        case bold
        case italic
        case code
    }

    struct Span: Equatable {
        let kind: SpanKind
        let range: NSRange   // UTF-16 units within the line string
    }

    /// All markdown spans of one line, sorted by location. Spans never
    /// overlap. An empty result = plain prose line.
    static func spans(inLine line: String) -> [Span] {
        let ns = line as NSString
        let length = ns.length
        guard length > 0 else { return [] }
        var spans: [Span] = []
        var consumed = [Bool](repeating: false, count: length)

        func markConsumed(_ r: NSRange) {
            guard r.location >= 0, NSMaxRange(r) <= length else { return }
            for i in r.location..<NSMaxRange(r) { consumed[i] = true }
        }
        func intersectsConsumed(_ r: NSRange) -> Bool {
            guard r.location >= 0, NSMaxRange(r) <= length else { return true }
            for i in r.location..<NSMaxRange(r) where consumed[i] { return true }
            return false
        }
        func isWhitespace(_ i: Int) -> Bool {
            guard i >= 0, i < length,
                  let scalar = Unicode.Scalar(ns.character(at: i)) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        /// Arithmetic guard: at least one char an expression could not
        /// contain. (Kills "2*3*4", "2**3.5**4", "**1,234**"; a purely
        /// numeric "**42**" deliberately does NOT style — fail closed,
        /// arithmetic safety beats the rare bolded bare number.)
        let arithmeticChars = Set("0123456789.,+-*/%^()= \t×÷".utf16)
        func looksLikeProse(_ r: NSRange) -> Bool {
            for i in r.location..<NSMaxRange(r)
            where !arithmeticChars.contains(ns.character(at: i)) { return true }
            return false
        }

        // --- Heading: `#{1,3}` at column 0 + separator + non-blank content.
        let hash = UInt16(UInt8(ascii: "#"))
        var level = 0
        while level < length, ns.character(at: level) == hash { level += 1 }
        if level >= 1, level <= 3, level < length {
            let sep = ns.character(at: level)
            // ASCII space/tab or 全角 space (JP keyboards) — "#hashtag"
            // has no separator and never becomes a heading.
            if sep == 0x20 || sep == 0x09 || sep == 0x3000 {
                let content = NSRange(location: level + 1, length: length - level - 1)
                if content.length > 0,
                   !ns.substring(with: content)
                       .trimmingCharacters(in: .whitespaces).isEmpty {
                    spans.append(Span(kind: .headingMarks(level: level),
                                      range: NSRange(location: 0, length: level)))
                    spans.append(Span(kind: .headingText(level: level), range: content))
                    // Marks + separator are consumed; the content itself
                    // stays scannable for inline spans below.
                    markConsumed(NSRange(location: 0, length: level + 1))
                }
            }
        }

        // --- Inline pass A: `code` (highest precedence; digits allowed —
        // backticks are explicit, so `2*3` IS code).
        let backtick = UInt16(UInt8(ascii: "`"))
        var i = 0
        while i < length {
            guard ns.character(at: i) == backtick, !consumed[i] else { i += 1; continue }
            var j = i + 1
            while j < length, ns.character(at: j) != backtick { j += 1 }
            guard j < length else { break }   // unterminated: no fire
            let content = NSRange(location: i + 1, length: j - i - 1)
            if content.length > 0,
               !ns.substring(with: content)
                   .trimmingCharacters(in: .whitespaces).isEmpty,
               !intersectsConsumed(content) {
                spans.append(Span(kind: .syntax, range: NSRange(location: i, length: 1)))
                spans.append(Span(kind: .code, range: content))
                spans.append(Span(kind: .syntax, range: NSRange(location: j, length: 1)))
                markConsumed(NSRange(location: i, length: j - i + 1))
                i = j + 1
            } else {
                // Blank/consumed content: the closing tick may open the
                // next candidate.
                i = j
            }
        }

        // --- Delimiter runs of ASCII `*` (full-width ＊ is prose).
        let star = UInt16(UInt8(ascii: "*"))
        var doubles: [Int] = []   // location of each exactly-2 run
        var singles: [Int] = []   // location of each exactly-1 run
        i = 0
        while i < length {
            guard ns.character(at: i) == star, !consumed[i] else { i += 1; continue }
            var runEnd = i + 1
            while runEnd < length, ns.character(at: runEnd) == star,
                  !consumed[runEnd] { runEnd += 1 }
            switch runEnd - i {
            case 2: doubles.append(i)
            case 1: singles.append(i)
            default: break   // 3+ stars = inert (v1)
            }
            i = runEnd
        }

        // --- Inline pass B/C: pair consecutive delimiters left-to-right.
        func pair(_ delims: [Int], markerLen: Int, kind: SpanKind) {
            var idx = 0
            while idx + 1 < delims.count {
                let open = delims[idx]
                let close = delims[idx + 1]
                let content = NSRange(location: open + markerLen,
                                      length: close - open - markerLen)
                if content.length > 0,
                   !isWhitespace(content.location),
                   !isWhitespace(NSMaxRange(content) - 1),
                   looksLikeProse(content),
                   !intersectsConsumed(content) {
                    spans.append(Span(kind: .syntax,
                                      range: NSRange(location: open, length: markerLen)))
                    spans.append(Span(kind: kind, range: content))
                    spans.append(Span(kind: .syntax,
                                      range: NSRange(location: close, length: markerLen)))
                    markConsumed(NSRange(location: open,
                                         length: close + markerLen - open))
                    idx += 2
                } else {
                    idx += 1   // failed open: the close becomes the next open
                }
            }
        }
        pair(doubles, markerLen: 2, kind: .bold)
        pair(singles.filter { !consumed[$0] }, markerLen: 1, kind: .italic)

        return spans.sorted { $0.range.location < $1.range.location }
    }
}
// S11-MD-PURE-END

// S12-LIST-PURE-BEGIN
/// §1 keyword system + §6 list keyword (Antinote parity) — PURE core,
/// Foundation-only, extracted standalone by .harness/tests/s12-list-test.sh
/// together with the S10-TIMER-PURE region it references (the timer token
/// recognizer stays TimerEngine's single source of truth). Three concerns:
/// - keyword recognition: a note whose FIRST LINE is exactly `list` /
///   `リスト` is a checklist note; that token (and the timer/タイマー
///   token, whose behavior NoteView/TimerEngine already own) renders in
///   FloteInk.keyword via the S11 semantic pass.
/// - activation planning: given the whole note text, where "[ ] " must be
///   inserted so every plain content line below the keyword is an item.
///   Every skip rule fails CLOSED — skipping never destroys content,
///   inserting wrongly would.
/// - `/x` check-off parsing: the type-only gesture that flips the line's
///   unchecked box (§6: "行末に check trigger をタイプ").
enum FloteList {

    /// The literal prefix a planned insertion adds (the same plain-token
    /// form toggleCheckbox / listPrefix / FloteLayoutManager understand).
    static let checkboxPrefix = "[ ] "

    private static let uncheckedToken = "[ ]"
    private static let checkedToken = "[\u{2713}]"
    /// `[x]` counts as "already a checkbox" too — toggleCheckbox accepts
    /// it, so a plan must never double-prefix such a line.
    private static let legacyCheckedToken = "[x]"

    /// Line terminators lineRange(for:) recognizes: LF, CR, LS, PS.
    private static let terminators: Set<unichar> = [0x0A, 0x0D, 0x2028, 0x2029]

    // MARK: Keyword recognition

    /// First line == the list token: `list` (ASCII case-insensitive — the
    /// same leniency FloteTimer.parse applies, and the spec's own Flote
    /// mapping: Tom types JP/EN mixed, Antinote's case-sensitivity is a
    /// deliberate divergence) or `リスト`, surrounding whitespace ignored.
    /// STANDALONE only: prose that merely begins with the letters
    /// ("listen", "list today", "リスト化") must NOT flip the note into a
    /// mode — exact token or nothing (fail closed).
    static func isListKeyword(firstLine raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        return line.lowercased() == "list" || line == "リスト"
    }

    /// UTF-16 range (in the RAW first line's coordinates) of the keyword
    /// token to render in FloteInk.keyword, or nil = not a keyword line.
    /// list/リスト color as a whole trimmed token; timer lines (decided by
    /// FloteTimer.parse — the exact recognizer NoteView uses for the rail,
    /// so coloring can never disagree with the rail) color ONLY the token
    /// word: arguments and `: タイトル` stay body ink (§6 visuals).
    static func keywordTokenRange(inFirstLine raw: String) -> NSRange? {
        let ns = raw as NSString
        var start = 0
        while start < ns.length,
              let s = Unicode.Scalar(ns.character(at: start)),
              CharacterSet.whitespaces.contains(s) { start += 1 }
        if isListKeyword(firstLine: raw) {
            let token = raw.trimmingCharacters(in: .whitespaces) as NSString
            return token.length > 0
                ? NSRange(location: start, length: token.length) : nil
        }
        guard FloteTimer.parse(firstLine: raw) != nil else { return nil }
        let rest = ns.substring(from: start)
        if rest.lowercased().hasPrefix("timer") {
            return NSRange(location: start, length: 5)
        }
        if rest.hasPrefix("タイマー") {
            return NSRange(location: start, length: 4)
        }
        return nil
    }

    // MARK: Activation planning

    /// UTF-16 offsets (note coordinates, ASCENDING — apply back-to-front)
    /// where "[ ] " must be inserted. Empty when the first line is not the
    /// list token. Per line below the keyword line, the fail-closed skips:
    /// - blank / whitespace-only lines (spacing, not items),
    /// - `//` comments (§6 exclusion 3),
    /// - `#…` heading-ish lines (§6 excludes headings; ANY leading `#`
    ///   skips — deliberately broader than FloteMarkdown's strict heading
    ///   rule so a to-be-heading "#todo" line is never boxed),
    /// - lines already carrying a checkbox token ANYWHERE (the same
    ///   anywhere-in-line rule CheckboxSink / FloteLayoutManager use),
    /// - numbered-list lines ("1. x" — listPrefix has no numbered+box
    ///   compound form, so boxing one would break auto-continue),
    /// - the line containing `excludingOffset` (the caret's line: a line
    ///   still being typed commits when the caret leaves it, so "//…" can
    ///   be typed without a box racing the first "/").
    /// Bullet lines ("- x" / "* x") take the box AFTER the bullet — the
    /// `- [ ] ` compound form listPrefix already continues. Indented lines
    /// keep their indent (insertion lands after the leading spaces/tabs).
    static func plannedCheckboxInsertions(
        noteText: String, excludingLineAt excludingOffset: Int?
    ) -> [Int] {
        let ns = noteText as NSString
        guard ns.length > 0 else { return [] }
        let firstLineRange = ns.lineRange(for: NSRange(location: 0, length: 0))
        var firstEnd = NSMaxRange(firstLineRange)
        while firstEnd > firstLineRange.location,
              terminators.contains(ns.character(at: firstEnd - 1)) { firstEnd -= 1 }
        guard isListKeyword(firstLine: ns.substring(
            with: NSRange(location: 0, length: firstEnd))) else { return [] }

        var insertions: [Int] = []
        var location = NSMaxRange(firstLineRange)
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)

            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  terminators.contains(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
            let content = ns.substring(with: NSRange(
                location: lineRange.location, length: contentEnd - lineRange.location))
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("//") { continue }
            if trimmed.hasPrefix("#") { continue }
            if content.contains(uncheckedToken) || content.contains(checkedToken)
                || content.contains(legacyCheckedToken) { continue }
            // The caret's line: end-of-document caret belongs to the last
            // line even though NSLocationInRange excludes the max offset.
            if let ex = excludingOffset, ex >= lineRange.location,
               ex < NSMaxRange(lineRange)
                || (ex == ns.length && NSMaxRange(lineRange) == ns.length) {
                continue
            }
            var offset = lineRange.location
            while offset < contentEnd {
                let c = ns.character(at: offset)
                if c == 0x20 || c == 0x09 { offset += 1 } else { break }
            }
            let afterIndent = ns.substring(with: NSRange(
                location: offset, length: contentEnd - offset))
            if afterIndent.hasPrefix("- ") || afterIndent.hasPrefix("* ") {
                offset += 2
            } else if hasNumberedPrefix(afterIndent) {
                continue
            }
            insertions.append(offset)
        }
        return insertions
    }

    /// "N. " head (ASCII digits only, listPrefix's exact shape).
    private static func hasNumberedPrefix(_ s: String) -> Bool {
        var digits = 0
        var rest = Substring(s)
        while let c = rest.first, c.isASCII, c.isNumber, digits < 7 {
            digits += 1
            rest = rest.dropFirst()
        }
        return digits > 0 && rest.hasPrefix(". ")
    }

    // MARK: /x check-off (§6: type the trigger at line END)

    struct CheckOffEdit: Equatable {
        /// The unchecked "[ ]" token to flip, in the line's UTF-16 coords.
        let boxRange: NSRange
        /// The trailing "/x" tag — always the line's suffix.
        let tagRange: NSRange
    }

    /// `line` = the caret line INCLUDING the just-completed "/x" suffix.
    /// nil (fail closed) when: no "/x" suffix (mid-line /x never fires —
    /// the caller additionally requires the caret AT line end), the line
    /// has no checkbox token, its FIRST token is already checked (the same
    /// first-token rule CheckboxSink.firstTokenChecked applies), or the
    /// box does not precede the tag.
    static func checkOffEdit(inLine line: String) -> CheckOffEdit? {
        let ns = line as NSString
        guard ns.length >= 2, line.hasSuffix("/x") else { return nil }
        let tagRange = NSRange(location: ns.length - 2, length: 2)
        let unchecked = ns.range(of: uncheckedToken)
        guard unchecked.location != NSNotFound else { return nil }
        let checked = ns.range(of: checkedToken)
        if checked.location != NSNotFound, checked.location < unchecked.location {
            return nil
        }
        guard NSMaxRange(unchecked) <= tagRange.location else { return nil }
        return CheckOffEdit(boxRange: unchecked, tagRange: tagRange)
    }
}

/// Pure splice helpers for tagged-run exclusion (v56 audit fix: rendered
/// calc-result DIGITS leaking into a new "=" candidate scan — "2*3=6 4*5"
/// + "=" glued "6 4*5" into 320). The view layer resolves attribute runs;
/// these decide what text survives.
enum FloteRunSplice {

    /// `text` minus the given runs (local UTF-16 coords, ascending).
    /// Out-of-bounds / overlapping ranges are clamped defensively — a bad
    /// range can drop at most its own slice, never corrupt neighbors.
    static func excluding(_ runs: [NSRange], from text: String) -> String {
        splice(runs, from: text) { _ in "" }
    }

    /// Each run collapses to its "=" BOUNDARY instead of vanishing: a
    /// new-format result run ("=6") keeps its leading "=", a legacy run
    /// ("6", user's "=" still in surrounding text) contributes nothing.
    /// Either way the scan sees "expr= …" and a fresh candidate can never
    /// absorb rendered digits ("2*3=6 4*5" → "2*3= 4*5" → 20, not 320).
    static func collapsingToEquals(_ runs: [NSRange], from text: String) -> String {
        splice(runs, from: text) { $0.hasPrefix("=") ? "=" : "" }
    }

    private static func splice(
        _ runs: [NSRange], from text: String,
        replacement: (String) -> String
    ) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for run in runs {
            let start = max(cursor, min(run.location, ns.length))
            let end = max(start, min(NSMaxRange(run), ns.length))
            if start > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: start - cursor))
            }
            if end > start {
                out += replacement(ns.substring(
                    with: NSRange(location: start, length: end - start)))
            }
            cursor = end
        }
        if cursor < ns.length {
            out += ns.substring(from: cursor)
        }
        return out
    }
}
// S12-LIST-PURE-END

/// Detects clicks on `[ ]` / `[x]` checkbox patterns and toggles them
/// in-place. All other mouse events pass through to standard NSTextView.
final class FloteTextView: NSTextView {
    var noteID: UUID?

    /// This note's legacy hue for per-note theme-ink resolution (nil when
    /// the note is gone or the view is not yet wired).
    var legacyThemeRaw: String? {
        noteID.flatMap { NoteManager.shared.note(byID: $0)?.colorTheme.rawValue }
    }

    /// Right-click anywhere in the text: リマインド (line-scoped) + AI 変換 +
    /// 書き出し (note-scoped) on top of the standard text menu. These also
    /// live on the Organize pill / copy button, but the TEXT is where people
    /// actually right-click (Tom's dogfood 2026-07-11 found none of them).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let noteID, let storage = textStorage, storage.length > 0 else { return menu }
        let result = menu ?? NSMenu()
        var top: [NSMenuItem] = []

        // -- リマインド: the clicked line, unless it is a CHECKED box
        // (completed items don't ring). Plain lines qualify — "明日15時
        // ミーティング" is written as plain text, not a checkbox.
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = storage.string as NSString
        let safeIndex = max(0, min(index, text.length - 1))
        let lineRange = text.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = text.substring(with: lineRange)
        let itemText = Self.reminderItemText(fromLine: line)
        if CheckboxSink.firstTokenChecked(inLine: line) != true, !itemText.isEmpty {
            let sub = NSMenu()
            // S7-2 entity EDGE: when the item names a time ("明日9時 ゴミ出し",
            // "call Sarah friday 3pm"), Apple's date detector resolves it — that
            // exact moment becomes the FIRST suggestion, above the presets.
            if let detected = Self.detectedFutureDate(in: itemText) {
                let fmt = DateFormatter()
                fmt.locale = Locale.current
                fmt.setLocalizedDateFormatFromTemplate("Md HH:mm")
                let item = NSMenuItem(
                    title: L("この時刻に: ", "At this time: ") + fmt.string(from: detected),
                    action: #selector(scheduleReminder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ReminderRequest(
                    noteID: noteID, itemText: itemText, date: detected)
                sub.addItem(item)
                sub.addItem(NSMenuItem.separator())
            }
            for preset in ReminderService.Preset.allCases {
                let item = NSMenuItem(
                    title: preset.title, action: #selector(scheduleReminder(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = ReminderRequest(
                    noteID: noteID, itemText: itemText, date: preset.fireDate)
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: L("この項目をリマインド", "Remind me about this"), action: nil, keyEquivalent: "")
            parent.submenu = sub
            top.append(parent)
        }

        // -- AI 変換: same pipeline as the Organize-pill menu (NoteView owns
        // the content-protection rails; we only post the request).
        let verbSub = NSMenu()
        for verb in NoteVerb.allCases {
            let item = NSMenuItem(
                title: verb.menuLabel, action: #selector(runVerbFromMenu(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = EditorNoteAction(noteID: noteID, payload: verb.rawValue)
            verbSub.addItem(item)
        }
        let verbParent = NSMenuItem(title: L("AI 変換", "AI transform"), action: nil, keyEquivalent: "")
        verbParent.submenu = verbSub
        top.append(verbParent)

        // -- 書き出し / コピー
        let exportSub = NSMenu()
        let exportEntries: [(String, String)] = [
            (L("Markdown をコピー", "Copy as Markdown"), "copy-md"),
            (L("TXT に書き出し", "Export as TXT"), "txt"),
            (L("Markdown に書き出し", "Export as Markdown"), "markdown"),
            (L("PDF に書き出し", "Export as PDF"), "pdf")
        ]
        for (title, format) in exportEntries {
            let item = NSMenuItem(
                title: title, action: #selector(exportFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = EditorNoteAction(noteID: noteID, payload: format)
            exportSub.addItem(item)
            if format == "copy-md" { exportSub.addItem(NSMenuItem.separator()) }
        }
        let exportParent = NSMenuItem(title: L("書き出し", "Export"), action: nil, keyEquivalent: "")
        exportParent.submenu = exportSub
        top.append(exportParent)

        // -- S16 文字色: theme ink + six fixed inks + カスタム (NSColorPanel).
        // Every pick rides the coordinator's standard undo-able command
        // path — apply(command:) wraps the attribute edit in
        // shouldChangeText/didChangeText exactly like the bold toggle, and
        // .textColor drops the S11 semantic marker so the user's pick
        // becomes the pass's new "original". テーマの文字色 = the explicit
        // color REMOVED (.removeTextColor): the run follows theme switches
        // again instead of baking today's ink. Selection gets the edit; an
        // empty selection arms typingAttributes — both handled by apply().
        let colorSub = NSMenu()
        let themeInkItem = NSMenuItem(
            title: L("テーマの文字色", "Theme ink"),
            action: #selector(applyTextColorFromMenu(_:)), keyEquivalent: "")
        themeInkItem.target = self
        themeInkItem.image = Self.colorSwatch(FloteInk.text(legacyTheme: legacyThemeRaw))
        colorSub.addItem(themeInkItem) // representedObject nil = remove
        colorSub.addItem(NSMenuItem.separator())
        for (name, color) in Self.textColorPresets() {
            let item = NSMenuItem(
                title: name, action: #selector(applyTextColorFromMenu(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.image = Self.colorSwatch(color)
            colorSub.addItem(item)
        }
        colorSub.addItem(NSMenuItem.separator())
        let customColorItem = NSMenuItem(
            title: L("カスタム…", "Custom…"),
            action: #selector(pickCustomTextColor(_:)), keyEquivalent: "")
        customColorItem.target = self
        colorSub.addItem(customColorItem)
        let colorParent = NSMenuItem(
            title: L("文字色", "Text color"), action: nil, keyEquivalent: "")
        colorParent.submenu = colorSub
        top.append(colorParent)

        for (i, item) in top.enumerated() { result.insertItem(item, at: i) }
        result.insertItem(NSMenuItem.separator(), at: top.count)
        return result
    }

    /// S16: the six fixed emphasis inks. System catalog colors adapt to
    /// light/dark automatically and archive/unarchive through
    /// RichTextStorage like any NSColor. Built per-call (not a static let)
    /// so L() reflects the current locale without isolation gymnastics.
    private static func textColorPresets() -> [(String, NSColor)] {
        [
            (L("レッド", "Red"), .systemRed),
            (L("ブルー", "Blue"), .systemBlue),
            (L("オレンジ", "Orange"), .systemOrange),
            (L("グリーン", "Green"), .systemGreen),
            (L("パープル", "Purple"), .systemPurple),
            (L("グレー", "Gray"), .systemGray),
        ]
    }

    /// 14×14 filled circle — the submenu item's color preview.
    private static func colorSwatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    @objc private func applyTextColorFromMenu(_ sender: NSMenuItem) {
        guard let coordinator = delegate as? RichTextEditor.Coordinator else { return }
        if let color = sender.representedObject as? NSColor {
            coordinator.apply(command: .textColor(color))
        } else {
            coordinator.apply(command: .removeTextColor)
        }
    }

    /// カスタム…: the shared NSColorPanel targets THIS view; every pick
    /// applies through the same undo-able path (one undo step per pick).
    /// The panel taking key does not disturb the note's selection —
    /// apply() reads selectedRange() as-is.
    @objc private func pickCustomTextColor(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(customTextColorPicked(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customTextColorPicked(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel else { return }
        (delegate as? RichTextEditor.Coordinator)?.apply(command: .textColor(panel.color))
    }

    @objc private func runVerbFromMenu(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? EditorNoteAction else { return }
        NotificationCenter.default.post(
            name: .floteRunVerbFromEditor, object: nil,
            userInfo: ["noteID": req.noteID, "verb": req.payload])
    }

    @objc private func exportFromMenu(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? EditorNoteAction else { return }
        NotificationCenter.default.post(
            name: .floteExportFromEditor, object: nil,
            userInfo: ["noteID": req.noteID, "format": req.payload])
    }

    /// representedObject carrier for context-menu → NoteView requests.
    private final class EditorNoteAction: NSObject {
        let noteID: UUID
        let payload: String
        init(noteID: UUID, payload: String) {
            self.noteID = noteID
            self.payload = payload
        }
    }

    /// First FUTURE date expression in the item, via NSDataDetector (the
    /// same engine Mail/Notes use — handles 明日/金曜15時/7/15/tomorrow 3pm).
    /// Date-only matches ("明日") resolve to noon-ish by the detector; past
    /// resolutions are ignored rather than guessed forward.
    private static func detectedFutureDate(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let now = Date()
        for match in detector.matches(in: text, options: [], range: range) {
            if let date = match.date, date > now.addingTimeInterval(60) {
                return date
            }
        }
        return nil
    }

    /// The reminder body = the line minus its leading checkbox token.
    private static func reminderItemText(fromLine line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["[ ]", "[\u{2713}]"] where s.hasPrefix(token) {
            s = String(s.dropFirst(token.count))
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private final class ReminderRequest: NSObject {
        let noteID: UUID
        let itemText: String
        let date: Date
        init(noteID: UUID, itemText: String, date: Date) {
            self.noteID = noteID
            self.itemText = itemText
            self.date = date
        }
    }

    @objc private func scheduleReminder(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? ReminderRequest else { return }
        let title = NoteManager.shared.note(byID: req.noteID)?.lockedSafeTitle
        ReminderService.schedule(
            noteID: req.noteID, noteTitle: title,
            itemText: req.itemText, at: req.date
        ) { error in
            if let error {
                NSLog("[Flote] Reminder: %@", error)
                NotificationCenter.default.post(
                    name: .floteTransientError, object: nil,
                    userInfo: ["noteID": req.noteID, "message": error])
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        // Antinote parity (their theme-maker bundle: answers are
        // click-to-copy): clicking a calc-result run copies the bare value.
        // Haptic = the only feedback; the caret still lands (super runs) so
        // text editing is never hijacked.
        if let storage = textStorage, index < storage.length,
           storage.attribute(.floteCalcResult, at: index, effectiveRange: nil) != nil {
            var runRange = NSRange()
            _ = storage.attribute(
                .floteCalcResult, at: index,
                longestEffectiveRange: &runRange,
                in: NSRange(location: 0, length: storage.length))
            var value = (storage.string as NSString).substring(with: runRange)
            if value.hasPrefix("=") { value.removeFirst() }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(value.trimmingCharacters(in: .whitespaces), forType: .string)
            NSHapticFeedbackManager.defaultPerformer.perform(
                .generic, performanceTime: .now)
        }
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
            // S6c: a toggle that leaves the line completed sinks it to the
            // bottom shortly after (the user sees the circle fill first).
            scheduleSinkIfNeeded(afterToggleAt: index)
            // S6 reminders: a completed item should not ring.
            cancelReminderIfCompleted(afterToggleAt: index)
            return
        }
        super.mouseDown(with: event)
    }

    /// After a toggle, if the clicked line's first token is now CHECKED,
    /// cancel any pending reminder for that item (same-length replacement,
    /// so `index` is still valid post-toggle).
    private func cancelReminderIfCompleted(afterToggleAt index: Int) {
        guard let noteID, let storage = textStorage else { return }
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        let safeIndex = max(0, min(index, text.length - 1))
        let lineRange = text.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = text.substring(with: lineRange)
        guard CheckboxSink.firstTokenChecked(inLine: line) == true else { return }
        let itemText = Self.reminderItemText(fromLine: line)
        guard !itemText.isEmpty else { return }
        ReminderService.cancel(noteID: noteID, itemText: itemText)
    }

    // MARK: - S6c: sink-completed scheduling

    /// Pending sink work. Every new toggle cancels it first, so rapid
    /// toggling coalesces into ONE sink after the last click settles.
    private var pendingSink: DispatchWorkItem?

    /// Schedule the Things-style sink ~0.6s after a toggle that left the
    /// clicked line COMPLETED. Unchecking never re-floats the line
    /// (standard Things behavior) — it only cancels a pending sink.
    /// All checkbox token replacements are same-length (3 UTF-16 units), so
    /// `index` is still valid in the post-toggle string.
    private func scheduleSinkIfNeeded(afterToggleAt index: Int) {
        pendingSink?.cancel()
        pendingSink = nil
        guard NoteManager.sinkCompletedEnabled,
              let noteID,
              let storage = textStorage else { return }
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        let safe = min(max(0, index), text.length - 1)
        let line = text.substring(with: text.lineRange(for: NSRange(location: safe, length: 0)))
        guard CheckboxSink.firstTokenChecked(inLine: line) == true else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSink = nil
            // IME guard: never reorder storage mid-composition — the reload
            // would destroy the marked range and corrupt Japanese input.
            guard !self.hasMarkedText() else { return }
            NoteManager.shared.sinkCompletedLines(id: noteID, undoManager: self.undoManager)
        }
        pendingSink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
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

    // MARK: - Typing niceties (S6a)
    //
    // Auto-continue lists on Return, Tab/Shift-Tab indent at line start, and
    // ⌘B/I/U key equivalents. Discipline shared by all three:
    // - NEVER fire while IME composition is active (hasMarkedText()) — a
    //   structural edit inside a marked range corrupts Japanese input, the
    //   same guard FloteLayoutManager applies to its temporary attributes.
    // - Storage stays plain `[ ]` / `[✓]` tokens; every edit goes through
    //   the normal text-change path (insertText, or shouldChangeText →
    //   replaceCharacters → didChangeText) so undo registration,
    //   FloteLayoutManager restyle (processEditing), and Coordinator
    //   persistence (textDidChange) all fire exactly as for hand typing.

    /// Line terminators lineRange(for:) recognizes: LF, CR, LS, PS.
    private static let lineTerminators: Set<unichar> = [0x0A, 0x0D, 0x2028, 0x2029]

    /// Parses a list prefix at the head of `line` (one line, no trailing
    /// newline): leading spaces/tabs + one of `- ` / `* ` (optionally
    /// compounded with a checkbox, `- [ ] `) / `[ ] ` / `[✓] ` / `N. `.
    /// Returns the literal prefix and the prefix the NEXT line should start
    /// with (checked continues as UNchecked; numbered increments).
    static func listPrefix(of line: String) -> (prefix: String, continuation: String)? {
        var rest = Substring(line)
        var indent = ""
        while let c = rest.first, c == " " || c == "\t" {
            indent.append(c)
            rest = rest.dropFirst()
        }
        let boxes = [("[ ] ", "[ ] "), ("[\u{2713}] ", "[ ] ")]
        for bullet in ["- ", "* "] {
            guard rest.hasPrefix(bullet) else { continue }
            let afterBullet = rest.dropFirst(bullet.count)
            for (box, next) in boxes where afterBullet.hasPrefix(box) {
                return (indent + bullet + box, indent + bullet + next)
            }
            return (indent + bullet, indent + bullet)
        }
        for (box, next) in boxes where rest.hasPrefix(box) {
            return (indent + box, indent + next)
        }
        // Numbered list: ASCII digits only ("１." must not parse), capped so
        // a pathological digit run can't build an absurd prefix.
        var digits = ""
        var scan = rest
        while let c = scan.first, ("0"..."9").contains(c), digits.count < 6 {
            digits.append(c)
            scan = scan.dropFirst()
        }
        if !digits.isEmpty, scan.hasPrefix(". "), let n = Int(digits) {
            return (indent + digits + ". ", indent + "\(n + 1). ")
        }
        return nil
    }

    /// The caret's line, split into (full line range incl. terminator,
    /// content range excl. terminator). Nil when there is no zero-length
    /// caret (range selections keep standard behavior).
    private func caretLine() -> (caret: Int, lineRange: NSRange, contentRange: NSRange, line: String)? {
        let sel = selectedRange()
        guard sel.length == 0, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        guard sel.location <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: sel.location, length: 0))
        var contentRange = lineRange
        while contentRange.length > 0,
              Self.lineTerminators.contains(text.character(at: NSMaxRange(contentRange) - 1)) {
            contentRange.length -= 1
        }
        return (sel.location, lineRange, contentRange, text.substring(with: contentRange))
    }

    /// S7-5 v2 (Antinote-quality pass, Tom 2026-07-11): the result is
    /// rendered in the theme ACCENT color and tagged with a private
    /// attribute, so it reads as a computed value, not typed text — and
    /// didChangeText can re-evaluate it live when the expression is edited.
    /// Only fires outside IME composition, only when the pref allows, and
    /// only when the line tail parses COMPLETELY (fail closed — prose "A="
    /// falls through untouched). The insert rides the normal typing path,
    /// so one ⌘Z removes it.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // A char typed right after (or inside) a result run must NEVER
        // inherit the calc marker — the live re-evaluator would treat it as
        // stale result text and overwrite it (content protection).
        if typingAttributes[.floteCalcResult] != nil {
            var attrs = typingAttributes
            attrs.removeValue(forKey: .floteCalcResult)
            attrs[.foregroundColor] = FloteInk.text(legacyTheme: legacyThemeRaw)
            typingAttributes = attrs
        }
        // Same discipline for link runs (S7L): a char typed at the edge of
        // a (shrunk) link must never inherit .floteShrunkLink / .link — the
        // display pass would otherwise treat the user's fresh text as part
        // of the shrunk run and rewrite it (content protection).
        if typingAttributes[.floteShrunkLink] != nil || typingAttributes[.link] != nil {
            var attrs = typingAttributes
            attrs.removeValue(forKey: .floteShrunkLink)
            attrs.removeValue(forKey: .link)
            typingAttributes = attrs
        }
        // S12 §6: "/x" typed at the END of a checkbox line checks it off.
        // The line already ends with "/" (the tag's first half); the "x"
        // completes the gesture — the tag never lands as text: the "/" is
        // removed and the line's unchecked box flips, both through the
        // normal shouldChangeText → didChangeText path (one ⌘Z restores
        // both, and the same completion side effects fire as for a checkbox
        // CLICK). Fail closed to a literal "x": IME composition, range
        // selections, a caret not at line end (mid-line /x never fires),
        // boxless lines and already-checked lines all fall through.
        if let typed = string as? String, typed == "x",
           !hasMarkedText(),
           replacementRange.location == NSNotFound
               || replacementRange == selectedRange(),
           let storage = textStorage,
           let (caret, _, contentRange, line) = caretLine(),
           caret == NSMaxRange(contentRange),
           let edit = FloteList.checkOffEdit(inLine: line + "x") {
            // Candidate coords = line + "x", so tagRange.location is the
            // "/" in the REAL line; the box precedes it, unaffected by the
            // slash removal below.
            let slashRange = NSRange(
                location: contentRange.location + edit.tagRange.location, length: 1)
            let boxRange = NSRange(
                location: contentRange.location + edit.boxRange.location,
                length: edit.boxRange.length)
            if shouldChangeText(in: slashRange, replacementString: "") {
                storage.replaceCharacters(in: slashRange, with: "")
                didChangeText()
                if shouldChangeText(in: boxRange, replacementString: "[\u{2713}]") {
                    storage.replaceCharacters(in: boxRange, with: "[\u{2713}]")
                    didChangeText()
                }
                // Exactly the click path's completion behavior (S6c/S6):
                // sink-on-complete + reminder cancellation.
                scheduleSinkIfNeeded(afterToggleAt: boxRange.location)
                cancelReminderIfCompleted(afterToggleAt: boxRange.location)
                return
            }
        }
        if let typed = string as? String, typed == "=",
           !hasMarkedText(),
           UserDefaults.standard.object(forKey: "floteInlineCalc") == nil
               || UserDefaults.standard.bool(forKey: "floteInlineCalc"),
           let storage = textStorage {
            let caret = selectedRange().location
            let text = storage.string as NSString
            if caret > 0, caret <= text.length {
                let lineRange = text.lineRange(for: NSRange(location: caret - 1, length: 0))
                // v56 audit fix: rendered result runs collapse to their "="
                // boundary before the candidate scan — their DIGITS are
                // derived display, not typed math ("2*3=6 4*5" + "=" must
                // scan "2*3= 4*5" and yield 20, never glue "6 4*5" → 320).
                let upToCaret = calcScanText(
                    in: NSRange(location: lineRange.location,
                                length: caret - lineRange.location))
                // Reactive variables: substitute note-wide definitions
                // ("幅 : 58" → 幅*2= …) before the candidate scan.
                let vars = FloteCalc.variables(inText: storage.string)
                let substituted = FloteCalc.substitute(variables: vars, in: upToCaret)
                var result: String? = nil
                if let expr = FloteCalc.expressionCandidate(inLineBeforeCaret: substituted),
                   let value = FloteCalc.evaluate(expr) {
                    result = FloteCalc.formatAnswer(value)
                } else if let converted = FloteCalc.conversionResult(
                    inLineBeforeCaret: upToCaret) {
                    // Unit conversion ("58cm to in="). RAW line, never the
                    // substituted one — a variable named like a unit must
                    // not corrupt the request. Runs only when the
                    // expression path failed: conversions never combine
                    // with arithmetic (Antinote limitation, kept).
                    result = converted
                } else if FloteCalc.isCurrencyRequest(
                    inLineBeforeCaret: upToCaret) {
                    // Currency + crypto ("10 USD to JPY=", "$10 to 円=",
                    // "$10=", "10 USD=", "USD to JPY="). RAW line, after
                    // the physical-unit path failed. The candidate check
                    // runs FIRST so the rates lookup (which may kick a
                    // background refresh) only happens on lines that
                    // actually ask for currency. No usable rates (never
                    // fetched / > 7d stale) = nil = the "=" falls through
                    // as literal typing (fail closed). No-target amounts
                    // convert to the other side of the floteCurrencyPair
                    // preference (default USD-JPY; Settings UI deferred).
                    result = FloteCalc.currencyResult(
                        inLineBeforeCaret: upToCaret,
                        rates: RatesService.shared.usableRates(),
                        pair: UserDefaults.standard.string(
                            forKey: FloteCalc.currencyPairDefaultsKey))
                } else if let op = FloteCalc.aggregateKeyword(inLineBeforeCaret: upToCaret),
                          let value = FloteCalc.aggregate(
                            op,
                            overTextAbove: plainTextExcludingCalcResults(
                                upTo: lineRange.location)) {
                    // sum= / avg= / 合計= / 平均= over the note text ABOVE
                    // this line, rendered results excluded.
                    result = FloteCalc.formatAnswer(value)
                } else if FloteCalc.isCountKeyword(inLineBeforeCaret: upToCaret),
                          let summary = FloteCalc.countSummary(
                            overTextAbove: plainTextExcludingCalcResults(
                                upTo: lineRange.location)) {
                    // count= / カウント= — the one aggregate whose answer is
                    // a preformatted STRING, not a Double (§5, landing:
                    // "Count items, lines, words, and reading ease" —
                    // reading ease deliberately skipped, see countSummary).
                    result = FloteCalc.formatCount(
                        summary, japanese: L("ja", "en") == "ja")
                }
                if let result {
                    // Antinote's real rendering (recovered from their
                    // theme-maker bundle): the "=" is part of the colored
                    // answer, so the whole "=7242" run is marked + accent.
                    var resultAttrs = typingAttributes
                    resultAttrs[.floteCalcResult] = true
                    resultAttrs[.foregroundColor] = FloteInk.calcAnswer(legacyTheme: legacyThemeRaw)
                    let piece = NSAttributedString(
                        string: "=" + result, attributes: resultAttrs)
                    super.insertText(piece, replacementRange: replacementRange)
                    return
                }
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Live re-evaluation (Antinote reactivity): any edit recomputes every
    /// calc result in the note — so editing "幅 : 58" updates each line
    /// that uses 幅, and a result's number is never stale. Breaking an
    /// expression removes its result (fail closed, no guesses). Only runs
    /// tagged .floteCalcResult are ever touched — user text is structurally
    /// out of reach (content protection).
    override func didChangeText() {
        super.didChangeText()
        recalculateCalcResults()
        // S7L: shrink/expand link display after every text change. Mutually
        // exclusive with the calc pass (each guards on the other's flag) so
        // neither can shift ranges the other captured mid-iteration.
        adjustLinkDisplay()
        // S12: list-mode checkbox prefixes — character-mutating, so it runs
        // with the other mutating passes, before the attribute-only S11.
        applyListModePrefixes()
        // S11: semantic styling runs LAST — it styles the SETTLED document
        // (post-recalc, post-link-display) and, being attribute-only, can
        // never shift the ranges the character-mutating passes captured.
        // Recursive didChangeText calls from those passes skip it via their
        // flags; the outermost call lands here with both flags cleared.
        runSemanticStylingPass()
    }

    /// Live re-evaluation body — see the comment on didChangeText above.
    private func recalculateCalcResults() {
        guard !isRecalculatingResult, !isAdjustingLinkDisplay, !hasMarkedText(),
              let storage = textStorage, storage.length > 0 else { return }
        // v56 audit fix: never fight undo/redo replay (the same guard
        // adjustLinkDisplay carries) — rewriting a run mid-replay would
        // corrupt the exact states the user is walking back through.
        if let um = undoManager, um.isUndoing || um.isRedoing { return }

        // All marked runs, back-to-front so replacements don't shift the
        // ranges still pending.
        var runs: [NSRange] = []
        var cursor = 0
        while cursor < storage.length {
            var effective = NSRange()
            let attr = storage.attribute(
                .floteCalcResult, at: cursor,
                longestEffectiveRange: &effective,
                in: NSRange(location: 0, length: storage.length))
            if attr != nil { runs.append(effective) }
            cursor = NSMaxRange(effective)
        }
        guard !runs.isEmpty else { return }

        let vars = FloteCalc.variables(inText: storage.string)
        isRecalculatingResult = true
        defer { isRecalculatingResult = false }

        for runRange in runs.reversed() {
            let text = storage.string as NSString
            let lineRange = text.lineRange(for: NSRange(location: runRange.location, length: 0))
            // The text before the run must end with "=" — its prefix is the
            // expression. Anything else means the line was restructured; the
            // orphaned result is removed rather than left lying.
            let prefixRange = NSRange(
                location: lineRange.location,
                length: runRange.location - lineRange.location)
            // v56 audit fix: a multi-run line's prefix contains the EARLIER
            // runs — collapse them to their "=" boundary so recomputing run
            // 2 of "2*3=6 4*5=20" scans "2*3= 4*5", never "2*3=6 4*5".
            let prefix = calcScanText(in: prefixRange)
            let runText = text.substring(with: runRange)
            // New-format runs carry their own leading "=" (Antinote's real
            // rendering: the whole "=N" is the colored answer). Legacy runs
            // (persisted before v47) left the "=" in user text. Support both.
            let runHasEquals = runText.hasPrefix("=")
            let exprPrefix: String? = runHasEquals
                ? prefix
                : (prefix.hasSuffix("=") ? String(prefix.dropLast()) : nil)
            var replacement: NSAttributedString? = nil   // nil = delete the run
            if let exprPrefix {
                let substituted = FloteCalc.substitute(variables: vars, in: exprPrefix)
                // Same three-way cascade as insertText: expression →
                // conversion (raw prefix) → aggregate. Whichever parses
                // recomputes; none parsing = orphaned result, deleted.
                var formatted: String? = nil
                if let expr = FloteCalc.expressionCandidate(inLineBeforeCaret: substituted),
                   let value = FloteCalc.evaluate(expr) {
                    formatted = FloteCalc.formatAnswer(value)
                } else if let converted = FloteCalc.conversionResult(
                    inLineBeforeCaret: exprPrefix) {
                    formatted = converted
                } else if FloteCalc.isCurrencyRequest(
                    inLineBeforeCaret: exprPrefix) {
                    // Currency line (all three shapes: explicit target /
                    // no-target amount / rate-only). With usable rates it
                    // recomputes like any other result; with NO usable
                    // rates (never fetched / rates just crossed 7d) the
                    // existing rendered result is LEFT AS-IS instead of
                    // deleted — a network condition must never destroy
                    // visible note content (content-protection principle).
                    // The run still dies the moment the line stops being a
                    // currency request.
                    guard let converted = FloteCalc.currencyResult(
                        inLineBeforeCaret: exprPrefix,
                        rates: RatesService.shared.usableRates(),
                        pair: UserDefaults.standard.string(
                            forKey: FloteCalc.currencyPairDefaultsKey))
                    else { continue }
                    formatted = converted
                } else if let op = FloteCalc.aggregateKeyword(inLineBeforeCaret: exprPrefix),
                          let value = FloteCalc.aggregate(
                            op,
                            overTextAbove: plainTextExcludingCalcResults(
                                upTo: lineRange.location)) {
                    formatted = FloteCalc.formatAnswer(value)
                } else if FloteCalc.isCountKeyword(inLineBeforeCaret: exprPrefix),
                          let summary = FloteCalc.countSummary(
                            overTextAbove: plainTextExcludingCalcResults(
                                upTo: lineRange.location)) {
                    // Live count: adding/removing lines above updates the
                    // rendered "N行 / N語 / N項目" run like any calc result.
                    formatted = FloteCalc.formatCount(
                        summary, japanese: L("ja", "en") == "ja")
                }
                if let formatted {
                    let target = runHasEquals ? "=" + formatted : formatted
                    if runText == target { continue }  // current
                    var attrs = storage.attributes(at: runRange.location, effectiveRange: nil)
                    attrs[.foregroundColor] = FloteInk.calcAnswer(legacyTheme: legacyThemeRaw)
                    replacement = NSAttributedString(string: target, attributes: attrs)
                }
            }
            let newText = replacement?.string ?? ""
            guard shouldChangeText(in: runRange, replacementString: newText) else { continue }
            if let replacement {
                storage.replaceCharacters(in: runRange, with: replacement)
            } else {
                storage.deleteCharacters(in: runRange)
            }
            didChangeText()
        }
    }
    private var isRecalculatingResult = false

    /// .floteCalcResult run ranges intersecting `bounds`, clipped to it and
    /// rebased to LOCAL coordinates (for the pure splice helpers).
    private func calcResultRuns(in bounds: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        var runs: [NSRange] = []
        storage.enumerateAttribute(.floteCalcResult, in: bounds, options: []) { v, r, _ in
            if v != nil {
                runs.append(NSRange(location: r.location - bounds.location,
                                    length: r.length))
            }
        }
        return runs
    }

    /// Plain text of the storage BEFORE `location`, with every
    /// .floteCalcResult run removed — aggregate input (sum=/avg=) must
    /// never count rendered results, only what the user actually wrote
    /// (results are derived, not data). Read-only walk: never mutates.
    private func plainTextExcludingCalcResults(upTo location: Int) -> String {
        guard let storage = textStorage else { return "" }
        let bounds = NSRange(location: 0, length: max(0, min(location, storage.length)))
        guard bounds.length > 0 else { return "" }
        let text = (storage.string as NSString).substring(with: bounds)
        return FloteRunSplice.excluding(calcResultRuns(in: bounds), from: text)
    }

    /// The line slice the "=" candidate scan (and a recalc's prefix) reads:
    /// every rendered .floteCalcResult run collapsed to its "=" boundary —
    /// see FloteRunSplice.collapsingToEquals for why "=" survives (v56
    /// audit fix: result digits must never become part of a new candidate).
    private func calcScanText(in bounds: NSRange) -> String {
        guard let storage = textStorage else { return "" }
        let safe = NSIntersectionRange(
            bounds, NSRange(location: 0, length: storage.length))
        guard safe.length > 0 else { return "" }
        let text = (storage.string as NSString).substring(with: safe)
        let runs = calcResultRuns(in: safe)
        return runs.isEmpty ? text : FloteRunSplice.collapsingToEquals(runs, from: text)
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(),
              let (caret, _, contentRange, line) = caretLine() else {
            return super.insertNewline(sender)
        }
        guard let (prefix, continuation) = Self.listPrefix(of: line) else {
            // S12 list mode: Return at the END of a plain non-empty line
            // (including the keyword line itself) starts the next ITEM —
            // the fresh line auto-prefixes "[ ] " through the normal typing
            // path (one ⌘Z removes prefix + newline together). Mid-line
            // splits and empty lines keep standard Return (fail closed).
            if isListModeActive, caret == NSMaxRange(contentRange),
               !line.trimmingCharacters(in: .whitespaces).isEmpty {
                insertText("\n" + FloteList.checkboxPrefix,
                           replacementRange: selectedRange())
                return
            }
            return super.insertNewline(sender)
        }
        let prefixLen = (prefix as NSString).length
        // Returns with the caret INSIDE the prefix behave standard (they
        // push the item down, they don't continue it).
        guard caret - contentRange.location >= prefixLen else {
            return super.insertNewline(sender)
        }
        // Empty item (prefix + at most whitespace): Return clears the
        // prefix and ends the list — standard escape hatch.
        let afterPrefix = (line as NSString).substring(from: prefixLen)
        if afterPrefix.trimmingCharacters(in: .whitespaces).isEmpty {
            if shouldChangeText(in: contentRange, replacementString: "") {
                textStorage?.replaceCharacters(in: contentRange, with: "")
                didChangeText()
                setSelectedRange(NSRange(location: contentRange.location, length: 0))
            }
            return
        }
        // Full normal typing path: undo, restyle, persistence, panel resize.
        insertText("\n" + continuation, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText(), indentCaretListLine(outdent: false) else {
            return super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText(), indentCaretListLine(outdent: true) else {
            return super.insertBacktab(sender)
        }
    }

    /// Indent (+2 spaces) or outdent (-up to 2 leading spaces) the caret's
    /// list line. Applies only "at line start" = caret within the
    /// indent+prefix region, which covers the key flow: Return continues a
    /// list, caret lands right after the fresh prefix, Tab nests it.
    /// Returns false when not applicable so callers fall back to the
    /// standard Tab/Backtab behavior.
    private func indentCaretListLine(outdent: Bool) -> Bool {
        guard let (caret, lineRange, _, line) = caretLine(),
              let (prefix, _) = Self.listPrefix(of: line),
              caret - lineRange.location <= (prefix as NSString).length,
              let storage = textStorage else { return false }
        if outdent {
            let text = storage.string as NSString
            var removable = 0
            while removable < 2,
                  lineRange.location + removable < text.length,
                  text.character(at: lineRange.location + removable) == 0x20 {
                removable += 1
            }
            let removeRange = NSRange(location: lineRange.location, length: removable)
            guard removable > 0,
                  shouldChangeText(in: removeRange, replacementString: "") else { return false }
            storage.replaceCharacters(in: removeRange, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: max(lineRange.location, caret - removable), length: 0))
        } else {
            let insertAt = NSRange(location: lineRange.location, length: 0)
            guard shouldChangeText(in: insertAt, replacementString: "  ") else { return false }
            storage.replaceCharacters(in: insertAt, with: "  ")
            didChangeText()
            setSelectedRange(NSRange(location: caret + 2, length: 0))
        }
        return true
    }

    // MARK: - S12: list keyword mode (Antinote §1 + §6)
    //
    // First line exactly `list` / `リスト` = checklist note: content lines
    // below get a "[ ] " prefix as REAL text through undo-able edits
    // (shouldChangeText paths — NEVER silent storage writes), Return
    // continues with a fresh box (insertNewline), and "/x" at a line end
    // checks the line off (insertText hook). Editing the keyword away
    // NEVER strips the boxes — they became user content the moment they
    // were inserted; stripping would destroy the checklist (content
    // protection), exactly like the calc pass never touches user text.

    /// Whether the note's first line is the list token right now (same
    /// first-line read NoteView uses for the timer rail).
    var isListModeActive: Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        return FloteList.isListKeyword(
            firstLine: String(storage.string.prefix(while: { $0 != "\n" })))
    }

    /// Reentrancy flag — the pass's own didChangeText re-enters the
    /// text-change cascade.
    private var isApplyingListPrefixes = false

    /// One idempotent prefix pass: plan (pure) → filter protected spots →
    /// ONE batched, undo-able multi-range edit. Runs on every text change
    /// and caret move; two caret rules make it safe while typing:
    /// - caret ON THE FIRST LINE = no-op ("list" might become "listen" —
    ///   activation commits only when the user LEAVES the keyword line, so
    ///   a half-typed word never litters the note with boxes it would
    ///   have to keep, since deactivation never strips),
    /// - the caret's own line below is exempt inside the planner ("//…"
    ///   can be typed without a box racing the first "/"); it commits when
    ///   the caret leaves it.
    func applyListModePrefixes() {
        guard !isApplyingListPrefixes, !isRecalculatingResult,
              !isAdjustingLinkDisplay, !hasMarkedText(),
              let storage = textStorage, storage.length > 0 else { return }
        // Never fight undo/redo replay: re-prefixing what the user just
        // undid would corrupt the stack (same rule as adjustLinkDisplay).
        if let um = undoManager, um.isUndoing || um.isRedoing { return }
        let sel = selectedRange()
        // Range selections: the user is mid-manipulation; edits under the
        // selection would shift what they grabbed. Wait for a caret.
        guard sel.length == 0 else { return }
        let text = storage.string as NSString
        let firstLineRange = text.lineRange(for: NSRange(location: 0, length: 0))
        if sel.location < NSMaxRange(firstLineRange)
            || (sel.location == text.length
                && NSMaxRange(firstLineRange) == text.length) {
            return   // caret still on the keyword line: not committed yet
        }
        let insertions = FloteList.plannedCheckboxInsertions(
            noteText: storage.string, excludingLineAt: sel.location
        ).filter { location in
            // Fail closed at protected boundaries: inserting AT a link /
            // shrunk-link / calc-result run start would splice text into a
            // run another pass owns and rewrites.
            location < storage.length
                && !semanticExcluded(NSRange(location: location, length: 1),
                                     in: storage)
        }
        guard !insertions.isEmpty else { return }
        isApplyingListPrefixes = true
        defer { isApplyingListPrefixes = false }
        // ONE bracketed multi-range edit (ranges ascending, as the API
        // requires): a single undo step covers the whole activation, and no
        // intermediate didChangeText can shift pending ranges mid-loop.
        let ranges = insertions.map { NSValue(range: NSRange(location: $0, length: 0)) }
        let strings = Array(repeating: FloteList.checkboxPrefix, count: insertions.count)
        guard shouldChangeText(inRanges: ranges, replacementStrings: strings) else { return }
        // Body-default attributes — the prefix must never inherit a
        // neighboring run's semantic markers or link/result attributes.
        // S16: resolvedBodyFont = user size + theme monospace override.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: FontPreference.shared.resolvedBodyFont(),
            .foregroundColor: FloteInk.text(legacyTheme: legacyThemeRaw)
        ]
        let piece = NSAttributedString(string: FloteList.checkboxPrefix,
                                       attributes: attrs)
        storage.beginEditing()
        for location in insertions.reversed() {
            storage.replaceCharacters(
                in: NSRange(location: location, length: 0), with: piece)
        }
        storage.endEditing()
        didChangeText()
    }

    // MARK: - S9: formatting-strip on paste (§12)

    /// ⌘V / Edit → Paste. The INCOMING pasted string (and only it — note
    /// storage is never re-processed) is cleaned by the pure pipeline and
    /// inserted as plain text via the normal typing path, so it adopts the
    /// note's typingAttributes (the attribute strip: no alien fonts/colors
    /// from web or Word) and ONE ⌘Z undoes the whole paste. Fall-through
    /// to the stock attributed paste when:
    /// - IME composition is active (never edit inside a marked range),
    /// - the master toggle is off (user opted out of paste processing),
    /// - the pasteboard has no plain string (images etc. keep default
    ///   behavior).
    /// ⌘⇧V (raw paste, below) bypasses this override entirely.
    override func paste(_ sender: Any?) {
        guard !hasMarkedText(),
              FlotePastePrefs.stripAttributesEnabled,
              let raw = NSPasteboard.general.string(forType: .string),
              !raw.isEmpty
        else { return super.paste(sender) }
        let cleaned = FlotePasteStrip.process(raw, options: FlotePastePrefs.currentOptions)
        insertText(cleaned, replacementRange: selectedRange())
    }

    /// ⌘B / ⌘I / ⌘U. This MenuBarExtra-only app has no Format menu, so the
    /// responder chain never resolves these as menu key equivalents
    /// (verified: no keyEquivalent/CommandMenu in the target). Reuses the
    /// toolbar's exact command path via the coordinator — selection
    /// behavior, typing-attribute behavior, persistence, and toolbar state
    /// updates stay identical to a toolbar click. Unmatched events fall
    /// through to super so Edit-menu equivalents (⌘C/⌘V/⌘Z…) are untouched.
    ///
    /// ⌘⇧V (S9) = paste RAW: NSTextView's default attributed paste with
    /// zero processing — the escape hatch the paste(_:) override needs.
    /// Intercepted here (view-level key equivalents run before the menu
    /// bar's) so a default "Paste and Match Style" menu binding can never
    /// shadow it. During IME composition it falls through to super —
    /// same discipline as ⌘B/I/U.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !hasMarkedText(), mods == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            super.paste(self)
            return true
        }
        // S7L ⌘⏎: open the link at the caret (landing: "⌘⏎ to open").
        // Only consumed when a link is actually there — otherwise the
        // event falls through untouched.
        if mods == .command, event.charactersIgnoringModifiers == "\r",
           openLinkAtCaret() {
            return true
        }
        if !hasMarkedText(), mods == .command,
           let coordinator = delegate as? RichTextEditor.Coordinator {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": coordinator.apply(command: .toggleBold); return true
            case "i": coordinator.apply(command: .toggleItalic); return true
            case "u": coordinator.apply(command: .toggleUnderline); return true
            default: break
            }
        }
        // S16 global text size: ⌘+ / ⌘= step up, ⌘− step down, ⌘0 reset —
        // the Safari-zoom key family, active while a note panel is key.
        // Wired here (not a menu) for the same reason as ⌘B/I/U above:
        // a MenuBarExtra app has no Format/View menu to host equivalents.
        // Writing the preference propagates to EVERY open note via
        // .floteBodyFontChanged (global size is a preference, not a
        // document edit — see applyBodyFontResolution). "+" arrives as
        // ⌘⇧= on ANSI (charactersIgnoringModifiers keeps the shift-mapped
        // "+"), so cmd and cmd+shift are both accepted for it; "=" is the
        // unshifted alias, cmd-only.
        if !hasMarkedText() {
            let char = event.charactersIgnoringModifiers
            if char == "+", mods == .command || mods == [.command, .shift] {
                FontPreference.shared.bodySize =
                    FloteTextSize.increased(from: FontPreference.shared.bodySize)
                return true
            }
            if mods == .command {
                switch char {
                case "=":
                    FontPreference.shared.bodySize =
                        FloteTextSize.increased(from: FontPreference.shared.bodySize)
                    return true
                case "-":
                    FontPreference.shared.bodySize =
                        FloteTextSize.decreased(from: FontPreference.shared.bodySize)
                    return true
                case "0":
                    FontPreference.shared.bodySize = FloteTextSize.defaultSize
                    return true
                default: break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - S7L: link auto-shrink display pass (spec §10)
    //
    // Long bare-URL link runs display as `domain/…/smart-ending`
    // (`github.com/…/pull/1234`) while the FULL url lives in the .link
    // attribute and in .floteShrunkLink (the exact original string).
    // Caret entering a shrunk run expands it for editing; leaving it
    // re-shrinks. Every replacement rides shouldChangeText/didChangeText,
    // so ⌘Z restores cleanly and persistence sees a consistent document.

    /// Reentrancy + mutual-exclusion flag (see didChangeText).
    private var isAdjustingLinkDisplay = false

    /// One idempotent display pass. Called on every selection change and
    /// every text change; when nothing qualifies it mutates nothing.
    func adjustLinkDisplay() {
        guard !isAdjustingLinkDisplay, !isRecalculatingResult, !hasMarkedText(),
              let storage = textStorage, storage.length > 0 else { return }
        // Never fight undo/redo replay — re-shrinking what the user just
        // undid would corrupt the stack they are walking.
        if let um = undoManager, um.isUndoing || um.isRedoing { return }
        isAdjustingLinkDisplay = true
        defer { isAdjustingLinkDisplay = false }

        // Phase 1 — existing shrunk runs: the run under the caret EXPANDS
        // back to the full URL for editing; every other run gets its .link
        // re-asserted (the auto link detector can strip or split it after
        // nearby edits — the run self-heals from the marker). Back-to-front
        // so the caret run's length change cannot shift pending ranges.
        let sel = selectedRange()
        let caret: Int? = sel.length == 0 ? sel.location : nil
        var shrunk: [(range: NSRange, full: String)] = []
        storage.enumerateAttribute(
            .floteShrunkLink, in: NSRange(location: 0, length: storage.length),
            options: []) { value, range, _ in
            if let full = value as? String { shrunk.append((range, full)) }
        }
        for (range, full) in shrunk.reversed() {
            if let caret, caret > range.location, caret < NSMaxRange(range) {
                expandShrunkRun(range, original: full,
                                caretOffset: caret - range.location, in: storage)
            } else {
                repairShrunkRun(range, full: full, in: storage)
            }
        }

        // Phase 2 — fresh candidates (re-scan: phase 1 may have moved
        // text). Shrink a .link run only when ALL of:
        // - its visible text IS the url (user-typed/pasted, not a custom
        //   label — content protection: labels are user prose),
        // - the caret/selection is not on or adjacent to it (the user is
        //   working there),
        // - it carries no .floteCalcResult anywhere (live-calc interplay
        //   rule: results are the calculator's, never the shrinker's).
        let selAfter = selectedRange()
        let text = storage.string as NSString
        var candidates: [(range: NSRange, short: String, full: String, link: Any)] = []
        storage.enumerateAttribute(
            .link, in: NSRange(location: 0, length: storage.length),
            options: []) { value, range, _ in
            guard let value else { return }
            if storage.attribute(.floteShrunkLink, at: range.location,
                                 effectiveRange: nil) != nil { return }
            var touchesCalc = false
            storage.enumerateAttribute(.floteCalcResult, in: range, options: []) { v, _, stop in
                if v != nil { touchesCalc = true; stop.pointee = true }
            }
            if touchesCalc { return }
            let touchesSelection: Bool
            if selAfter.length == 0 {
                touchesSelection = selAfter.location >= range.location
                    && selAfter.location <= NSMaxRange(range)
            } else {
                touchesSelection = NSIntersectionRange(selAfter, range).length > 0
            }
            if touchesSelection { return }
            let visible = text.substring(with: range)
            guard let linkString = (value as? URL)?.absoluteString ?? (value as? String),
                  FloteLinkShrink.isBareURLText(visible, linkURL: linkString),
                  let short = FloteLinkShrink.smartShort(for: visible) else { return }
            candidates.append((range, short, visible, value))
        }
        for c in candidates.reversed() {
            shrinkLinkRun(c.range, short: c.short, full: c.full,
                          linkValue: c.link, in: storage)
        }
    }

    /// Replace a bare-URL run's visible text with its smart-short form.
    /// The full url stays in .link (untouched original value) and in
    /// .floteShrunkLink (the exact original string) — display shrinks,
    /// data never does.
    private func shrinkLinkRun(_ range: NSRange, short: String, full: String,
                               linkValue: Any, in storage: NSTextStorage) {
        guard NSMaxRange(range) <= storage.length else { return }
        var attrs = storage.attributes(at: range.location, effectiveRange: nil)
        attrs[.floteShrunkLink] = full
        attrs[.link] = linkValue
        attrs.removeValue(forKey: .floteCalcResult)
        guard shouldChangeText(in: range, replacementString: short) else { return }
        storage.replaceCharacters(
            in: range, with: NSAttributedString(string: short, attributes: attrs))
        didChangeText()
    }

    /// Restore the original full URL for editing (caret entered the run):
    /// visible text becomes the stored original, the marker is dropped,
    /// .link stays. The caret keeps its relative offset inside the run.
    private func expandShrunkRun(_ range: NSRange, original: String,
                                 caretOffset: Int, in storage: NSTextStorage) {
        guard NSMaxRange(range) <= storage.length else { return }
        var attrs = storage.attributes(at: range.location, effectiveRange: nil)
        attrs.removeValue(forKey: .floteShrunkLink)
        guard shouldChangeText(in: range, replacementString: original) else { return }
        storage.replaceCharacters(
            in: range, with: NSAttributedString(string: original, attributes: attrs))
        didChangeText()
        let newLen = (original as NSString).length
        setSelectedRange(NSRange(
            location: range.location + min(caretOffset, newLen), length: 0))
    }

    /// Self-heal a shrunk run whose .link the auto-detector stripped or
    /// split (it re-checks edited regions and does not understand the "…"
    /// display form). Any http/https/bare spelling of the stored url
    /// counts as intact — repair only rewrites genuinely damaged runs.
    private func repairShrunkRun(_ range: NSRange, full: String,
                                 in storage: NSTextStorage) {
        guard NSMaxRange(range) <= storage.length else { return }
        let absolute = full.contains("://") ? full : "https://" + full
        guard let url = URL(string: absolute) else { return }
        let acceptable: Set<String> = [
            full, full + "/",
            "https://" + full, "https://" + full + "/",
            "http://" + full, "http://" + full + "/",
        ]
        var intact = true
        storage.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
            let current = (value as? URL)?.absoluteString ?? (value as? String)
            if current == nil || !acceptable.contains(current!) {
                intact = false
                stop.pointee = true
            }
        }
        guard !intact else { return }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(.link, value: url, range: range)
        storage.endEditing()
        didChangeText()
    }

    /// ⌘⏎ — open the link at (or immediately before) the caret. Falls back
    /// to the .floteShrunkLink marker when a damaged run has no .link yet.
    private func openLinkAtCaret() -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let sel = selectedRange()
        for probe in [sel.location, sel.location - 1] {
            guard probe >= 0, probe < storage.length else { continue }
            if let value = storage.attribute(.link, at: probe, effectiveRange: nil) {
                let url = (value as? URL) ?? (value as? String).flatMap {
                    URL(string: $0.contains("://") ? $0 : "https://" + $0)
                }
                if let url {
                    NSWorkspace.shared.open(url)
                    return true
                }
            }
            if let full = storage.attribute(.floteShrunkLink, at: probe,
                                            effectiveRange: nil) as? String,
               let url = URL(string: full.contains("://") ? full : "https://" + full) {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }

    /// S7L copy: the pasteboard must carry the FULL url, never the
    /// "domain/…/tail" display form. When the selection overlaps any
    /// shrunk run, the copy degrades to plain text with every overlapped
    /// run expanded (rich attributes are the price of a correct URL — a
    /// partially selected shrunk run still yields the whole url, because
    /// half a display form is meaningless). Selections without shrunk
    /// runs keep stock rich copy.
    override func copy(_ sender: Any?) {
        guard let out = expandedPlainText(for: selectedRange()) else {
            return super.copy(sender)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out, forType: .string)
    }

    /// S7L cut (v56 audit fix): ⌘X must carry the same truth as copy — the
    /// FULL url, never the elided display form — because cut also DELETES
    /// the storage that held it (the marker would be gone for good).
    /// Pasteboard first, then the deletion rides the normal undo-able edit
    /// path. Selections without shrunk runs keep stock rich cut; IME
    /// composition falls through untouched.
    override func cut(_ sender: Any?) {
        let sel = selectedRange()
        guard !hasMarkedText(),
              let out = expandedPlainText(for: sel),
              let storage = textStorage else { return super.cut(sender) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out, forType: .string)
        guard shouldChangeText(in: sel, replacementString: "") else { return }
        storage.deleteCharacters(in: sel)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location, length: 0))
    }

    /// Drag-out and Services writes (v56 audit fix): same contract — a
    /// dragged shrunk run leaves as its FULL url, degraded to plain text.
    /// Selections without shrunk runs keep the stock rich write.
    override func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let out = expandedPlainText(for: selectedRange()) else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.declareTypes([.string], owner: nil)
        pboard.setString(out, forType: .string)
        return true
    }

    /// Plain-text form of `sel` with every overlapped .floteShrunkLink run
    /// expanded to its full URL (a partially selected run still yields the
    /// WHOLE url — half a display form is meaningless). nil when no shrunk
    /// run intersects, so callers keep stock behavior (rich attributes are
    /// the price of a correct URL only when a shrunk run is actually
    /// involved).
    private func expandedPlainText(for sel: NSRange) -> String? {
        guard let storage = textStorage,
              sel.length > 0, NSMaxRange(sel) <= storage.length else { return nil }
        var hasShrunk = false
        storage.enumerateAttribute(.floteShrunkLink, in: sel, options: []) { value, _, stop in
            if value != nil {
                hasShrunk = true
                stop.pointee = true
            }
        }
        guard hasShrunk else { return nil }
        let text = storage.string as NSString
        let docRange = NSRange(location: 0, length: storage.length)
        var out = ""
        var cursor = sel.location
        let end = NSMaxRange(sel)
        while cursor < end {
            var effective = NSRange()
            let marker = storage.attribute(
                .floteShrunkLink, at: cursor,
                longestEffectiveRange: &effective, in: docRange)
            let sliceEnd = min(NSMaxRange(effective), end)
            if let full = marker as? String {
                out += full
            } else if sliceEnd > cursor {
                out += text.substring(
                    with: NSRange(location: cursor, length: sliceEnd - cursor))
            }
            cursor = max(sliceEnd, cursor + 1)
        }
        return out
    }

    // MARK: - S11: live semantic styling (calc variables + invisible markdown)
    //
    // ONE attribute-only pass, two concerns (Appendix C item b + rival P1):
    // - Calc grammar: variable DEFINITION name → FloteInk.variableDef, its
    //   colon → FloteInk.keyword, variable USES inside calc-flavored
    //   expressions → FloteInk.variableUse (the Antinote "dimmed quote").
    // - Invisible markdown v1: #/##/### heading lines (heavier + larger,
    //   marks visible but dim), **bold**, *italic*, `code` (mono + subtle
    //   background), all markers dimmed — FloteMarkdown finds the ranges.
    //
    // Mechanics (content protection, same spirit as the calc/link passes):
    // - Everything the pass touches carries a private marker attribute
    //   (.floteSemanticColor / .floteSemanticFont / .floteSemanticBackground)
    //   whose VALUE stores what was replaced (original color / trait bits
    //   the pass ADDED), so the clear step restores EXACTLY its own edits —
    //   user-set colors, link colors and calc-result runs are structurally
    //   out of reach (runs carrying .link / .floteShrunkLink /
    //   .floteCalcResult are skipped whole; fail closed).
    // - Attribute-only: wrapped in beginEditing/endEditing WITHOUT
    //   shouldChangeText — the styling is DERIVED state, not a user edit,
    //   so it must never occupy an undo step (⌘Z after typing "# t" should
    //   remove the "t", not un-bold the heading). Undo/redo replay restores
    //   characters with whatever attributes were captured; the pass re-runs
    //   right after (didChangeText fires during replay) and re-derives —
    //   self-healing, nothing registered, the stack never fights it.
    // - Persistence: markers + colors ride RichTextStorage (NSColor/NSNumber
    //   are on the unarchive allow-list). The Coordinator's textDidChange
    //   snapshot runs BEFORE this pass each keystroke, so the pass persists
    //   once more when it actually changed something — disk and display
    //   never diverge for longer than one pass.
    // - Skipped during IME composition (hasMarkedText) and while the calc /
    //   link passes run (their didChangeText recursion); re-run on theme
    //   change via .floteAppearanceChanged (Coordinator observer), on load,
    //   on reload and on font-family swap.

    /// Trait/derivation bits the pass ADDED at a run — stored as the
    /// .floteSemanticFont value so the clear step removes only what the
    /// pass itself introduced (user bold inside **…** survives).
    private enum SemanticFontBits {
        static let boldAdded = 1
        static let italicAdded = 2
        static let monoApplied = 4
        static let headingApplied = 8
    }

    /// Body point size — the app-wide invariant (rescaleToDefaultSize
    /// normalizes every span to it on load). Headings ride +3/+2/+1 on top.
    /// S16: now the USER'S global size — heading/code derivation stays
    /// relative to whatever base the user picked (⌘+/⌘−/Settings).
    private static var semanticBodyPointSize: CGFloat {
        FontPreference.shared.bodySize
    }

    /// Documents past this size skip the APPLY phase (the clear phase still
    /// runs, so stale styling never outlives the cap). Sticky notes live
    /// far below this; the cap only guards pathological pastes.
    private static let semanticPassMaxLength = 20_000

    /// Reentrancy flag (the pass never calls didChangeText, but the guard
    /// keeps any future notification-driven re-trigger from stacking).
    private var isApplyingSemanticStyle = false

    /// The one semantic-styling pass: clear own styling → re-derive.
    /// Idempotent; a no-op document mutates nothing.
    func runSemanticStylingPass() {
        guard !isApplyingSemanticStyle, !isRecalculatingResult,
              !isAdjustingLinkDisplay, !hasMarkedText(),
              let storage = textStorage, storage.length > 0 else { return }
        isApplyingSemanticStyle = true
        defer { isApplyingSemanticStyle = false }

        var changed = false
        storage.beginEditing()
        clearSemanticStyling(in: storage, changed: &changed)
        if storage.length <= Self.semanticPassMaxLength,
           applySemanticStyling(in: storage) {
            changed = true
        }
        storage.endEditing()

        // Keep disk in step: the Coordinator's snapshot for this keystroke
        // ran before the pass. Same call textDidChange makes; markers and
        // colors self-heal from persisted state on reload either way.
        if changed, let noteID {
            let attrStr = NSAttributedString(attributedString: storage)
            NoteManager.shared.updateRichText(
                id: noteID, data: RichTextStorage.archive(attrStr),
                plainText: attrStr.string)
        }
    }

    // MARK: S11 clear phase

    /// Restore EXACTLY what the pass changed, nothing else: marked colors
    /// revert to their stored original (or to "no explicit color"), marked
    /// fonts drop only the traits/size/family the pass added.
    private func clearSemanticStyling(in storage: NSTextStorage, changed: inout Bool) {
        let full = NSRange(location: 0, length: storage.length)
        let fm = NSFontManager.shared

        // Fonts first (color restore is independent of font restore).
        var fontMarks: [(NSRange, Int)] = []
        storage.enumerateAttribute(.floteSemanticFont, in: full, options: []) { v, r, _ in
            if let bits = (v as? NSNumber)?.intValue { fontMarks.append((r, bits)) }
        }
        for (range, bits) in fontMarks {
            var restores: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: range, options: []) { fv, sub, _ in
                let current = (fv as? NSFont)
                    ?? FontPreference.shared.resolvedBodyFont()
                let restored: NSFont
                if bits & (SemanticFontBits.monoApplied | SemanticFontBits.headingApplied) != 0 {
                    // Size/family were touched: rebuild from the preference
                    // base (S16: resolvedBodyFont — user size + theme mono
                    // override, so a mono theme's clear step never restores
                    // the non-mono family) and re-add the traits the USER
                    // had (current traits minus the ones the pass added).
                    var f = FontPreference.shared.resolvedBodyFont()
                    let traits = fm.traits(of: current)
                    if traits.contains(.boldFontMask),
                       bits & SemanticFontBits.boldAdded == 0 {
                        f = fm.convert(f, toHaveTrait: .boldFontMask)
                    }
                    if traits.contains(.italicFontMask),
                       bits & SemanticFontBits.italicAdded == 0 {
                        f = fm.convert(f, toHaveTrait: .italicFontMask)
                    }
                    restored = f
                } else {
                    // Traits-only change: surgical removal keeps whatever
                    // family/size the run legitimately has.
                    var f = current
                    if bits & SemanticFontBits.boldAdded != 0 {
                        f = fm.convert(f, toNotHaveTrait: .boldFontMask)
                    }
                    if bits & SemanticFontBits.italicAdded != 0 {
                        f = fm.convert(f, toNotHaveTrait: .italicFontMask)
                    }
                    restored = f
                }
                if restored != current { restores.append((sub, restored)) }
            }
            for (sub, font) in restores {
                storage.addAttribute(.font, value: font, range: sub)
            }
            storage.removeAttribute(.floteSemanticFont, range: range)
            changed = true
        }

        // Colors: marker value = the replaced original (NSColor), or
        // NSNumber(true) = "had no explicit foreground".
        var colorMarks: [(NSRange, Any)] = []
        storage.enumerateAttribute(.floteSemanticColor, in: full, options: []) { v, r, _ in
            if let v { colorMarks.append((r, v)) }
        }
        for (range, original) in colorMarks {
            if let color = original as? NSColor {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            } else {
                storage.removeAttribute(.foregroundColor, range: range)
            }
            storage.removeAttribute(.floteSemanticColor, range: range)
            changed = true
        }

        // Backgrounds (code spans): same restore contract as colors.
        var bgMarks: [(NSRange, Any)] = []
        storage.enumerateAttribute(.floteSemanticBackground, in: full, options: []) { v, r, _ in
            if let v { bgMarks.append((r, v)) }
        }
        for (range, original) in bgMarks {
            if let color = original as? NSColor {
                storage.addAttribute(.backgroundColor, value: color, range: range)
            } else {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            storage.removeAttribute(.floteSemanticBackground, range: range)
            changed = true
        }
    }

    // MARK: S11 apply phase

    /// Returns true when it styled anything. Uses a captured local (not an
    /// inout parameter): enumerateSubstrings' block is typed escaping, and
    /// escaping closures cannot capture inout — the block still runs
    /// synchronously, so the local is settled before the return.
    private func applySemanticStyling(in storage: NSTextStorage) -> Bool {
        var changed = false
        let text = storage.string as NSString
        let theme = legacyThemeRaw

        // Resolved inks, once per pass (FloteTheme S14 semantic slots).
        let defInk = FloteInk.variableDef(legacyTheme: theme)
        let useInk = FloteInk.variableUse(legacyTheme: theme)
        let keywordInk = FloteInk.keyword(legacyTheme: theme)
        let dimInk = FloteInk.text(legacyTheme: theme, alpha: 0.4)
        let codeBg = FloteInk.text(legacyTheme: theme, alpha: 0.07)

        // Variable tables: the FULL table decides which names are live USES
        // anywhere (a use above its definition evaluates — insertText
        // substitutes the whole-note table); the PROGRESSIVE table mirrors
        // FloteCalc.variables' top-to-bottom liveness for DEFINITION lines
        // (prose "メモ : 買い物" never evaluates → never colored — Antinote
        // colors any name: line in math MODE, but Flote notes are
        // prose-first, so a non-evaluating name would be a false positive).
        let fullTable = FloteCalc.variables(inText: storage.string)
        var progressive: [(name: String, value: Double)] = []
        // Longest-first so 全幅 wins over 幅 on overlap.
        let useNames = fullTable.map(\.name).sorted { $0.count > $1.count }

        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length), options: [.byLines]
        ) { sub, lineRange, _, _ in
            guard let line = sub, lineRange.length > 0 else { return }

            // --- Concern 0 (S12): keyword-line coloring. FIRST line only:
            // the mode token (list/リスト/timer/タイマー) renders in the
            // keyword ink (Antinote Appendix C: the keyword line is
            // COLORED; §6: the token is accent, any arguments/title stay
            // body ink). A keyword line is chrome, not content — the calc
            // and markdown concerns never touch it.
            if lineRange.location == 0,
               let token = FloteList.keywordTokenRange(inFirstLine: line) {
                let abs = NSRange(location: lineRange.location + token.location,
                                  length: token.length)
                if !self.semanticExcluded(abs, in: storage) {
                    self.applySemanticColor(keywordInk, range: abs,
                                            in: storage, changed: &changed)
                }
                return
            }

            // Rendered calc results are the calculator's — the semantic
            // zone of the line ends where the first result run begins.
            var resultStart: Int? = nil
            storage.enumerateAttribute(.floteCalcResult, in: lineRange, options: []) { v, r, stop in
                if v != nil { resultStart = r.location; stop.pointee = true }
            }
            let zoneEnd = resultStart ?? NSMaxRange(lineRange)
            let visible = text.substring(
                with: NSRange(location: lineRange.location,
                              length: zoneEnd - lineRange.location))
            let isCalcCandidate = resultStart != nil
                || visible.trimmingCharacters(in: .whitespaces).hasSuffix("=")

            // --- Concern 1: calc variables.
            var isLiveDefinition = false
            if let def = FloteCalc.variableDefinition(inLine: line) {
                let body = FloteCalc.substitute(
                    variables: progressive, in: def.expression)
                if let value = FloteCalc.evaluate(FloteCalc.normalizedOperators(body)) {
                    isLiveDefinition = true
                    if let tokens = Self.variableTokenRanges(inLineContent: line) {
                        let nameRange = NSRange(
                            location: lineRange.location + tokens.name.location,
                            length: tokens.name.length)
                        let colonRange = NSRange(
                            location: lineRange.location + tokens.colon.location,
                            length: tokens.colon.length)
                        // Exclusion gate here too: a name shaped like a URL
                        // ("github.com : 300") is a LINK run — never touch.
                        if !self.semanticExcluded(nameRange, in: storage) {
                            self.applySemanticColor(defInk, range: nameRange,
                                                    in: storage, changed: &changed)
                        }
                        if !self.semanticExcluded(colonRange, in: storage) {
                            self.applySemanticColor(keywordInk, range: colonRange,
                                                    in: storage, changed: &changed)
                        }
                        // USES inside the definition body ("subtotal :
                        // price * qty" — Antinote's custom-calculator look).
                        let bodyStart = NSMaxRange(colonRange)
                        self.colorVariableUses(
                            useNames, ink: useInk, in: storage, text: text,
                            zone: NSRange(location: bodyStart,
                                          length: max(0, self.semanticEqualsBound(
                                            text: text, from: bodyStart, to: zoneEnd) - bodyStart)),
                            changed: &changed)
                    }
                    progressive.removeAll { $0.name == def.name }
                    progressive.append((def.name, value))
                }
            } else if isCalcCandidate {
                // Expression lines ("幅*2=…"): uses colored up to the "=".
                let start = lineRange.location
                self.colorVariableUses(
                    useNames, ink: useInk, in: storage, text: text,
                    zone: NSRange(location: start,
                                  length: max(0, self.semanticEqualsBound(
                                    text: text, from: start, to: zoneEnd) - start)),
                    changed: &changed)
            }

            // --- Concern 2: invisible markdown. Calc-flavored lines get
            // NONE of it (a live definition or a "…=" expression is math,
            // not prose — "a*b + c*d=" must stay arithmetic, not italic).
            guard !isCalcCandidate, !isLiveDefinition else { return }
            let mdSpans = FloteMarkdown.spans(inLine: line)
            // A heading whose CONTENT hosts a protected run (a link in the
            // title) skips the whole heading — dim 14pt marks over plain
            // 11pt content would read broken, so fail closed together.
            let headingBlocked = mdSpans.contains { span in
                if case .headingText = span.kind {
                    return self.semanticExcluded(
                        NSRange(location: lineRange.location + span.range.location,
                                length: span.range.length), in: storage)
                }
                return false
            }
            for span in mdSpans {
                let range = NSRange(
                    location: lineRange.location + span.range.location,
                    length: span.range.length)
                guard !self.semanticExcluded(range, in: storage) else { continue }
                if headingBlocked,
                   case .headingMarks = span.kind { continue }
                switch span.kind {
                case .headingMarks(let level):
                    // Marks keep the heading's font (aligned baseline) but
                    // read as syntax: dimmed.
                    self.applySemanticFont(
                        range: range, headingLevel: level, in: storage, changed: &changed)
                    self.applySemanticColor(dimInk, range: range,
                                            in: storage, changed: &changed)
                case .headingText(let level):
                    self.applySemanticFont(
                        range: range, headingLevel: level, in: storage, changed: &changed)
                case .bold:
                    self.applySemanticFont(
                        range: range, bold: true, in: storage, changed: &changed)
                case .italic:
                    self.applySemanticFont(
                        range: range, italic: true, in: storage, changed: &changed)
                case .code:
                    self.applySemanticFont(
                        range: range, mono: true, in: storage, changed: &changed)
                    self.applySemanticBackground(codeBg, range: range,
                                                 in: storage, changed: &changed)
                case .syntax:
                    self.applySemanticColor(dimInk, range: range,
                                            in: storage, changed: &changed)
                }
            }
        }
        return changed
    }

    // MARK: S11 helpers

    /// Name + colon ranges of a definition line, in the LINE's UTF-16
    /// coordinates. Same slicing as FloteCalc.variableDefinition (first
    /// `:` or `：`, name = trimmed prefix) — only called on lines that
    /// parser already accepted.
    private static func variableTokenRanges(inLineContent line: String)
        -> (name: NSRange, colon: NSRange)? {
        let ns = line as NSString
        var colonIdx = -1
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            if c == 0x3A || c == 0xFF1A { colonIdx = i; break }   // : ／ ：
        }
        guard colonIdx > 0 else { return nil }
        func isWS(_ i: Int) -> Bool {
            guard let s = Unicode.Scalar(ns.character(at: i)) else { return false }
            return CharacterSet.whitespaces.contains(s)
        }
        var start = 0
        while start < colonIdx, isWS(start) { start += 1 }
        var end = colonIdx
        while end > start, isWS(end - 1) { end -= 1 }
        guard end > start else { return nil }
        return (NSRange(location: start, length: end - start),
                NSRange(location: colonIdx, length: 1))
    }

    /// The expression zone ends at the first literal "=" (anything after
    /// it is a rendered/legacy result, mirroring variableDefinition's cut).
    private func semanticEqualsBound(text: NSString, from: Int, to: Int) -> Int {
        var i = from
        while i < to {
            if text.character(at: i) == UInt16(UInt8(ascii: "=")) { return i }
            i += 1
        }
        return to
    }

    /// Color every boundary-clean occurrence of the known variable names
    /// inside `zone` (longest name wins; letters/digits glued to either
    /// side disqualify — the same fail-closed spirit as substitute()).
    private func colorVariableUses(
        _ names: [String], ink: NSColor, in storage: NSTextStorage,
        text: NSString, zone: NSRange, changed: inout Bool
    ) {
        guard zone.length > 0, NSMaxRange(zone) <= text.length else { return }
        var taken = [Bool](repeating: false, count: zone.length)
        let alnum = CharacterSet.alphanumerics
        func isAlnum(_ i: Int) -> Bool {
            guard i >= 0, i < text.length,
                  let s = Unicode.Scalar(text.character(at: i)) else { return false }
            return alnum.contains(s)
        }
        for name in names {
            var search = zone
            while search.length > 0 {
                let hit = text.range(of: name, options: [], range: search)
                if hit.location == NSNotFound { break }
                let next = NSMaxRange(hit)
                search = NSRange(location: next, length: NSMaxRange(zone) - next)
                // Boundary + overlap + exclusion gates (all fail closed).
                if isAlnum(hit.location - 1) || isAlnum(NSMaxRange(hit)) { continue }
                let local = hit.location - zone.location
                if (local..<(local + hit.length)).contains(where: { taken[$0] }) { continue }
                if semanticExcluded(hit, in: storage) { continue }
                for i in local..<(local + hit.length) { taken[i] = true }
                applySemanticColor(ink, range: hit, in: storage, changed: &changed)
            }
        }
    }

    /// True when any part of `range` belongs to a run the pass must never
    /// touch: rendered calc results, links, shrunk links.
    private func semanticExcluded(_ range: NSRange, in storage: NSTextStorage) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return true }
        for key: NSAttributedString.Key in [.floteCalcResult, .link, .floteShrunkLink] {
            var found = false
            storage.enumerateAttribute(key, in: range, options: []) { v, _, stop in
                if v != nil { found = true; stop.pointee = true }
            }
            if found { return true }
        }
        return false
    }

    /// Foreground with restore-marker: the marker VALUE keeps the color it
    /// replaced (or NSNumber(true) for "none"), per existing-color sub-run.
    private func applySemanticColor(
        _ color: NSColor, range: NSRange, in storage: NSTextStorage,
        changed: inout Bool
    ) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        var originals: [(NSRange, Any)] = []
        storage.enumerateAttribute(.foregroundColor, in: range, options: []) { v, sub, _ in
            // Already-marked sub-runs keep their ORIGINAL stored value —
            // never capture the pass's own output as "the original".
            if storage.attribute(.floteSemanticColor, at: sub.location,
                                 effectiveRange: nil) != nil { return }
            originals.append((sub, (v as? NSColor) ?? NSNumber(value: true)))
        }
        for (sub, original) in originals {
            storage.addAttribute(.floteSemanticColor, value: original, range: sub)
        }
        storage.addAttribute(.foregroundColor, value: color, range: range)
        changed = true
    }

    /// Background with the same restore contract (code spans).
    private func applySemanticBackground(
        _ color: NSColor, range: NSRange, in storage: NSTextStorage,
        changed: inout Bool
    ) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        var originals: [(NSRange, Any)] = []
        storage.enumerateAttribute(.backgroundColor, in: range, options: []) { v, sub, _ in
            if storage.attribute(.floteSemanticBackground, at: sub.location,
                                 effectiveRange: nil) != nil { return }
            originals.append((sub, (v as? NSColor) ?? NSNumber(value: true)))
        }
        for (sub, original) in originals {
            storage.addAttribute(.floteSemanticBackground, value: original, range: sub)
        }
        storage.addAttribute(.backgroundColor, value: color, range: range)
        changed = true
    }

    /// Font derivation from the CURRENT font at each sub-run (respects the
    /// user's family preference and any user-applied traits — a user-bolded
    /// word inside **…** records boldAdded=0 and survives the clear).
    /// Bits accumulate (heading content can host a code span: both restore).
    private func applySemanticFont(
        range: NSRange, headingLevel: Int? = nil, bold: Bool = false,
        italic: Bool = false, mono: Bool = false, in storage: NSTextStorage,
        changed: inout Bool
    ) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let fm = NSFontManager.shared
        var updates: [(NSRange, NSFont, Int)] = []
        storage.enumerateAttribute(.font, in: range, options: []) { v, sub, _ in
            let current = (v as? NSFont)
                ?? FontPreference.shared.resolvedBodyFont()
            let traits = fm.traits(of: current)
            var f = current
            var bits = 0
            if let level = headingLevel {
                // +3/+2/+1 pt over body for # / ## / ###.
                let delta = CGFloat(4 - min(max(level, 1), 3))
                f = fm.convert(f, toSize: Self.semanticBodyPointSize + delta)
                bits |= SemanticFontBits.headingApplied
                if !traits.contains(.boldFontMask) {
                    f = fm.convert(f, toHaveTrait: .boldFontMask)
                    bits |= SemanticFontBits.boldAdded
                }
            }
            if bold, !traits.contains(.boldFontMask) {
                f = fm.convert(f, toHaveTrait: .boldFontMask)
                bits |= SemanticFontBits.boldAdded
            }
            if italic, !traits.contains(.italicFontMask) {
                f = fm.convert(f, toHaveTrait: .italicFontMask)
                bits |= SemanticFontBits.italicAdded
            }
            if mono {
                // Mono at the run's CURRENT size (a code span inside a
                // heading stays heading-sized); heavier when the user had
                // bold there.
                f = NSFont.monospacedSystemFont(
                    ofSize: f.pointSize,
                    weight: traits.contains(.boldFontMask) ? .semibold : .regular)
                bits |= SemanticFontBits.monoApplied
            }
            if bits != 0 {
                let existing = (storage.attribute(
                    .floteSemanticFont, at: sub.location,
                    effectiveRange: nil) as? NSNumber)?.intValue ?? 0
                updates.append((sub, f, existing | bits))
            }
        }
        for (sub, font, bits) in updates {
            storage.addAttribute(.font, value: font, range: sub)
            storage.addAttribute(.floteSemanticFont,
                                 value: NSNumber(value: bits), range: sub)
            changed = true
        }
    }

    // MARK: - S7O: image drop → OCR (spec §11)
    //
    // Drop a png/jpg/heic/webp/tiff on the note → Apple Vision reads it
    // LOCALLY (no network, privacy parity with Antinote) → the recognized
    // plain text is inserted at the drop point through the normal typing
    // path (undo-able, inherits typingAttributes). The image itself is
    // NEVER stored. No text / any Vision error = transient banner, no
    // insertion (fail closed).

    private static let ocrImageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "heic", "webp", "tiff", "tif"]

    /// Payload cap — a 4K screenshot is ~10 MB; anything past 50 MB is not
    /// a screenshot and fails closed rather than stalling Vision.
    private static let ocrMaxImageBytes = 50 * 1024 * 1024

    /// Cheap type check only (runs on every draggingUpdated tick) — no
    /// file I/O here.
    private static func dragCarriesOCRImage(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { ocrImageExtensions.contains($0.pathExtension.lowercased()) }) {
            return true
        }
        return pb.availableType(from: [.png, .tiff]) != nil
    }

    /// The actual image bytes (file drag first, in-memory bitmap second).
    private static func ocrImageData(from pb: NSPasteboard) -> Data? {
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls
            where ocrImageExtensions.contains(url.pathExtension.lowercased()) {
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= ocrMaxImageBytes,
                      let data = try? Data(contentsOf: url) else { continue }
                return data
            }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), !data.isEmpty,
               data.count <= ocrMaxImageBytes {
                return data
            }
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.dragCarriesOCRImage(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.dragCarriesOCRImage(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard Self.dragCarriesOCRImage(pb) else {
            // Text/file drags keep stock NSTextView behavior.
            return super.performDragOperation(sender)
        }
        guard let data = Self.ocrImageData(from: pb) else {
            // Image-shaped drag whose payload could not be read (oversize,
            // file vanished mid-drag): fail closed, tell the user.
            postOCRError(L("画像を読み込めませんでした", "Could not read the image"))
            return false
        }
        let point = convert(sender.draggingLocation, from: nil)
        let dropIndex = characterIndexForInsertion(at: point)
        runOCR(on: data, insertAt: dropIndex)
        return true
    }

    /// Vision OCR OFF the main thread; insertion (or the error banner)
    /// back ON it. recognitionLanguages ja-first: the latin-biased default
    /// misreads JP glyphs, while EN survives this order untouched.
    private func runOCR(on data: Data, insertAt index: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP", "en-US"]
            request.usesLanguageCorrection = true
            var lines: [String] = []
            var failed = false
            do {
                let handler = VNImageRequestHandler(data: data, options: [:])
                try handler.perform([request])
                lines = (request.results ?? []).compactMap {
                    $0.topCandidates(1).first?.string
                }
            } catch {
                failed = true
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if failed {
                        self.postOCRError(L("画像の解析に失敗しました",
                                            "Could not analyze the image"))
                        return
                    }
                    let recognized = lines.joined(separator: "\n")
                    guard !recognized.isEmpty else {
                        self.postOCRError(L("画像に文字が見つかりませんでした",
                                            "No text found in the image"))
                        return
                    }
                    // IME guard: never splice into an active composition.
                    guard !self.hasMarkedText() else {
                        self.postOCRError(L("変換中のため挿入できませんでした",
                                            "Could not insert during text conversion"))
                        return
                    }
                    // The note may have changed while Vision ran — clamp.
                    let limit = self.textStorage?.length ?? 0
                    let at = max(0, min(index, limit))
                    self.insertText(recognized,
                                    replacementRange: NSRange(location: at, length: 0))
                }
            }
        }
    }

    /// OCR problems surface on NoteView's red transient banner (the same
    /// rail reminders use) — never as inserted text.
    private func postOCRError(_ message: String) {
        guard let noteID else { return }
        NotificationCenter.default.post(
            name: .floteTransientError, object: nil,
            userInfo: ["noteID": noteID, "message": message])
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
    // S16: "theme ink" — drop the explicit foreground color so the run
    // follows theme switches again (counterpart of removeHighlight).
    case removeTextColor

    static func == (lhs: RichTextCommand, rhs: RichTextCommand) -> Bool {
        switch (lhs, rhs) {
        case (.toggleBold, .toggleBold): return true
        case (.toggleItalic, .toggleItalic): return true
        case (.toggleUnderline, .toggleUnderline): return true
        case (.toggleStrikethrough, .toggleStrikethrough): return true
        case (.removeHighlight, .removeHighlight): return true
        case (.removeTextColor, .removeTextColor): return true
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
        // Swap in the checkbox-rendering layout manager BEFORE any content
        // loads or the view joins a window. replaceLayoutManager at creation
        // time cannot race a live layout pass (the documented
        // _postWindowNeedsUpdateConstraints crashes all involve views already
        // attached to a window). Storage, text container, and the
        // FloteTextView class (PanelManager walks subviews by that class)
        // are all unchanged; TextKit 1 stays TextKit 1.
        textView.textContainer?.replaceLayoutManager(FloteLayoutManager())
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
        // S16: resolvedBodyFont = family (or theme monospace override) at
        // the user's global body size.
        let baseFont = FontPreference.shared.resolvedBodyFont()
        textView.font = baseFont
        textView.textColor = FloteInk.text(legacyTheme: textView.legacyThemeRaw)

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
        // S6 entity detection: URLs (and phone/address via data detection)
        // become clickable. Apple's own checking paths — IME-safe, and the
        // .link attributes persist through RichTextStorage like any other.
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.linkTextAttributes = [
            .foregroundColor: FloteInk.accent(
                legacyTheme: NoteManager.shared.note(byID: noteID)?.colorTheme.rawValue),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
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
        // Detect entities in LOADED content too — the automatic flags only
        // cover text typed from now on. Runs the enabled checking types
        // (links/data) over the whole document once, before the user types.
        if textView.string.isEmpty == false {
            textView.checkTextInDocument(nil)
        }

        // S7O: image drops must reach performDragOperation even for types
        // NSTextView does not register on its own.
        var dragTypes = textView.registeredDraggedTypes
        for t in [NSPasteboard.PasteboardType.fileURL, .png, .tiff]
        where !dragTypes.contains(t) {
            dragTypes.append(t)
        }
        textView.registerForDraggedTypes(dragTypes)

        // Resize panel to fit initial content (deferred until layout is ready).
        let capturedNoteID = noteID
        DispatchQueue.main.async { [weak textView] in
            guard let tv = textView,
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer else { return }
            // S7L: shrink persisted long links / self-heal persisted shrunk
            // runs once the load settles. Results the async text checker
            // delivers later are caught by the selection/typing passes.
            tv.adjustLinkDisplay()
            // S11: re-derive semantic styling for loaded content BEFORE the
            // height fit (heading fonts change line heights). Persisted
            // markers from the previous session are cleared and re-applied
            // against the CURRENT theme/font — stale styling self-heals.
            tv.runSemanticStylingPass()
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
        context.coordinator.startObservingAppearance()
        context.coordinator.startObservingBodyFont()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Live-update the body font (family choice, theme monospace
        // override, S16 global size) when preferences change. `fontFamily`
        // stays a stored property so SwiftUI tracks the Settings picker and
        // calls updateNSView; the actual resolution reads FontPreference
        // directly (same source NoteView passes). Size/mono changes are
        // ALSO delivered by the Coordinator's .floteBodyFontChanged
        // observer — both paths funnel into the same idempotent helper.
        if let tv = scrollView.documentView as? NSTextView {
            Self.applyBodyFontResolution(tv)
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

                    let userFont = FontPreference.shared.resolvedBodyFont()
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.lineSpacing = 2.5
                    tv.typingAttributes = [
                        .font: userFont,
                        .foregroundColor: FloteInk.text(
                            legacyTheme: NoteManager.shared.note(byID: capturedNoteID)?.colorTheme.rawValue),
                        .paragraphStyle: paraStyle
                    ]

                    // S7L: reloaded content (Organize output etc.) gets the
                    // same link-display pass as the initial load.
                    (tv as? FloteTextView)?.adjustLinkDisplay()

                    // S11: and the same semantic-styling pass (Organize
                    // output often contains headings/lists worth styling).
                    (tv as? FloteTextView)?.runSemanticStylingPass()

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

    /// S16: ONE idempotent re-resolution of an open editor's body font —
    /// family (the user's choice, or the theme's monospace override) plus
    /// the global body size. This is the family-swap hook generalized:
    /// - family sweep preserves each span's size + traits (N1)
    /// - rescaleToDefaultSize normalizes every span to the current body
    ///   size (traits kept; heading/code derivations rebuilt by S11 next)
    /// - S11 re-derives so `code` stays monospaced and headings ride
    ///   +3/+2/+1 on the NEW base
    /// - typingAttributes convert family+size, KEEPING a live bold/italic
    /// - panel refits because the text height changed.
    /// DERIVED state, exactly like the family swap before it: no undo
    /// registration (⌘Z after ⌘+ undoes the last TEXT edit, never fights
    /// a global preference; an undo-restored run with a stale size baked
    /// in re-normalizes on the next resolution pass or reload — the same
    /// documented parity the family swap has today).
    /// Callers: updateNSView (SwiftUI-driven) and the Coordinator's
    /// .floteBodyFontChanged observer (⌘+/⌘−/⌘0, Settings stepper, theme
    /// monospace flag) — gated below, so redundant delivery is free.
    @MainActor
    static func applyBodyFontResolution(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        // IME guard: never mutate storage mid-composition. Self-heals: the
        // gate below re-detects the mismatch on the next call (updateNSView
        // fires again once composition commits and SwiftUI updates).
        guard !tv.hasMarkedText() else { return }
        let resolved = FontPreference.shared.resolvedBodyFont()
        let familyChanged = tv.font?.familyName != resolved.familyName
        let sizeChanged = abs((tv.font?.pointSize ?? 0) - resolved.pointSize) > 0.1
        guard familyChanged || sizeChanged else { return }
        tv.font = resolved

        if familyChanged, let newFamilyName = resolved.familyName {
            // Swap family on each existing font span, keeping size + traits.
            // `convert(_:toFamily:)` applies the closest available variant
            // (bold, italic, bold-italic…).
            let fullRange = NSRange(location: 0, length: storage.length)
            let fm = NSFontManager.shared
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: fullRange, options: []) { value, subRange, _ in
                let existing = (value as? NSFont) ?? resolved
                let swapped = fm.convert(existing, toFamily: newFamilyName)
                storage.addAttribute(.font, value: swapped, range: subRange)
            }
            storage.endEditing()
        }

        // Size: the same machinery as the load-time migration — every span
        // to the current body size, family + traits preserved.
        rescaleToDefaultSize(tv)

        // S11: the family swap converts code-span mono fonts to the new
        // family and the rescale flattens heading sizes — re-derive so
        // `code` stays monospaced and headings rebuild from the new base.
        (tv as? FloteTextView)?.runSemanticStylingPass()

        // Typing attributes follow: convert the CURRENT typing font (keeps
        // a live bold/italic toggle armed by the user) to family + size.
        var attrs = tv.typingAttributes
        let fm = NSFontManager.shared
        var typing = (attrs[.font] as? NSFont) ?? resolved
        if let family = resolved.familyName {
            typing = fm.convert(typing, toFamily: family)
        }
        typing = fm.convert(typing, toSize: resolved.pointSize)
        attrs[.font] = typing
        tv.typingAttributes = attrs

        // Text height changed — refit the panel, same as the reload path.
        DispatchQueue.main.async { [weak tv] in
            guard let flote = tv as? FloteTextView, let noteID = flote.noteID,
                  let lm = flote.layoutManager,
                  let tc = flote.textContainer else { return }
            lm.ensureLayout(for: tc)
            PanelManager.shared.fitPanelToContent(
                noteID: noteID, textHeight: lm.usedRect(for: tc).height)
        }
    }

    /// Rescale every font span in the text view's storage to the current
    /// default point size while preserving the family and traits (bold /
    /// italic). Rich text stored before a font-size change still carries
    /// the old size baked into its attributes; without this rescale, the
    /// user would have to re-run Organize on every note to see the new
    /// size. Called from makeNSView (initial load), updateNSView
    /// (reloadTrigger bump after Organize) and applyBodyFontResolution
    /// (S16 live size change). Content that OTHER writers bake at a fixed
    /// 11pt (NoteView's Organize output, ClipboardCollector) self-heals
    /// through this same pass on the reload/load that follows.
    @MainActor
    static func rescaleToDefaultSize(_ tv: NSTextView) {
        guard let storage = tv.textStorage, storage.length > 0 else { return }
        // S16: target = the user's global body size.
        let targetSize = FontPreference.shared.bodySize
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
        nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
        nonisolated(unsafe) private var bodyFontObserver: NSObjectProtocol?

        init(noteID: UUID, textState: RichTextState) {
            self.noteID = noteID
            self.textState = textState
        }

        deinit {
            if let obs = scrollObserver {
                NotificationCenter.default.removeObserver(obs)
                scrollObserver = nil
            }
            if let obs = appearanceObserver {
                NotificationCenter.default.removeObserver(obs)
                appearanceObserver = nil
            }
            if let obs = bodyFontObserver {
                NotificationCenter.default.removeObserver(obs)
                bodyFontObserver = nil
            }
        }

        /// S16: a global body-size step (⌘+/⌘−/⌘0 in ANY note, Settings
        /// stepper) or the theme monospace flag re-resolves the body font
        /// of EVERY open note — this note included when the key event
        /// landed elsewhere. Same delivery pattern as the appearance
        /// observer below; the helper is idempotent, so overlap with the
        /// updateNSView path costs nothing.
        func startObservingBodyFont() {
            guard bodyFontObserver == nil else { return }
            bodyFontObserver = NotificationCenter.default.addObserver(
                forName: .floteBodyFontChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let tv = self.textView else { return }
                    RichTextEditor.applyBodyFontResolution(tv)
                }
            }
        }

        /// S11: an app-theme switch re-inks the semantic styling (variable
        /// defs/uses, dimmed syntax are BAKED colors — a theme change must
        /// restyle, same reasoning as the layout manager's checkbox refresh).
        /// paperType/paperStrength changes don't affect text ink — skipped.
        func startObservingAppearance() {
            guard appearanceObserver == nil else { return }
            appearanceObserver = NotificationCenter.default.addObserver(
                forName: .floteAppearanceChanged, object: nil, queue: .main
            ) { [weak self] note in
                // queue: .main delivery; assumeIsolated bridges to
                // @MainActor (established idiom in this codebase).
                MainActor.assumeIsolated {
                    guard let self,
                          let key = note.userInfo?["key"] as? String,
                          key == "appTheme" else { return }
                    (self.textView as? FloteTextView)?.runSemanticStylingPass()
                }
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
                // queue: .main delivery; assumeIsolated bridges to
                // @MainActor (established idiom in this codebase).
                MainActor.assumeIsolated {
                    guard let self, let sv = scrollView else { return }
                    self.updateOverflowIndicator(sv)
                }
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
            // S7L: caret movement drives the shrink/expand of link display
            // (spec §10 Flote adaptation: caret entering a shrunk run
            // expands it for editing; leaving re-shrinks). The pass is
            // reentrancy-guarded and a no-op when nothing qualifies.
            (tv as? FloteTextView)?.adjustLinkDisplay()
            // S12: leaving a line COMMITS its list-mode checkbox prefix
            // (the keyword line and the caret's own line are exempt inside
            // the pass — see applyListModePrefixes). No-op outside list
            // mode.
            (tv as? FloteTextView)?.applyListModePrefixes()
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
            guard !tv.hasMarkedText() else { return }
            let range = tv.selectedRange()

            // When no text is selected, modify typingAttributes for future input.
            if range.length == 0 {
                applyToTypingAttributes(command: command, textView: tv)
                updateTextState(from: tv)
                return
            }

            // Undo bracket (Evaluator #5): replacementString nil = an
            // attributes-only change; without this bracket the toggle
            // mutates storage behind the undo stack and ⌘Z skips it.
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()

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
                // S11: dropping the semantic marker makes the user's pick
                // the styling pass's new "original" — an explicit choice is
                // never reverted by the pass's clear step.
                storage.removeAttribute(.floteSemanticBackground, range: range)
                storage.addAttribute(.backgroundColor, value: color, range: range)

            case .removeHighlight:
                storage.removeAttribute(.floteSemanticBackground, range: range)
                storage.removeAttribute(.backgroundColor, range: range)

            case .textColor(let color):
                // S11: same contract as .highlight above.
                storage.removeAttribute(.floteSemanticColor, range: range)
                storage.addAttribute(.foregroundColor, value: color, range: range)

            case .removeTextColor:
                // S16 theme ink: drop the explicit color AND the S11
                // marker — the run renders in the view's theme ink again
                // and the semantic pass may re-derive its own styling
                // fresh (didChangeText below re-runs it).
                storage.removeAttribute(.floteSemanticColor, range: range)
                storage.removeAttribute(.foregroundColor, range: range)
            }

            storage.endEditing()
            tv.didChangeText()

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

            case .removeTextColor:
                // No explicit color in typingAttributes = new text uses
                // the view's theme ink.
                attrs.removeValue(forKey: .foregroundColor)
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

extension NSAttributedString.Key {
    /// Marks an inline-calc RESULT run ("=7242" tail): rendered in the theme
    /// accent and live-re-evaluated on edit. Only runs carrying this key are
    /// ever rewritten by the calculator — user-typed text is structurally
    /// untouchable. Persists through RichTextStorage (NSNumber value).
    static let floteCalcResult = NSAttributedString.Key("floteCalcResult")
    /// S7L: marks a SHRUNK link run; value = the original full URL string
    /// (the exact visible text before shrinking). The display pass expands
    /// it when the caret enters, copy(_:) substitutes it on the pasteboard,
    /// and it persists through RichTextStorage (NSString is on the
    /// unarchive allow-list) — the full URL is structurally never lost.
    static let floteShrunkLink = NSAttributedString.Key("floteShrunkLink")
    /// S11: marks a foreground color set by the semantic-styling pass
    /// (variable defs/uses/colons, dimmed markdown syntax). Value = the
    /// NSColor the pass replaced, or NSNumber(true) = "had no explicit
    /// color" — the clear step restores EXACTLY that, so user-set colors
    /// are never destroyed. Persists through RichTextStorage (NSColor and
    /// NSNumber are both on the unarchive allow-list) — reloaded notes
    /// self-heal instead of freezing stale styling.
    static let floteSemanticColor = NSAttributedString.Key("floteSemanticColor")
    /// S11: marks a font DERIVED by the semantic pass (heading size/weight,
    /// **bold**, *italic*, `code` mono). Value = NSNumber bitmask of what
    /// the pass ADDED (FloteTextView.SemanticFontBits) — the clear step
    /// removes only those additions, so user-applied traits survive.
    static let floteSemanticFont = NSAttributedString.Key("floteSemanticFont")
    /// S11: marks the subtle background behind a `code` span. Value = the
    /// replaced NSColor or NSNumber(true), same restore contract as
    /// .floteSemanticColor (user highlights are never destroyed).
    static let floteSemanticBackground = NSAttributedString.Key("floteSemanticBackground")
}

extension Notification.Name {
    /// Posted by AppKit-side features (reminders) that need NoteView's red
    /// transient error banner. userInfo: "noteID" UUID, "message" String.
    static let floteTransientError = Notification.Name("floteTransientError")
    /// Text context menu → NoteView verb pipeline (same rails as the
    /// Organize-pill menu). userInfo: "noteID" UUID, "verb" String rawValue.
    static let floteRunVerbFromEditor = Notification.Name("floteRunVerbFromEditor")
    /// Text context menu → NoteView export/copy actions.
    /// userInfo: "noteID" UUID, "format" String (copy-md|txt|markdown|pdf).
    static let floteExportFromEditor = Notification.Name("floteExportFromEditor")
}
