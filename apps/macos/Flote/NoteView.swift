import SwiftUI
import Combine
import LocalAuthentication
import CoreText
import UniformTypeIdentifiers

/// S6 verb menu: targeted one-shot transforms on the note body, reached by
/// right-clicking the Organize pill AND from the text context menu
/// (internal, not private, so FloteTextView can enumerate the cases —
/// Tom's dogfood 2026-07-11: right-click on the TEXT is where people look).
/// Every verb rides the exact same content-protection rails as Organize —
/// snapshot first, apply via updateRichText, button flips to 戻す.
enum NoteVerb: String, CaseIterable, Identifiable {
    case checklist, fixTypos, shorten, translate

    var id: String { rawValue }

    @MainActor
    var menuLabel: String {
        switch self {
        case .checklist: return L("チェックリスト化", "To checklist")
        case .fixTypos:  return L("誤字を直す", "Fix typos")
        case .shorten:   return L("短くする", "Shorten")
        case .translate: return L("英語⇄日本語", "EN ⇄ JP")
        }
    }

    /// The single instruction handed to AIProvider.transform. The
    /// "transformed text only" output contract is enforced by the providers;
    /// this string only defines WHAT the verb does.
    var instruction: String {
        switch self {
        case .checklist:
            return "テキストから行動項目を漏らさず抽出し、各行を「[ ] 」で始まるチェックリストにする。行動項目でない重要情報も短い行として残す。項目を発明しない。"
        case .fixTypos:
            return "誤字・脱字・変換ミス・明らかな文法ミスだけを直す。言い回し・語順・内容・改行構造は変えない。"
        case .shorten:
            return "内容と改行構造を保ったまま簡潔に短くする。固有名詞・数値・日時・URL は必ず残す。おおよそ半分の長さにする。"
        case .translate:
            return "日本語の部分は自然な英語に、英語の部分は自然な日本語に翻訳する。意味とトーンを保ち、固有名詞・数値はそのまま残す。"
        }
    }
}

/// S6 export formats reached by right-clicking the copy button.
private enum NoteExportFormat {
    case txt, markdown, pdf

    var fileExtension: String {
        switch self {
        case .txt:      return "txt"
        case .markdown: return "md"
        case .pdf:      return "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .txt:      return .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .pdf:      return .pdf
        }
    }
}

// FLOTE-SENDTO-PURE-BEGIN
// (pure: Foundation-only — extracted verbatim by .harness/tests/
// send-to-test.sh, so the harness always compiles the SHIPPING logic.)

