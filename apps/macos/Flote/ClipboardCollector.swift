import AppKit
import Observation

// FLOTE-AUTOPASTE-PURE-BEGIN
// (pure: Foundation-only — extracted verbatim by .harness/tests/
// autopaste-test.sh, so the harness always compiles the SHIPPING logic.)

/// AutoPaste (Antinote §9) capture decision. Every gate is FAIL-CLOSED:
/// any doubt means "do not append" — a collector that occasionally misses
/// a copy is annoying; one that appends passwords or duplicates is broken.
enum FloteClipDecide {
    /// Decide whether a pasteboard change becomes an appended line.
    /// Returns the exact string to append, or nil = skip.
    ///
    /// Rules, in order:
    /// 1. concealed → never. Password managers mark secrets with
    ///    org.nspasteboard.ConcealedType; those must never land in a note.
    /// 2. nil / whitespace-only string → never. Images and file copies have
    ///    no string representation (string-only v1); pure whitespace is
    ///    noise.
    /// 3. within 1 s of a Flote-internal copy → never (our own copy
    ///    buttons must not echo into the collector).
    /// 4. exact repeat of the previous capture → never (rapid-fire ⌘C on
    ///    the same selection appends once).
    /// 5. already contained anywhere in the note text → never. This is a
    ///    superset of the "note tail" check: it also blocks whole-note
    ///    self-copies (Flote's copy button puts note.text on the
    ///    pasteboard), calc-result copies whose value sits in the text,
    ///    and append→copy→append echo loops.
    ///
    /// Trailing newlines are trimmed before rules 4/5 so "foo\n" from a
    /// browser and "foo" from an editor dedupe as the same item — and so
    /// captures never accumulate blank separator lines. Leading and inner
    /// whitespace are preserved (indented code snippets stay intact).
    static func capture(
        candidate: String?,
        isConcealed: Bool,
        lastCaptured: String?,
        noteText: String,
        secondsSinceInternalCopy: Double?
    ) -> String? {
        if isConcealed { return nil }
        guard var text = candidate else { return nil }
        // "\r\n" is ONE grapheme cluster in Swift — hasSuffix("\n") does
        // not match it, so CRLF needs its own check (removeLast() then
        // drops the whole cluster at once).
        while text.hasSuffix("\r\n") || text.hasSuffix("\n") || text.hasSuffix("\r") {
            text.removeLast()
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if let dt = secondsSinceInternalCopy, dt < 1.0 { return nil }
        if text == lastCaptured { return nil }
        if !noteText.isEmpty, noteText.contains(text) { return nil }
        return text
    }
}
// FLOTE-AUTOPASTE-PURE-END

/// AutoPaste (Antinote §9 → Flote mapping): while ON for a note, every NEW
/// string copied anywhere on the Mac is appended to that note as a new
/// line — "Skip Cmd-Tab". Toggled from the note's copy-button context menu
/// (クリップボード収集); NoteView shows a pulsing clipboard glyph while
/// collecting.
///
/// Polling, not notifications: macOS has NO pasteboard-change notification
/// API — NSPasteboard.changeCount polling is the sanctioned pattern (every
/// clipboard manager does this). 0.7 s keeps rapid-fire copies feeling
/// instant while the idle cost is two Int reads per tick.
///
/// Exactly ONE note may collect at a time (`activeNoteID`, not a Set —
/// a Set would double-append every copy). Turning collection on for
/// another note silently moves the collector there.
///
/// OFF conditions: toggle off / indicator click / the note's panel closes
/// (NoteView.onDisappear) / the note disappears or becomes LOCKED
/// mid-collection (fail-closed auto-stop) / app quit (state is in-memory
/// only, never persisted — a relaunch always starts collector-off).
///
/// Own-copy protection: NoteView's copy actions call noteInternalCopy(),
/// opening a 1 s suppression window; decision rule 5 additionally blocks
/// anything already present in the note. Residual edge (documented, not
/// closable without touching RichTextEditor): a calc-result click-to-copy
/// whose value is NOT part of the collecting note's text (e.g. clicked in
/// a DIFFERENT note) is indistinguishable from a genuine external copy and
/// will be appended — visible, ordinary text, trivially deletable.
@Observable
@MainActor
final class ClipboardCollector {
    static let shared = ClipboardCollector()