/// Send-to-app payload builders (landing copy: "Instantly send to Apple
/// Notes, Obsidian, and Bear."). Pure String → String, no AppKit, so the
/// escaping/URL logic is testable standalone.
enum FloteSendTo {
    /// HTML escape for the Apple Notes `body` property (Notes renders body
    /// as HTML). `&` `<` `>` are escaped — & FIRST so entities don't
    /// double-escape their own ampersand — then CR/CRLF are normalized and
    /// newlines become <br>.
    static func htmlEscapedBody(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// AppleScript string-literal escaping. Backslash FIRST (or the escape
    /// of a quote would itself get re-escaped), then double quote.
    static func appleScriptLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The exact one-liner executed for "Send to Apple Notes" (spec form:
    /// make new note at folder "Notes"). Notes creates the note silently
    /// in the default account's Notes folder.
    static func appleNotesScript(name: String, plainText: String) -> String {
        "tell application \"Notes\" to make new note at folder \"Notes\" "
            + "with properties {name:\"\(appleScriptLiteral(name))\", "
            + "body:\"\(appleScriptLiteral(htmlEscapedBody(plainText)))\"}"
    }

    /// RFC 3986 unreserved characters — everything else (spaces, &, ?, /,
    /// #, %, unicode…) is percent-encoded so scheme URLs can never be
    /// misparsed by the receiving app.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "abcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// addingPercentEncoding is nil only for pathological inputs; "" is the
    /// fail-closed fallback (an empty query param, never a broken URL).
    static func percentEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// No vault param — Obsidian routes to the user's default vault.
    static func obsidianURLString(content: String) -> String {
        "obsidian://new?content=" + percentEncoded(content)
    }

    static func bearURLString(title: String, text: String) -> String {
        "bear://x-callback-url/create?title=" + percentEncoded(title)
            + "&text=" + percentEncoded(text)
    }
}
// FLOTE-SENDTO-PURE-END

/// Send targets reachable from the copy-button context menu AND the text
/// context menu (editor posts "send-notes" / "send-obsidian" / "send-bear"
/// through .floteExportFromEditor — same single pipeline as exports).
private enum NoteSendTarget {
    case appleNotes, obsidian, bear

    /// Product names — not localized on purpose.
    var appName: String {
        switch self {
        case .appleNotes: return "Apple Notes"
        case .obsidian:   return "Obsidian"
        case .bear:       return "Bear"
        }
    }

    /// URL scheme probed for the install check; nil = always present
    /// (Apple Notes ships with macOS).
    var installProbeScheme: String? {
        switch self {
        case .appleNotes: return nil
        case .obsidian:   return "obsidian"
        case .bear:       return "bear"
        }
    }
}

struct NoteView: View {
    let noteID: UUID

    @State private var isOrganizing = false
    @State private var organizeError: String?
    @State private var showErrorOverlay = false
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var reloadTrigger = 0
    @State private var isHoveringOrganize = false
    // Onboarding demo hint: the pill pulses until the first Organize tap.
    @State private var organizeHintActive =
        UserDefaults.standard.bool(forKey: OnboardingWindowController.organizeHintKey)
    @State private var organizeHintPulse = false
    // S6 Touch ID lock: unlocked-for-this-session flag (never persisted —
    // relaunching the app re-locks every locked note).
    @State private var isUnlockedThisSession = false
    @State private var isAuthenticating = false
    @State private var isHoveringString = false
    @State private var showCopiedToast = false
    @State private var isSorting = false
    @State private var editorState = RichTextState()
    @State private var organizeUndoData: (richData: Data?, plain: String, title: String?)?
    // S1 Organize↔戻す: confirm before discarding post-organize edits.
    @State private var showRevertEditedConfirm = false
    // S10 timer finish: transient border-pulse overlay (never the panel
    // frame or corner radius — crash invariant).
    @State private var timerPulseVisible = false
    @State private var timerPulseTask: Task<Void, Never>?
    // AutoPaste (§9): drives the collecting-indicator opacity pulse.
    @State private var clipboardPulse = false
    // S16 deck: fleeting "2/5" position flash after a deck switch.
    @State private var deckFlashText: String?
    @State private var deckFlashTask: Task<Void, Never>?
    // S16 tab commands: dot currently under the pointer (drives the
    // hover-× close badge) + grace task so the badge survives the
    // pointer's dot→× hop.
    @State private var hoveredDotID: UUID?
    @State private var dotHoverClearTask: Task<Void, Never>?

    private var note: StickyNote? {
        NoteManager.shared.note(byID: noteID)
    }

    // S3: resolve the note's theme spec — app-wide override (appTheme) wins,
    // else the note's own hue via the legacy-lossless registry mapping.
    @Environment(\.colorScheme) private var colorScheme

    private var themePalette: FloteThemeSpec.Palette {
        let spec = AppearanceSettings.shared.appThemeSpec
            ?? FloteThemeRegistry.specForLegacy(note?.colorTheme.rawValue ?? "yellow")
        // Notes are PAPER — always the light palette, even in system dark
        // mode (Tom 2026-07-10: dark-mode coupling turned pastel notes into
        // muddy slate; the approved mock's world is light pastel). The dark
        // variants stay in the registry for a future explicit dark-note
        // option, never an OS-driven surprise.
        return spec.palette(dark: false)
    }

    private var background: Color { themePalette.background.color }

    private var toolbarColor: Color { themePalette.toolbar.color }

    /// Theme ink for chrome (buttons/labels). Body-text ink is applied by the
    /// editor; chrome follows the same spec so every theme stays legible.
    private var inkColor: Color { themePalette.text.color }

    private var stowState: StowState {
        note?.stowState ?? .expanded
    }

    var body: some View {
        Group {
            switch stowState {
            case .mini:
                MiniNoteView(noteID: noteID)
            case .rolledUp:
                rolledUpView
            case .expanded:
                if (note?.isLocked ?? false) && !isUnlockedThisSession {
                    lockedView
                } else {
                    expandedView
                }
            }
        }
        // CRASH INVARIANT (2026-04-17 family): the radius must never change
        // as a side effect of stowState transitions and must never animate.
        // It is an APP-LEVEL constant that changes only through an explicit
        // Settings action (S7-3 角丸) — same safety class as the old literal
        // 12, which is still the default.
        .clipShape(RoundedRectangle(
            cornerRadius: AppearanceSettings.shared.cornerRadius, style: .continuous))
        // S3 live refresh: AppearanceSettings is @Observable and its
        // properties are read inside body (themePalette / background), so
        // SwiftUI Observation re-renders open panels automatically on any
        // Settings change — no NotificationCenter plumbing needed here.
        // (FloatingPanel keeps its own observer for the WINDOW-level knobs,
        // alphaValue and the vibrancy layer, which live outside SwiftUI.)
        .onDisappear {
            // Cancel the auto-dismiss timer when the view leaves the hierarchy
            // (panel closed or note switched) to prevent a delayed setState.
            errorDismissTask?.cancel()
            timerPulseTask?.cancel()
            deckFlashTask?.cancel()
            dotHoverClearTask?.cancel()
            // AutoPaste OFF condition "panel closes or the deck switches
            // away": the root view leaves the hierarchy when the panel
            // goes away (stow keeps the root alive) AND when this note
            // stops being the deck's SHOWN note (S16 — the collector
            // writes into what the user can see, so switching away ends
            // collection; the deck keeps the collected text, of course).
            // Timer notes are the opposite by design: TimerEngine is
            // noteID-keyed and keeps running for switched-away members.
            ClipboardCollector.shared.stopIfActive(noteID: noteID)
        }
        // NOTE: Do NOT add SwiftUI .animation(value: stowState) here.
        // StowAnimator already runs an NSAnimationContext frame animation on
        // the window; a SwiftUI implicit animation on top of it causes
        // NSHostingView.updateAnimatedWindowSize to reenter the constraint
        // pass and throw (_postWindowNeedsUpdateConstraints). See crash
        // Flote-2026-04-17-132651.ips.
    }

    // MARK: - Rolled-up view (balloon handle, 2026-07-12 redesign)

    /// The stow handle: the note fades out in place (StowAnimator) and
    /// THIS remains, hovering at the note's former top edge — a small
    /// balloon in the note's paper tint with a cord rising above it.
    /// Tap = the note fades back in just below.
    /// Owner's dark-desktop screenshot (2026-07-12): the old hairline
    /// cord + tiny bead were invisible on dark wallpapers, so every
    /// stroke here is DOUBLED light-over-dark — a light outer edge under
    /// the ink cord, a light rim outside the balloon's ink line, and a
    /// real drop shadow — reads on ANY background.
    private var rolledUpView: some View {
        let balloonSize: CGFloat = isHoveringString ? 21 : 18
        return VStack(spacing: 0) {
            // Cord: 3pt total — light outer edge under a dark core.
            // Fades toward the top so it reads as trailing off.
            ZStack {
                LinearGradient(
                    colors: [Color.white.opacity(0.05),
                             Color.white.opacity(isHoveringString ? 0.8 : 0.6)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 3)
                .clipShape(Capsule())
                LinearGradient(
                    colors: [inkColor.opacity(0.05),
                             inkColor.opacity(isHoveringString ? 0.72 : 0.52)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 1.5)
                .clipShape(Capsule())
            }
            .frame(maxHeight: .infinity)
            // Balloon: the note's own paper tint (multiple handles stay
            // tellable-apart), 1pt light rim OUTSIDE the ink line + a
            // stronger shadow so it reads as a physical object anywhere,
            // and a specular touch to keep the balloon material.
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: balloonSize + 2, height: balloonSize + 2)
                Circle()
                    .fill(toolbarColor)
                    .overlay(Circle().strokeBorder(inkColor.opacity(0.35), lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: balloonSize * 0.28, height: balloonSize * 0.28)
                            .offset(x: balloonSize * 0.18, y: balloonSize * 0.18)
                    }
                    .frame(width: balloonSize, height: balloonSize)
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
            .padding(.top, 1)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            PanelManager.shared.toggleStow(noteID: noteID)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHoveringString = hovering }
        }
        .help(note?.lockedSafeTitle ?? L("ノートを戻す", "Bring the note back"))
        .accessibilityLabel(L("ノートを戻す", "Bring the note back"))
        .contextMenu {
            Button(L("ノートを戻す", "Bring back")) {
                PanelManager.shared.toggleStow(noteID: noteID)
            }
            Button(L("ミニにする", "To mini")) {
                PanelManager.shared.toggleMini(noteID: noteID)
            }
            Divider()
            Button(L("タイトルを編集", "Edit title")) { editTitleViaAlert() }
        }
    }

    /// Rolled-title editing, post-balloon home (the old 26px-bar inline
    /// editor has no room on a 44px string). Native alert + text field —
    /// keyboard-first, Esc cancels, empty clears back to the derived title.
    private func editTitleViaAlert() {
        let alert = NSAlert()
        alert.messageText = L("タイトルを編集", "Edit title")
        alert.informativeText = L("空にすると本文から自動で付きます。",
                                  "Leave empty to derive it from the note text.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = note?.rolledTitle ?? note?.lockedSafeTitle ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("キャンセル", "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        NoteManager.shared.updateRolledTitle(id: noteID, title: trimmed.isEmpty ? nil : trimmed)
    }


    // MARK: - Expanded

    /// S6 Touch ID lock: the locked face. Content is never in the view
    /// tree while locked (an overlay would still leave text in the
    /// hierarchy); the paper, a lock glyph, and an unlock button only.
    private var lockedView: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(inkColor.opacity(0.35))
            Text(note?.lockedSafeTitle ?? L("ロック中のノート", "Locked note"))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(inkColor.opacity(0.55))
                .lineLimit(1)
            Button(action: authenticateToUnlock) {
                Text(isAuthenticating ? L("認証中…", "Authenticating…") : L("ロック解除", "Unlock"))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(inkColor.opacity(0.82)))
            }
            .buttonStyle(.plain)
            .disabled(isAuthenticating)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Device-owner authentication (Touch ID, or password fallback — the
    /// policy covers Macs without biometrics). Unlock lasts this session.
    private func authenticateToUnlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isAuthenticating = false
            showTransientError(L("この Mac では認証を利用できません", "Authentication is unavailable on this Mac") + "（\(error?.localizedDescription ?? "?")）")
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: L("ロックされたノートを表示", "view the locked note")
        ) { success, _ in
            Task { @MainActor in
                isAuthenticating = false
                if success {
                    isUnlockedThisSession = true
                    reloadTrigger += 1
                }
            }
        }
    }

    /// S10: parsed timer spec from the note's FIRST LINE. nil = normal note
    /// (the parse fails closed — prose like "timers are fun" never matches).
    /// Reads note text inside body, so Observation re-evaluates on edits.
    private var timerSpec: FloteTimer.Spec? {
        guard let text = note?.text else { return nil }
        return FloteTimer.parse(firstLine: String(text.prefix(while: { $0 != "\n" })))
    }

    private var expandedView: some View {
        VStack(spacing: 0) {
            // Top bar: copy + organize + roll-up + close
            topBar

            // Text area (formatting is handled by AI Organize), with the S10
            // timer rail down the LEFT MARGIN when the first line is a timer
            // token — the text stays a normal editable note beside it.
            HStack(spacing: 4) {
                if let spec = timerSpec {
                    TimerRail(noteID: noteID, spec: spec,
                              ink: inkColor, accent: themePalette.accent.color)
                }
                ZStack(alignment: .bottom) {
                    RichTextEditor(
                        noteID: noteID,
                        pendingCommand: .constant(nil),
                        textState: editorState,
                        reloadTrigger: reloadTrigger,
                        fontFamily: FontPreference.shared.current
                    )

                    if editorState.hasContentBelow {
                        LinearGradient(
                            colors: [background.opacity(0), background],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 24)
                        .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 6)

            // Error banner (only shown when there's an error). Allow up to 2
            // lines so the detailed cause message (C6) is visible without
            // truncating the action hint ("Settings > AI Organize" etc.).
            if showErrorOverlay, let errorMsg = organizeError {
                Text(errorMsg)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.red.opacity(0.8))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .background(noteSurfaceBackground)
        // S10: the first line stopped being a timer token (edited/organized
        // away) — the note is no longer a timer note, forget its session
        // and cancel any pending cue. Panel close does NOT pass here (the
        // whole view goes away), so a closed panel's timer keeps running.
        .onChange(of: timerSpec) { _, newSpec in
            if newSpec == nil { TimerEngine.shared.drop(noteID: noteID) }
        }
        // S10 finish pulse: TRANSIENT overlay stroke, opacity-only. Never
        // animates the panel frame / corner radius (crash invariant) — the
        // radius is read as a constant, only this overlay's opacity moves.
        .overlay {
            if timerPulseVisible {
                RoundedRectangle(
                    cornerRadius: AppearanceSettings.shared.cornerRadius,
                    style: .continuous)
                    .strokeBorder(themePalette.accent.color, lineWidth: 3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floteTimerPulse)) { notif in
            guard let id = notif.userInfo?["noteID"] as? UUID, id == noteID else { return }
            runTimerPulse()
        }
        // S16 deck position indicator: tiny dots on the bottom edge
        // (deck ≥ 2 only) + the fleeting "2/5" flash after a switch.
        .overlay(alignment: .bottom) { deckIndicator }
        .onReceive(NotificationCenter.default.publisher(for: .floteDeckSwitched)) { notif in
            guard let id = notif.userInfo?["noteID"] as? UUID, id == noteID else { return }
            flashDeckPosition()
        }
    }

    // MARK: - Deck indicator (S16)

    /// Ordered deck members straight from the model — NoteManager is
    /// @Observable and `notes` is read in body, so membership changes
    /// (⌘T, archive, sort-away) re-render the dots automatically.
    private var deckMemberIDs: [UUID] {
        NoteManager.shared.deckMemberIDs(with: noteID)
    }

    /// Antinote-style minimal position indicator: a row of 5pt dots at
    /// the panel's bottom edge — current = accent-filled, others = ink
    /// 25% — visible ONLY when the deck has 2+ members. Tooltip = member
    /// titles; click = jump. Locked members never leak content into the
    /// tooltip (lockedSafeTitle).
    @ViewBuilder
    private var deckIndicator: some View {
        let deck = deckMemberIDs
        if deck.count >= 2 {
            VStack(spacing: 4) {
                if let flash = deckFlashText {
                    Text(flash)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.white.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous)
                            .fill(inkColor.opacity(0.85)))
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 5) {
                    ForEach(deck, id: \.self) { memberID in
                        let isCurrent = memberID == noteID
                        Circle()
                            .fill(isCurrent
                                ? themePalette.accent.color
                                : inkColor.opacity(0.25))
                            .frame(width: 5, height: 5)
                            .contentShape(Circle().scale(2.4)) // fat click target
                            .onTapGesture {
                                guard !isCurrent else { return }
                                PanelManager.shared.deckJump(from: noteID, to: memberID)
                            }
                            .help(NoteManager.shared.note(byID: memberID)?.lockedSafeTitle
                                  ?? L("無題のノート", "Untitled note"))
                            // Tab commands (2026-07-12), mouse lane: hover
                            // shows a small × above the dot (click = close
                            // that tab); right-click = the tab menu. The
                            // badge rides an overlay so dot spacing never
                            // changes; its hit region overlaps the dot's so
                            // the pointer can travel up without a gap.
                            .onHover { setDotHover(memberID, $0) }
                            .overlay(alignment: .top) {
                                if hoveredDotID == memberID {
                                    dotCloseBadge(for: memberID)
                                        .offset(y: -12)
                                }
                            }
                            .contextMenu { dotContextMenu(for: memberID) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(deckPositionText(in: deck).map {
                    L("ノート \($0)", "Note \($0)")
                } ?? "")
            }
            .padding(.bottom, 3)
        }
    }

    /// "2/5"-style position of THIS note in its deck (nil when solo).
    private func deckPositionText(in deck: [UUID]) -> String? {
        guard let pos = FloteDeck.position(of: noteID, in: deck),
              pos.count >= 2 else { return nil }
        return "\(pos.index)/\(pos.count)"
    }

    // MARK: - Deck tab commands, mouse lane (2026-07-12)

    /// Hover-driven badge state with a 150 ms grace period: the badge and
    /// the dot are separate hover regions (overlapping by design), and a
    /// diagonal pointer path can skim outside both for a frame — without
    /// the grace the × vanishes mid-travel.
    private func setDotHover(_ memberID: UUID, _ hovering: Bool) {
        if hovering {
            dotHoverClearTask?.cancel()
            dotHoverClearTask = nil
            hoveredDotID = memberID
        } else {
            dotHoverClearTask?.cancel()
            dotHoverClearTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                if hoveredDotID == memberID { hoveredDotID = nil }
            }
        }
    }

    /// The small × above a hovered dot — click closes that tab (archive,
    /// recoverable from the Groups tab; the dot click itself keeps meaning
    /// "jump", so both affordances coexist).
    private func dotCloseBadge(for memberID: UUID) -> some View {
        Image(systemName: "xmark")
            .font(.system(size: 5, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 10, height: 10)
            .background(Circle().fill(inkColor.opacity(0.85)))
            .contentShape(Circle().scale(1.6))
            .onHover { setDotHover(memberID, $0) }
            .onTapGesture {
                PanelManager.shared.deckCloseTab(memberID, shownID: noteID)
            }
            .help(L("このタブを閉じる", "Close this tab"))
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// Right-click menu on a dot: the keyboard tab commands for mouse
    /// users (product owner 2026-07-12: keyboard-first, menu secondary).
    /// Actions target the RIGHT-CLICKED dot's tab; the shortcut hints
    /// show the keyboard lane, which always acts on the shown tab.
    @ViewBuilder
    private func dotContextMenu(for memberID: UUID) -> some View {
        Button(L("このタブを閉じる", "Close This Tab")) {
            PanelManager.shared.deckCloseTab(memberID, shownID: noteID)
        }
        .keyboardShortcut("w", modifiers: .command)
        Button(L("独立した付箋に戻す", "Move to Its Own Sticky")) {
            PanelManager.shared.deckDetach(memberID, shownID: noteID)
        }
        .keyboardShortcut("w", modifiers: [.command, .option])
        Divider()
        Button(L("他のタブをすべて閉じる", "Close Other Tabs")) {
            PanelManager.shared.deckCloseOthers(keeping: memberID, shownID: noteID)
        }
        .keyboardShortcut("w", modifiers: [.command, .shift])
    }

    /// The fleeting counter: 0.8s after a switch, then gone. Reduce
    /// Motion swaps the fades for instant show/hide.
    private func flashDeckPosition() {
        guard let text = deckPositionText(in: deckMemberIDs) else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            deckFlashText = text
        } else {
            withAnimation(.easeIn(duration: 0.1)) { deckFlashText = text }
        }
        deckFlashTask?.cancel()
        deckFlashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                deckFlashText = nil
            } else {
                withAnimation(.easeOut(duration: 0.2)) { deckFlashText = nil }
            }
        }
    }

    /// One border pulse: fade in, hold ~0.9 s, fade out. Reduce Motion
    /// shows/hides without the fades. Re-firing cancels the previous decay
    /// so overlapping pomodoro cues can't flicker.
    private func runTimerPulse() {
        timerPulseTask?.cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            timerPulseVisible = true
        } else {
            withAnimation(.easeIn(duration: 0.12)) { timerPulseVisible = true }
        }
        timerPulseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                timerPulseVisible = false
            } else {
                withAnimation(.easeOut(duration: 0.45)) { timerPulseVisible = false }
            }
        }
    }

    // MARK: - Note surface (S3c layer stack)

    /// Bottom → top: photo (or the S3 top-lit tint gradient) → white
    /// dimming veil → reduced tint (photo mode) → surface material → dots
    /// pattern. Text draws above all of this; 罫線/方眼 are ruled inside
    /// FloteLayoutManager.drawBackground, aligned to real line fragments.
    ///
    /// Tint rationale: the approved mock's gradient — faint white highlight
    /// melting into the pastel — so the note reads as paper catching light,
    /// not a flat tile. With vibrancy it sits at 0.90 (the frost must never
    /// swallow the pastel — Tom rejected the see-through look); over a
    /// photo it drops to 0.35 so the hue still tints the image without
    /// hiding it.
    private var noteSurfaceBackground: some View {
        let settings = AppearanceSettings.shared
        // Dark-identity themes (nightsky/charcoal + the S16 editor set)
        // are designed as a FLAT deep ground — the white sheen ramp that
        // makes light pastels read as lit paper lifts them toward gray
        // ("washed pastel" owner verdict, root-caused by the themes
        // agent 2026-07-12). Keep only a whisper of depth there.
        let spec = AppearanceSettings.shared.appThemeSpec
            ?? FloteThemeRegistry.specForLegacy(note?.colorTheme.rawValue ?? "yellow")
        let sheenTop = Color.white.opacity(spec.isDarkTheme ? 0.05 : 0.38)
        return ZStack {
            if let photo = settings.customBackgroundImage {
                Color.clear
                    .overlay(
                        Image(nsImage: photo)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipped()
                // White veil (not black): keeps the dark warm ink readable
                // and stays inside Flote's light-paper world.
                Color.white.opacity(settings.customBackgroundDimming)
                LinearGradient(
                    colors: [sheenTop, background],
                    startPoint: .top, endPoint: .bottom
                )
                .opacity(0.35)
            } else {
                LinearGradient(
                    colors: [sheenTop, background],
                    startPoint: .top, endPoint: .bottom
                )
                .opacity(settings.useVibrancy ? 0.90 : 1.0)
            }

            MaterialOverlayView(material: settings.surfaceMaterial, ink: inkColor)

            // Paper pattern: .dots isn't line-coupled, so it stays SwiftUI-
            // drawn. 罫線/方眼 moved into FloteLayoutManager (S3c, aligned
            // by construction); the SwiftUI fallback below covers ONLY the
            // fully-empty note, where no line fragments exist yet — and a
            // constant pitch can't drift against text that isn't there.
            let paper = settings.paperType
            let noteIsEmpty = note?.text.isEmpty ?? true
            if paper == .dots {
                PaperPatternView(
                    type: .dots,
                    ink: inkColor,
                    patternOpacity: PaperType.defaultPatternOpacity * settings.paperStrength,
                    spacingOverride: 16 // editor line pitch approximation
                )
            } else if noteIsEmpty && (paper == .lines || paper == .grid) {
                PaperPatternView(
                    type: paper,
                    ink: inkColor,
                    patternOpacity: PaperType.defaultPatternOpacity * settings.paperStrength,
                    spacingOverride: 19 // ≈ 11pt body line + 2.5 spacing
                )
            }
        }
    }

    // MARK: - Top bar (minimal: roll-up + close)

    private var topBar: some View {
        VStack(spacing: 2) {
            // Row 1: 4 buttons evenly spaced across the panel width.
            // Spacers between each button distribute the remaining space
            // equally so the cluster doesn't feel crammed at the right.
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                // AutoPaste (§9) indicator: small pulsing clipboard glyph
                // while THIS note is collecting. Opacity pulse ONLY — never
                // frame/radius animation (crash invariant). Click = stop
                // (Antinote parity: clicking the blinking icon ends paste
                // mode). Reduce Motion: steady glyph, no pulse.
                if ClipboardCollector.shared.isCollecting(noteID) {
                    let reduceMotion =
                        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    Button(action: { ClipboardCollector.shared.stop() }) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(inkColor.opacity(0.55))
                            .opacity(reduceMotion ? 0.8 : (clipboardPulse ? 1.0 : 0.35))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("クリップボード収集中 — クリックで停止",
                            "Collecting clipboard — click to stop"))
                    .accessibilityLabel(L("クリップボード収集を停止",
                                          "Stop collecting clipboard"))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: clipboardPulse
                    )
                    .onAppear { clipboardPulse = true }
                    .onDisappear { clipboardPulse = false }

                    Spacer(minLength: 0)
                }

                Button(action: copyNoteText) {
                    Image(systemName: showCopiedToast ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(inkColor.opacity(showCopiedToast ? 0.8 : 0.4))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showCopiedToast ? "Copied!" : "Copy text")
                .accessibilityLabel(L("テキストをコピー", "Copy text"))
                // S6 export: right-click (or control-click) on the copy
                // button. Plain left-click behavior is untouched.
                .contextMenu {
                    Button(L("コピー", "Copy")) { copyNoteText() }
                        .disabled(note?.text.isEmpty ?? true)
                    Button(L("Markdown をコピー", "Copy as Markdown")) { copyAsMarkdown() }
                        .disabled(note?.text.isEmpty ?? true)
                    Divider()
                    Button(L("TXT に書き出し", "Export as TXT")) { exportNote(.txt) }
                        .disabled(note?.text.isEmpty ?? true)
                    Button(L("Markdown に書き出し", "Export as Markdown")) { exportNote(.markdown) }
                        .disabled(note?.text.isEmpty ?? true)
                    Button(L("PDF に書き出し", "Export as PDF")) { exportNote(.pdf) }
                        .disabled(note?.text.isEmpty ?? true)
                    Divider()
                    // Send to (landing copy: "Instantly send to Apple
                    // Notes, Obsidian, and Bear."). Install check happens
                    // ON CLICK for Obsidian/Bear — a friendly alert can say
                    // WHY nothing happened; a silently-grey item can't.
                    Menu(L("送信", "Send to")) {
                        Button("Apple Notes") { sendNote(.appleNotes) }
                            .disabled(note?.text.isEmpty ?? true)
                        Button("Obsidian") { sendNote(.obsidian) }
                            .disabled(note?.text.isEmpty ?? true)
                        Button("Bear") { sendNote(.bear) }
                            .disabled(note?.text.isEmpty ?? true)
                    }
                    Divider()
                    // AutoPaste (§9): per-note clipboard collection. Lives
                    // HERE and not in the Organize-pill menu because that
                    // pill is disabled on an EMPTY note — and an empty
                    // scratch note is the collector's prime use case.
                    Toggle(L("クリップボード収集", "Collect clipboard"), isOn: Binding(
                        get: { ClipboardCollector.shared.isCollecting(noteID) },
                        set: { on in
                            if on {
                                ClipboardCollector.shared.start(noteID: noteID)
                            } else {
                                ClipboardCollector.shared.stop()
                            }
                        }
                    ))
                }

                Spacer(minLength: 0)

                // AI auto-sort: uses Claude to pick (or propose) the best
                // group for this note. Falls back to Inbox on error.
                Button(action: runAISort) {
                    Group {
                        if isSorting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.35)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundColor(inkColor.opacity(isSorting ? 0.7 : 0.45))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSorting || (note?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
                .help("AI sort: let Claude pick the best group")
                .accessibilityLabel(L("AI でグループに振り分け", "AI sort into a group"))

                Spacer(minLength: 0)

                Button(action: hideToGroup) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(inkColor.opacity(0.4))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Archive — close panel, note stays in Groups")
                .accessibilityLabel(L("アーカイブ", "Archive"))

                Spacer(minLength: 0)

                Button(action: {
                    // Roll-up is safe during Organize / AI Sort — see the
                    // rolledUpView onTapGesture comment for why. Guard
                    // removed so the user isn't blocked mid-Organize.
                    PanelManager.shared.toggleStow(noteID: noteID)
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(inkColor.opacity(0.4))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Roll up")
                .accessibilityLabel(L("巻き取る", "Roll up"))

                Spacer(minLength: 0)
            }
            .frame(height: 22)
            .padding(.horizontal, 4)

            // Row 2: Organize button, right-aligned under the roll-up/close cluster
            HStack(spacing: 0) {
                Spacer()
                // Organize↔戻す toggle (S1): while a persisted snapshot
                // exists the button reverts instead of re-organizing —
                // organized output can never be organized again (the
                // "summary shrinks forever" accident is structurally gone).
                Button(action: {
                    clearOrganizeHint()
                    hasOrganizeSnapshot ? requestRevert() : organizeNote()
                }) {
                    HStack(spacing: 4) {
                        ZStack {
                            if isOrganizing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: hasOrganizeSnapshot ? "arrow.uturn.backward" : "wand.and.stars")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .frame(width: 12, height: 12)
                        Text(isOrganizing ? "Organizing" : (hasOrganizeSnapshot ? L("戻す", "Revert") : "Organize"))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .frame(minWidth: 78, alignment: .center)
                    // Mock language: Organize is a dark ink pill with light
                    // text — the one strong element on the soft paper.
                    .foregroundColor(Color.white.opacity(isHoveringOrganize ? 1.0 : 0.92))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(inkColor.opacity(isHoveringOrganize ? 0.95 : 0.82))
                    )
                }
                .buttonStyle(.plain)
                // Onboarding hint: gentle scale pulse, driven by its own
                // @State (NEVER stowState — crash invariant).
                .scaleEffect(organizeHintActive && organizeHintPulse ? 1.07 : 1.0)
                .animation(
                    organizeHintActive
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: organizeHintPulse
                )
                .onAppear { if organizeHintActive { organizeHintPulse = true } }
                .accessibilityLabel(hasOrganizeSnapshot
                    ? L("整理を戻す", "Revert organize")
                    : L("AI で整理", "Organize with AI"))
                // First run: this view exists BEFORE onboarding finishes, so
                // the @State snapshot missed the flag — onboarding pokes us.
                .onReceive(NotificationCenter.default.publisher(for: .floteOrganizeHintChanged)) { _ in
                    organizeHintActive = true
                    organizeHintPulse = true
                }
                // AppKit-side features (reminders) borrow the red banner.
                .onReceive(NotificationCenter.default.publisher(for: .floteTransientError)) { note in
                    guard let id = note.userInfo?["noteID"] as? UUID, id == noteID,
                          let msg = note.userInfo?["message"] as? String else { return }
                    showTransientError(msg)
                }
                // Text context menu → the SAME verb/export paths as the
                // pill/copy-button menus (single pipeline, no duplicate
                // logic — the editor only posts requests).
                .onReceive(NotificationCenter.default.publisher(for: .floteRunVerbFromEditor)) { notif in
                    guard let id = notif.userInfo?["noteID"] as? UUID, id == noteID,
                          let raw = notif.userInfo?["verb"] as? String,
                          let verb = NoteVerb(rawValue: raw),
                          !verbActionsDisabled else { return }
                    runVerb(verb)
                }
                .onReceive(NotificationCenter.default.publisher(for: .floteExportFromEditor)) { notif in
                    guard let id = notif.userInfo?["noteID"] as? UUID, id == noteID,
                          let format = notif.userInfo?["format"] as? String,
                          !(note?.text.isEmpty ?? true) else { return }
                    switch format {
                    case "copy-md":       copyAsMarkdown()
                    case "txt":           exportNote(.txt)
                    case "markdown":      exportNote(.markdown)
                    case "pdf":           exportNote(.pdf)
                    // Send-to rides the same editor-menu pipeline as
                    // exports (single pipeline, no duplicate logic).
                    case "send-notes":    sendNote(.appleNotes)
                    case "send-obsidian": sendNote(.obsidian)
                    case "send-bear":     sendNote(.bear)
                    default: break
                    }
                }
                .disabled(isOrganizing || (!hasOrganizeSnapshot && (note?.text.isEmpty ?? true)))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) { isHoveringOrganize = hovering }
                }
                // S6 verb menu: right-click (control-click) on the Organize
                // pill. Plain tap behavior is untouched. Verbs share
                // Organize's guards: while a snapshot exists nothing can be
                // re-transformed (the "summary shrinks forever" protection
                // covers verbs too) — 戻す first, then transform again.
                .contextMenu {
                    Button(L("整理（Organize）", "Organize")) { organizeNote() }
                        .disabled(verbActionsDisabled)
                    Divider()
                    ForEach(NoteVerb.allCases) { verb in
                        Button(verb.menuLabel) { runVerb(verb) }
                            .disabled(verbActionsDisabled)
                    }
                    if hasOrganizeSnapshot {
                        Divider()
                        Button(L("戻す", "Revert")) { requestRevert() }
                            .disabled(isOrganizing)
                    }
                    Divider()
                    if note?.isLocked ?? false {
                        Button(L("ロックを解除する（Touch ID）", "Remove lock (Touch ID)")) {
                            NoteManager.shared.updateLocked(id: noteID, locked: false)
                            isUnlockedThisSession = false
                        }
                    } else {
                        Button(L("このノートをロック（Touch ID）", "Lock this note (Touch ID)")) {
                            NoteManager.shared.updateLocked(id: noteID, locked: true)
                            isUnlockedThisSession = false
                        }
                    }
                }
                .padding(.trailing, 6)
                .alert(L("整理前に戻しますか？", "Revert to before Organize?"), isPresented: $showRevertEditedConfirm) {
                    Button(L("キャンセル", "Cancel"), role: .cancel) {}
                    Button(L("戻す", "Revert"), role: .destructive) { performRevert() }
                } message: {
                    Text(L("整理後にこのノートを編集しています。戻すと、その編集は失われます（走り書きが復元されます）。", "You edited this note after organizing. Reverting discards those edits (the original scribble comes back)."))
                }
            }
        }
    }

    // MARK: - Organize↔戻す helpers (S1)

    /// Persisted on the note itself, so the toggle survives restart.
    private var hasOrganizeSnapshot: Bool {
        note?.organizeOriginalPlain != nil
    }

    /// Content protection: edits made AFTER Organize are never discarded
    /// silently — confirm first. An unedited organized note reverts
    /// immediately (lossless: snapshot holds exact rich text + title).
    private func requestRevert() {
        guard !isOrganizing else { return }
        if NoteManager.shared.hasUserEditsAfterOrganize(id: noteID) {
            showRevertEditedConfirm = true
        } else {
            performRevert()
        }
    }

    private func performRevert() {
        NoteManager.shared.revertOrganize(id: noteID)
        reloadTrigger += 1
    }

    // MARK: - Verb menu (S6)

    /// Verbs share Organize's own disabled conditions PLUS the snapshot
    /// guard: while 戻す is armed, nothing may transform the note again.
    private var verbActionsDisabled: Bool {
        isOrganizing || isSorting || hasOrganizeSnapshot || (note?.text.isEmpty ?? true)
    }

    /// S6 verb: identical lifecycle to organizeNote — snapshot the exact
    /// pre-transform state → transform → apply via updateRichText → persist
    /// the snapshot so the button flips to 戻す. The rolled title is
    /// intentionally NOT touched: verbs reshape the body, they don't
    /// retitle the note (the snapshot still carries the title, so 戻す
    /// stays lossless either way).
    private func runVerb(_ verb: NoteVerb) {
        guard !isOrganizing, !isSorting, !hasOrganizeSnapshot else { return }
        guard let note = note, !note.text.isEmpty else { return }
        // Snapshot pre-transform state (content-protection principle: a
        // verb result must never silently destroy text).
        let prevRichData = note.richTextData
        let prevPlain = note.text
        let prevTitle = note.rolledTitle
        isOrganizing = true
        organizeError = nil
        showErrorOverlay = false
        Task {
            do {
                let result = try await OrganizeService.shared.transform(
                    text: note.text,
                    instruction: verb.instruction
                )
                // Last line of defense — the providers already throw on
                // empty output, but an empty result must NEVER blank a note.
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIProviderError.emptyResult
                }
                let (font, ink) = await MainActor.run {
                    (FontPreference.shared.current.nsFont(size: 11, weight: .regular),
                     FloteInk.text(legacyTheme: note.colorTheme.rawValue))
                }
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.lineSpacing = 2.5
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: ink,
                    .paragraphStyle: paraStyle
                ]
                let attrStr = NSAttributedString(string: result, attributes: attrs)
                let data = RichTextStorage.archive(attrStr)

                await MainActor.run {
                    guard NoteManager.shared.note(byID: noteID) != nil else {
                        print("[Flote] \(verb.menuLabel) cancelled: note \(noteID) removed")
                        return
                    }
                    // Content protection (Evaluator #1): keystrokes typed
                    // while the verb was in flight beat the regenerable AI
                    // result — discard on mismatch, never overwrite.
                    guard NoteManager.shared.note(byID: noteID)?.text == prevPlain else {
                        isOrganizing = false
                        print("[Flote] \(verb.menuLabel) discarded: note edited mid-flight")
                        return
                    }
                    NoteManager.shared.updateRichText(id: noteID, data: data, plainText: result)
                    // SAME snapshot mechanism as Organize: 戻す survives
                    // restart, and re-transforming is structurally blocked
                    // until the user reverts.
                    NoteManager.shared.setOrganizeSnapshot(
                        id: noteID,
                        originalRichData: prevRichData,
                        originalPlain: prevPlain,
                        originalTitle: prevTitle,
                        organizedPlain: result
                    )
                    NoteManager.shared.cancelPendingSave()
                    NoteManager.shared.save()
                    reloadTrigger += 1

                    // ⌘Z parity with Organize (see organizeNote for why the
                    // registration is deferred one run-loop tick).
                    let um = PanelManager.shared.undoManager(for: noteID)
                        ?? NSApp.keyWindow?.undoManager
                        ?? NSApp.mainWindow?.undoManager
                    let capturedNoteID = noteID
                    DispatchQueue.main.async {
                        NoteManager.shared.registerOrganizeUndo(
                            id: capturedNoteID,
                            prevData: prevRichData,
                            prevPlain: prevPlain,
                            prevTitle: prevTitle,
                            undoManager: um
                        )
                    }
                }
            } catch {
                let msg = error.localizedDescription
                print("[Flote] \(verb.menuLabel) failed: \(msg)")
                await MainActor.run { showTransientError(msg) }
            }
            await MainActor.run { isOrganizing = false }
        }
    }