    /// The single collecting note. Observed by NoteView (indicator + menu
    /// checkmark re-render through SwiftUI Observation).
    private(set) var activeNoteID: UUID?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = 0
    @ObservationIgnored private var lastCaptured: String?
    @ObservationIgnored private var lastInternalCopyAt: Date?

    private init() {}

    func isCollecting(_ noteID: UUID) -> Bool { activeNoteID == noteID }

    func toggle(noteID: UUID) {
        if activeNoteID == noteID { stop() } else { start(noteID: noteID) }
    }

    /// Starting on note B while note A collects MOVES the collector
    /// (single-owner invariant).
    func start(noteID: UUID) {
        activeNoteID = noteID
        lastCaptured = nil
        // Baseline = NOW: whatever already sits on the clipboard predates
        // the toggle and must not be captured retroactively.
        lastChangeCount = NSPasteboard.general.changeCount
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        activeNoteID = nil
        lastCaptured = nil
        timer?.invalidate()
        timer = nil
    }

    /// Panel-close hook (NoteView.onDisappear): only stops when the closing
    /// note is the one collecting.
    func stopIfActive(noteID: UUID) {
        if activeNoteID == noteID { stop() }
    }

    /// Flote's own copy actions (copy button, copy-as-markdown) announce
    /// themselves so the collector skips the next ~1 s of pasteboard
    /// changes. Calc click-to-copy lives in RichTextEditor and cannot call
    /// this — see the class header for that residual edge.
    func noteInternalCopy() {
        lastInternalCopyAt = Date()
    }

    private static let concealedType =
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private func pollOnce() {
        guard let noteID = activeNoteID else { return }
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        // Consume the change FIRST — every skip path below must not
        // re-examine the same pasteboard generation next tick.
        lastChangeCount = count

        // Fail-closed: the note vanished (deleted/archived) or got LOCKED
        // mid-collection → stop entirely, never append blind.
        guard let note = NoteManager.shared.note(byID: noteID),
              !note.isLocked else {
            stop()
            return
        }

        let concealed = pb.availableType(from: [Self.concealedType]) != nil
        let dt = lastInternalCopyAt.map { Date().timeIntervalSince($0) }
        guard let text = FloteClipDecide.capture(
            candidate: pb.string(forType: .string),
            isConcealed: concealed,
            lastCaptured: lastCaptured,
            noteText: note.text,
            secondsSinceInternalCopy: dt
        ) else { return }
        // IME protection (eval-regression finding 2): the append swaps the
        // open panel's whole text storage — doing that mid-composition
        // destroys the user's uncommitted input. Defer: put the pasteboard
        // generation back and retry next tick until composition ends.
        if let tv = PanelManager.shared.textViewIfComposing(noteID: noteID) {
            _ = tv  // (composing) — leave lastChangeCount rewound for retry
            lastChangeCount = count - 1
            return
        }
        lastCaptured = text
        append(text, toNoteID: noteID)
    }

    /// Append as a new line through the same storage path the AI flows use:
    /// updateRichText (markDirty → debounced auto-save = ordinary note text,
    /// persistence for free) + PanelManager.reloadTextView so an OPEN panel
    /// updates live. The appended run adopts the note's current editor
    /// recipe (body font, theme ink, 2.5 line spacing — same as Organize).
    private func append(_ text: String, toNoteID noteID: UUID) {
        guard let note = NoteManager.shared.note(byID: noteID) else { return }
        let newPlain = note.text.isEmpty ? text : note.text + "\n" + text
        let font = FontPreference.shared.current.nsFont(size: 11, weight: .regular)
        let ink = FloteInk.text(legacyTheme: note.colorTheme.rawValue)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2.5
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: para
        ]
        // archive() is Optional-returning; a nil rides the same tolerant
        // path the rest of the app uses (updateRichText/reloadTextView both
        // accept nil and fall back to plain text).
        let data: Data?
        if let existing = note.richTextData,
           let attr = RichTextStorage.unarchive(existing),
           attr.length > 0 {
            let merged = NSMutableAttributedString(attributedString: attr)
            merged.append(NSAttributedString(string: "\n" + text, attributes: attrs))
            data = RichTextStorage.archive(merged)
        } else {
            data = RichTextStorage.archive(
                NSAttributedString(string: newPlain, attributes: attrs))
        }
        NoteManager.shared.updateRichText(id: noteID, data: data, plainText: newPlain)
        PanelManager.shared.reloadTextView(for: noteID, data: data, plain: newPlain)
    }
}