    /// Shared red banner (same UX as an Organize failure): show for 5 s,
    /// auto-dismiss, cancel any previous timer first.
    @MainActor
    private func showTransientError(_ msg: String) {
        organizeError = msg
        withAnimation { showErrorOverlay = true }
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
                withAnimation { showErrorOverlay = false }
            } catch {
                // Cancelled — a newer error owns the banner now.
            }
        }
    }

    private func copyNoteText() {
        guard let note = note else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Include both rich and plain representations so either format works.
        // If richTextData exists but fails to unarchive (corrupted from a
        // partial save), we log and fall through to plain-text only.
        if let data = note.richTextData {
            if let attr = RichTextStorage.unarchive(data),
               let rtfData = try? attr.data(
                   from: NSRange(location: 0, length: attr.length),
                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
               ) {
                pasteboard.setData(rtfData, forType: .rtf)
            } else {
                print("[Flote] Rich text unarchive failed; using plain text only")
            }
        }
        pasteboard.setString(Self.egressText(of: note), forType: .string)
        // AutoPaste: our own copies must never echo into a collecting note.
        ClipboardCollector.shared.noteInternalCopy()
        withAnimation(.easeInOut(duration: 0.15)) {
            showCopiedToast = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCopiedToast = false
                }
            }
        }
    }

    // MARK: - Export & copy-as-markdown (S6)

    /// Egress text: note.text with every shrunk-link display form expanded
    /// back to its FULL url (eval-protection FAIL 2026-07-11: exports /
    /// send-to / copy shipped "domain/…/tail" with a literal ellipsis —
    /// silent loss of user-pasted URLs outside the app). Walks the rich
    /// storage's .floteShrunkLink runs; notes without rich data (or with
    /// no shrunk runs) return note.text unchanged.
    static func egressText(of note: StickyNote) -> String {
        guard let data = note.richTextData,
              let attr = RichTextStorage.unarchive(data) else { return note.text }
        let full = NSMutableString(string: attr.string)
        var replacements: [(NSRange, String)] = []
        attr.enumerateAttribute(
            NSAttributedString.Key("floteShrunkLink"),
            in: NSRange(location: 0, length: attr.length)
        ) { value, range, _ in
            if let original = value as? String { replacements.append((range, original)) }
        }
        guard !replacements.isEmpty else { return note.text }
        for (range, original) in replacements.reversed() {
            full.replaceCharacters(in: range, with: original)
        }
        return full as String
    }

    /// note.text is markdown-ish (Organize emits "- " bullets; headers stay
    /// "## ") except the checkbox tokens: storage uses bare "[ ]"/"[✓]"
    /// (FloteLayoutManager renders circles from those literals), which GFM
    /// does not recognize. Exported markdown converts leading tokens to
    /// GFM task items ("- [ ]"/"- [x]"); storage is never touched.
    private static func gfmMarkdown(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
            let rest = line.dropFirst(leading.count)
            if rest.hasPrefix("[ ] ") || rest == "[ ]" {
                return String(leading) + "- [ ]" + String(rest.dropFirst(3))
            }
            if rest.hasPrefix("[\u{2713}] ") || rest == "[\u{2713}]" {
                return String(leading) + "- [x]" + String(rest.dropFirst(3))
            }
            return String(line)
        }.joined(separator: "\n")
    }

    /// Plain-string-only pasteboard, no RTF, so pasting into a markdown
    /// editor keeps the syntax literal.
    private func copyAsMarkdown() {
        guard let note = note, !note.text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.gfmMarkdown(from: Self.egressText(of: note)), forType: .string)
        // AutoPaste: our own copies must never echo into a collecting note.
        ClipboardCollector.shared.noteInternalCopy()
        flashCopiedToast()
    }

    private func flashCopiedToast() {
        withAnimation(.easeInOut(duration: 0.15)) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { showCopiedToast = false }
            }
        }
    }

    /// NSSavePanel export. Sandbox-safe: the panel's user-selected URL is
    /// writable under the user-selected-file R/W entitlement — no extra
    /// security scoping needed for a fresh save-panel grant.
    private func exportNote(_ format: NoteExportFormat) {
        guard let note = note, !note.text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.exportFileName(for: note) + "." + format.fileExtension
        // Flote is an accessory app whose notes live in nonactivating
        // panels — without explicit activation the save panel can open
        // BEHIND the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .txt:
                try Data(Self.egressText(of: note).utf8).write(to: url, options: .atomic)
            case .markdown:
                try Data(Self.gfmMarkdown(from: Self.egressText(of: note)).utf8).write(to: url, options: .atomic)
            case .pdf:
                try Self.renderPDF(note: note, to: url)
            }
        } catch {
            print("[Flote] Export failed: \(error.localizedDescription)")
            showTransientError(L("書き出しに失敗しました", "Export failed") + "（\(error.localizedDescription)）")
        }
    }

    /// Default filename = the note's display title, filesystem-sanitized.
    private static func exportFileName(for note: StickyNote) -> String {
        let raw = note.lockedSafeTitle ?? "Flote Note"
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Flote Note" : cleaned
    }

    /// A4 page (595.2 x 841.8 pt), 56 pt margins. Draws the note's
    /// attributed string through CoreText pagination — no NSPrintOperation,
    /// no WebView, sandbox-clean. Falls back to a plain-text rendering when
    /// richTextData is missing or fails to unarchive (same tolerance as
    /// copyNoteText).
    @MainActor
    private static func renderPDF(note: StickyNote, to url: URL) throws {
        let attr: NSAttributedString
        if let data = note.richTextData,
           let unarchived = RichTextStorage.unarchive(data),
           unarchived.length > 0 {
            attr = unarchived
        } else {
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.lineSpacing = 2.5
            attr = NSAttributedString(string: Self.egressText(of: note), attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: FloteInk.text(legacyTheme: note.colorTheme.rawValue),
                .paragraphStyle: paraStyle
            ])
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let textRect = mediaBox.insetBy(dx: 56, dy: 56)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        var location = 0
        let total = attr.length
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: location, length: 0), path, nil
            )
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            // Guard: zero progress (e.g. one glyph taller than the page)
            // must never loop forever — advance at least one character.
            location += max(visible.length, 1)
        } while location < total
        ctx.closePDF()
    }

    // MARK: - Send to Apple Notes / Obsidian / Bear

    /// Single entry for both surfaces (copy-button submenu + editor menu).
    /// Gate = the SAME structural gate exports use: both surfaces exist
    /// only inside the unlocked expanded view. The explicit lock re-check
    /// is fail-closed defense for the notification path, where lock state
    /// could in principle flip between post and receive.
    private func sendNote(_ target: NoteSendTarget) {
        guard let note = note, !note.text.isEmpty,
              !(note.isLocked && !isUnlockedThisSession) else { return }
        // Same title recipe as export: display title, else first content
        // line, else a neutral constant. Content is the PLAIN text.
        let title = note.lockedSafeTitle
            ?? Self.firstContentLine(of: note.text)
            ?? "Flote Note"
        switch target {
        case .appleNotes:
            sendToAppleNotes(title: title, text: Self.egressText(of: note))
        case .obsidian:
            openSchemeURL(FloteSendTo.obsidianURLString(content: Self.egressText(of: note)),
                          target: target)
        case .bear:
            openSchemeURL(FloteSendTo.bearURLString(title: title, text: Self.egressText(of: note)),
                          target: target)
        }
    }

    /// NSAppleScript runs main-thread; the first send triggers the macOS
    /// automation consent prompt (expected — the OS owns that UX; Info.plist
    /// carries NSAppleEventsUsageDescription, entitlements carry the
    /// sandbox apple-events exception for com.apple.notes). A denial or
    /// script failure surfaces on the existing transient-error banner.
    /// Success is silent — Notes creates the note in the background without
    /// stealing focus, matching the export flows' quiet finish.
    private func sendToAppleNotes(title: String, text: String) {
        let source = FloteSendTo.appleNotesScript(name: title, plainText: text)
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?
            .executeAndReturnError(&errorInfo)
        if result == nil {
            let detail = (errorInfo?[NSAppleScript.errorMessage] as? String)
                ?? L("不明なエラー", "unknown error")
            print("[Flote] Send to Apple Notes failed: \(detail)")
            showTransientError(
                L("Apple Notes への送信に失敗しました", "Couldn't send to Apple Notes")
                    + "（\(detail)）")
        }
    }

    /// Obsidian / Bear: install check first (NSWorkspace.urlForApplication
    /// is the canOpenURL equivalent on macOS) — a missing app gets a
    /// friendly alert, never a dead click.
    private func openSchemeURL(_ urlString: String, target: NoteSendTarget) {
        if let scheme = target.installProbeScheme {
            guard let probe = URL(string: scheme + "://"),
                  NSWorkspace.shared.urlForApplication(toOpen: probe) != nil else {
                presentAppMissingAlert(appName: target.appName)
                return
            }
        }
        guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
            showTransientError(
                L("\(target.appName) に送信できませんでした",
                  "Couldn't send to \(target.appName)"))
            return
        }
    }

    private func presentAppMissingAlert(appName: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("\(appName) が見つかりません",
                              "\(appName) isn't installed")
        alert.informativeText = L(
            "この Mac に \(appName) がインストールされていないため、送信できませんでした。インストール後にもう一度お試しください。",
            "Flote couldn't find \(appName) on this Mac, so the note wasn't sent. Install \(appName) and try again.")
        alert.addButton(withTitle: "OK")
        // Accessory app: without explicit activation the alert can open
        // BEHIND the frontmost app (same fix as the export save panel).
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Bottom bar removed — Organize moved to top bar

    // MARK: - Actions

    /// Close the floating panel without removing the note. The note keeps its
    /// group membership; the user can bring it back from the Groups tab.
    /// Empty scratch notes (never Organized, no content) are simply dropped
    /// rather than polluting any group.
    private func hideToGroup() {
        // Block while Organize/AI sort is in flight. If we remove the note
        // now, the pending Task would try to update a ghost when it returns.
        guard !isOrganizing, !isSorting else { return }
        // S16 deck-aware: archives the SHOWN note; a deck panel advances
        // to the next member (deck of 1 = closes, the old behavior).
        PanelManager.shared.closeShownNote(noteID: noteID, archive: true)
    }

    /// AI auto-sort: ask the model to pick (or create) the best group for
    /// this note given the existing group list. Falls back to Inbox on error.
    private func runAISort() {
        // Hard lock: never overlap with Organize (API contention + state race).
        guard !isSorting, !isOrganizing else { return }
        guard let note = note,
              !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        isSorting = true
        let groups = GroupManager.shared.groups
        Task {
            let result: OrganizeService.ClassifyResult
            do {
                result = try await OrganizeService.shared.classify(
                    text: note.text,
                    existingGroups: groups
                )
            } catch {
                print("[Flote] AI sort failed, falling back to Inbox: \(error)")
                await MainActor.run {
                    isSorting = false
                    parkInInbox()
                }
                return
            }
            await MainActor.run {
                isSorting = false
                applyClassifyResult(result)
            }
        }
    }

    /// Put this note in Inbox and close its panel (used as a fallback).
    private func parkInInbox() {
        GroupManager.shared.ensureInboxExists()
        guard let inboxID = GroupManager.shared.inboxID else { return }
        NoteManager.shared.moveNote(id: noteID, toGroup: inboxID)
        NoteManager.shared.closePanel(noteID: noteID)
        // S16 deck-aware put-away: the panel advances to the next deck
        // member instead of vanishing under the user (deck of 1 = closes).
        PanelManager.shared.closeShownNote(noteID: noteID, archive: false)
    }

    private func applyClassifyResult(_ result: OrganizeService.ClassifyResult) {
        GroupManager.shared.ensureInboxExists()
        let targetID: UUID
        switch result {
        case .existing(let id):
            if GroupManager.shared.group(byID: id) != nil {
                targetID = id
            } else {
                targetID = GroupManager.shared.inboxID ?? id
            }
        case .newGroup(let name):
            let icon = GroupManager.iconForGroupName(name)
            let color = GroupManager.colorHexForGroupName(name)
            let group = GroupManager.shared.createGroup(name: name, icon: icon, colorHex: color)
            targetID = group.id
        case .inbox:
            targetID = GroupManager.shared.inboxID ?? UUID()
        }
        // AI sort = "put this away": move into the chosen group AND close the
        // panel. The note is always retrievable from the Groups tab.
        NoteManager.shared.moveNote(id: noteID, toGroup: targetID)
        NoteManager.shared.closePanel(noteID: noteID)
        // S16 deck-aware put-away (same tail as parkInInbox above).
        PanelManager.shared.closeShownNote(noteID: noteID, archive: false)
    }

    /// First Organize ends the onboarding pulse for good.
    private func clearOrganizeHint() {
        guard organizeHintActive else { return }
        organizeHintPulse = false
        organizeHintActive = false
        UserDefaults.standard.removeObject(
            forKey: OnboardingWindowController.organizeHintKey)
    }

    private func organizeNote() {
        guard !isOrganizing, !isSorting else { return }
        guard let note = note, !note.text.isEmpty else { return }
        // Snapshot pre-organize state for undo.
        let prevRichData = note.richTextData
        let prevPlain = note.text
        let prevTitle = note.rolledTitle
        isOrganizing = true
        organizeError = nil
        showErrorOverlay = false
        Task {
            do {
                let result = try await OrganizeService.shared.organize(text: note.text)
                let (font, ink) = await MainActor.run {
                    (FontPreference.shared.current.nsFont(size: 11, weight: .regular),
                     FloteInk.text(legacyTheme: note.colorTheme.rawValue))
                }
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.lineSpacing = 2.5
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: ink,
                    .paragraphStyle: paraStyle
                ]
                let attrStr = NSAttributedString(string: result, attributes: attrs)
                let data = RichTextStorage.archive(attrStr)

                await MainActor.run {
                    guard NoteManager.shared.note(byID: noteID) != nil else {
                        // M1-1: log cancellation so Organize race conditions are
                        // visible in the console without crashing.
                        print("[Flote] Organize cancelled: note \(noteID) removed")
                        return
                    }
                    // Content protection (Evaluator #1): if the user typed
                    // while the AI was in flight, the note no longer matches
                    // the snapshot we sent — applying would silently destroy
                    // those keystrokes. Discard the AI result instead (it is
                    // regenerable; the user's keystrokes are not).
                    guard NoteManager.shared.note(byID: noteID)?.text == prevPlain else {
                        isOrganizing = false
                        print("[Flote] Organize discarded: note edited mid-flight")
                        return
                    }

                    // Prefer the explicit `## タイトル` section. If the model
                    // omitted it (happens with short notes or non-compliant
                    // output), fall back to the first non-empty, non-header
                    // line so the scroll never ends up blank. Only overwrite
                    // the stored title when we actually have something — a nil
                    // extraction must not wipe a previously-set rolled title.
                    if let title = Self.extractTitle(from: result)
                        ?? Self.firstContentLine(of: result) {
                        NoteManager.shared.updateRolledTitle(id: noteID, title: title)
                    }
                    NoteManager.shared.updateRichText(id: noteID, data: data, plainText: result)

                    if NoteManager.shared.note(byID: noteID)?.groupID == nil {
                        GroupManager.shared.ensureInboxExists()
                        if let inboxID = GroupManager.shared.inboxID {
                            NoteManager.shared.moveNote(id: noteID, toGroup: inboxID)
                        }
                    }

                    // S1 Organize↔戻す: persist the pre-organize state on the
                    // note (survives restart) — the button flips to 戻す and
                    // re-organizing organized output becomes impossible.
                    NoteManager.shared.setOrganizeSnapshot(
                        id: noteID,
                        originalRichData: prevRichData,
                        originalPlain: prevPlain,
                        originalTitle: prevTitle,
                        organizedPlain: result
                    )

                    NoteManager.shared.cancelPendingSave()
                    NoteManager.shared.save()
                    reloadTrigger += 1

                    // Defer undo registration to the next run-loop tick so that
                    // updateNSView's reloadTrigger-driven undo-manager clear
                    // completes first. Use NoteManager directly to avoid the
                    // weak-reference silent failure when the panel is closed.
                    // Prefer the undoManager of the note's own panel so ⌘Z
                    // works even if Settings or another note is currently key.
                    // Falls back to key/main only when the panel was closed
                    // before the async dispatch fires.
                    let um = PanelManager.shared.undoManager(for: noteID)
                        ?? NSApp.keyWindow?.undoManager
                        ?? NSApp.mainWindow?.undoManager
                    let capturedPrevRichData = prevRichData
                    let capturedPrevPlain = prevPlain
                    let capturedPrevTitle = prevTitle
                    let capturedNoteID = noteID
                    DispatchQueue.main.async {
                        NoteManager.shared.registerOrganizeUndo(
                            id: capturedNoteID,
                            prevData: capturedPrevRichData,
                            prevPlain: capturedPrevPlain,
                            prevTitle: capturedPrevTitle,
                            undoManager: um
                        )
                    }
                }
            } catch {
                let msg = error.localizedDescription
                print("[Flote] Organize failed: \(msg)")
                await MainActor.run {
                    organizeError = msg
                    withAnimation { showErrorOverlay = true }
                    // Cancel any previous dismiss timer before starting a new one
                    // so rapid consecutive failures don't cause premature dismissal.
                    errorDismissTask?.cancel()
                    errorDismissTask = Task { @MainActor in
                        do {
                            try await Task.sleep(for: .seconds(5))
                            withAnimation { showErrorOverlay = false }
                        } catch {
                            // Task was cancelled (e.g. new error arrived or view disappeared).
                        }
                    }
                }
            }
            await MainActor.run { isOrganizing = false }
        }
    }

    /// Fallback when the Organize output lacks a `## タイトル` section.
    /// Picks the first non-blank, non-header, non-list line and clips to 12
    /// glyphs so the rolled scroll doesn't try to render a paragraph. Also
    /// skips pure date/time lines so fallbacks don't inherit the same
    /// "4月17日 10:30-"-as-title problem the LLM prompt now forbids.
    private static func firstContentLine(of result: String) -> String? {
        for raw in result.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty,
                  !t.hasPrefix("#"),
                  !t.hasPrefix("-"),
                  !t.hasPrefix("*"),
                  !t.hasPrefix("[ ]"),
                  !t.hasPrefix("[x]"),
                  !t.hasPrefix("[\u{2713}]"),
                  !StickyNote.looksLikeDateTimeOnly(t) else { continue }
            let cleaned = t.trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
            return cleaned.count > 12 ? String(cleaned.prefix(12)) : cleaned
        }
        return nil
    }

    /// Parses the `## タイトル` section from the Organize result.
    /// Returns the first non-empty line following that header, trimmed.
    private static func extractTitle(from result: String) -> String? {
        let lines = result.components(separatedBy: "\n")
        var seenHeader = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if seenHeader {
                // Skip blank lines between header and content.
                if trimmed.isEmpty { continue }
                // Stop if we hit the next section.
                if trimmed.hasPrefix("##") { return nil }
                // Strip any leading markdown emphasis.
                return trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
            }
            // Accept ## タイトル or # タイトル
            if trimmed.hasPrefix("## タイトル") || trimmed.hasPrefix("# タイトル") {
                seenHeader = true
            }
        }
        return nil
    }
}


