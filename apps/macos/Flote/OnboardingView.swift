import AppKit
import SwiftUI

// MARK: - First-run onboarding (S5, plan: goal-loop-sleepy-castle.md)
//
// One-time ~30-second setup shown on first launch, then never again
// (requirements v0.2: visual, zero interruption afterwards). Five steps:
//
//   1. 言語 / Language   — JP/EN choice; all onboarding copy switches live.
//   2. 使い方            — self-drawn ⌥Space → scribble → Organize diagram.
//   3. 3 つのキー        — the power gestures (⌥Space new note, ⌥⇧A
//                          hide/show all, ⌥⇧Space search) as keycap rows.
//                          An LSUIElement app has no Dock icon or window
//                          list to rediscover it from: these keys ARE the
//                          front door, so they get their own step.
//   4. AI セットアップ    — on-device options (Apple Intelligence probe +
//                          bundled local model download) with a prominent
//                          skip; the user is NEVER blocked on AI.
//   5. スタイル          — starting NoteColorTheme pick.
//
// WIRING (done by the lead, not this file): AppDelegate calls
//   `OnboardingWindowController.shared.showIfNeeded()`
// after launch setup. Consumption of "floteDefaultTheme" is wired later too.
//
// i18n NOTE: "floteLanguage" currently drives ONBOARDING copy only. Full app
// i18n (Settings, menus, note UI) is future work — the key is persisted here
// so that work has a source of truth for the user's choice.
//
// CLOSE SEMANTICS: finishing (はじめる) marks onboarding completed. Closing
// the window early marks it completed ONLY if the user reached step 2 (they
// have seen ⌥Space — without it an LSUIElement app is undiscoverable). If
// closed on step 1 the flow shows once more at next launch.

// MARK: - Window controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    /// Absent key = first run. Set to true on finish (or early close after
    /// the hotkey step — see file header).
    static let completedDefaultsKey = "floteOnboardingCompleted"
    /// "ja" / "en" — persisted by the flow's step 1 (see i18n note above).
    nonisolated static let languageDefaultsKey = "floteLanguage"
    /// NoteColorTheme.rawValue chosen in the final style step. Consumed by
    /// the lead later (NoteManager default for newly created notes).
    static let defaultThemeDefaultsKey = "floteDefaultTheme"

    static var needsOnboarding: Bool {
        UserDefaults.standard.object(forKey: completedDefaultsKey) == nil
    }

    private var window: NSWindow?
    /// True once the user has seen the ⌥Space explainer (step index >= 1).
    private var reachedHotkeyStep = false

    private override init() { super.init() }

    /// Idempotent: shows the onboarding window on first run, no-op otherwise.
    /// Safe to call unconditionally from applicationDidFinishLaunching.
    func showIfNeeded() {
        guard Self.needsOnboarding else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let flow = OnboardingFlow(
            onStepShown: { [weak self] index in
                if index >= 1 { self?.reachedHotkeyStep = true }
            },
            onFinish: { [weak self] in
                self?.completeAndClose()
            }
        )

        let hosting = NSHostingController(rootView: flow)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Flote"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // .floating so the LSUIElement accessory app's onboarding is actually
        // visible above whatever the user was doing (same level family as the
        // note panels).
        window.level = .floating
        window.setContentSize(NSSize(width: 640, height: 520))
        window.center()
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Set when the demo scribble has been placed (exactly once, ever).
    static let demoNoteCreatedKey = "floteDemoNoteCreated"
    /// Read by NoteView: the Organize pill pulses until the first Organize.
    static let organizeHintKey = "floteOrganizeHintPending"

    private func completeAndClose() {
        Self.markCompleted()
        applyOnboardingChoices()
        window?.close() // windowWillClose performs the cleanup
    }

    /// Consume the flow's persisted choices (theme + demo note). The launch
    /// path always opens one EMPTY note before onboarding shows — the demo
    /// scribble fills that note. A note the user already typed into is never
    /// touched (content protection), and the whole step runs exactly once.
    private func applyOnboardingChoices() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.demoNoteCreatedKey) else { return }
        defaults.set(true, forKey: Self.demoNoteCreatedKey)

        let manager = NoteManager.shared
        let target: StickyNote
        if let empty = manager.notes.first(where: { $0.text.isEmpty }) {
            target = empty
        } else if manager.notes.isEmpty {
            target = manager.createNote()
            PanelManager.shared.createPanel(for: target)
        } else {
            // Every note carries user content (defaults were reset on an
            // existing install) — a demo would only be clutter.
            return
        }

        if let raw = defaults.string(forKey: Self.defaultThemeDefaultsKey),
           let chosen = NoteColorTheme(rawValue: raw) {
            manager.updateColorTheme(id: target.id, theme: chosen)
        }
        let lang = defaults.string(forKey: Self.languageDefaultsKey) ?? "ja"
        let demo = Self.demoScribble(japanese: lang != "en")
        manager.updateText(id: target.id, text: demo)
        // Push into the already-open editor (updateText only touches the model).
        PanelManager.shared.reloadTextView(for: target.id, data: nil, plain: demo)
        defaults.set(true, forKey: Self.organizeHintKey)
        // The launch panel's NoteView was created BEFORE onboarding finished,
        // so its @State snapshot of the hint flag is stale — poke it live.
        NotificationCenter.default.post(name: .floteOrganizeHintChanged, object: nil)
    }

    /// A believable messy scribble that shows Organize off well — clearly
    /// labeled a demo so deleting it feels safe. Besides the pulsing
    /// Organize pill, three lines sit one action away from a feature
    /// firing (each trigger verified against the shipped code):
    ///   - 「明日15時 …」 right-click → the detected time leads the
    ///     reminder submenu (RichTextEditor.detectedFutureDate).
    ///   - 値段 : 480 defines a reactive variable, so typing = right
    ///     after 値段*3 prints the answer inline (FloteCalc.variables).
    ///   - the [ ] pair renders as tappable checkboxes.
    /// The ← hints live ON the armed lines so the caret has an obvious
    /// destination; a = typed mid-line still evaluates the line prefix,
    /// so the hint text after the arrow never breaks the calc.
    private static func demoScribble(japanese: Bool) -> String {
        japanese
            ? """
              （デモ用のメモです。そのまま消して大丈夫）
              [ ] 牛乳 卵 食パン
              [ ] ジム 19時から
              明日15時 佐藤さんに返信 ← この行を右クリック
              値段 : 480
              値段*3 ← すぐうしろで = と打つ
              アイデア: 走り書きが勝手に片付くアプリ
              """
            : """
              (A demo note — feel free to delete it)
              [ ] milk eggs bread
              [ ] gym at 7pm
              tomorrow 3pm reply to Sarah ← right-click this line
              price : 480
              price*3 ← type = right here
              idea: scribbles that tidy themselves
              """
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedDefaultsKey)
    }

    func windowWillClose(_ notification: Notification) {
        if reachedHotkeyStep { Self.markCompleted() }
        window?.delegate = nil
        window = nil
    }
}

// MARK: - Language

/// Onboarding-copy language. Raw values are BCP-47-ish and intentionally
/// stable — future full-app i18n keys off this same UserDefaults value.
enum OnboardingLanguage: String, CaseIterable {
    case japanese = "ja"
    case english = "en"

    /// Stored choice if present, else guessed from the system language.
    static var initialGuess: OnboardingLanguage {
        if let stored = UserDefaults.standard.string(forKey: OnboardingWindowController.languageDefaultsKey),
           let lang = OnboardingLanguage(rawValue: stored) {
            return lang
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("ja") ? .japanese : .english
    }

    func pick(_ ja: String, _ en: String) -> String {
        self == .japanese ? ja : en
    }
}

// MARK: - Palette (warm paper identity, matches the LP / pastel notes)

private enum OnboardingPalette {
    static let paper     = Color(red: 0.993, green: 0.965, blue: 0.915)
    static let paperDeep = Color(red: 0.972, green: 0.933, blue: 0.868)
    static let accent    = Color(red: 0.85, green: 0.62, blue: 0.13)
    static let ink       = Color(red: 0.24,  green: 0.20,  blue: 0.15)
    static let inkSoft   = Color(red: 0.47,  green: 0.41,  blue: 0.34)
    static let card      = Color.white.opacity(0.62)
    static let ok        = Color(red: 0.27,  green: 0.58,  blue: 0.35)
    static let warn      = Color(red: 0.78,  green: 0.44,  blue: 0.10)
}

// MARK: - Apple Intelligence probe state

/// Local mirror of the FoundationModels availability probe so the AI step
/// can render a status line without re-probing on every body evaluation.
enum AppleAIStatus {
    case checking
    case available
    case unavailable(AIProviderUnavailableReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// MARK: - Flow root

struct OnboardingFlow: View {
    /// Called with the 0-based step index whenever a step becomes visible
    /// (drives the controller's close-marking logic).
    var onStepShown: (Int) -> Void = { _ in }
    var onFinish: () -> Void = {}

    @State private var step = 0
    @State private var forward = true
    @State private var language: OnboardingLanguage = .initialGuess
    @State private var selectedTheme: NoteColorTheme = .yellow
    @State private var appleAI: AppleAIStatus = .checking

    private let stepCount = 5

    private func L(_ ja: String, _ en: String) -> String { language.pick(ja, en) }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(count: stepCount, current: step)
                .padding(.top, 30)
                .padding(.bottom, 6)

            ZStack {
                content
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 640, height: 520)
        .background(paperBackground)
        .onAppear { onStepShown(step) }
        .onChange(of: step) { _, newStep in
            onStepShown(newStep)
        }
        .onChange(of: language) { _, newLanguage in
            UserDefaults.standard.set(
                newLanguage.rawValue,
                forKey: OnboardingWindowController.languageDefaultsKey
            )
        }
        .task { await probeAppleAI() }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:  LanguageStep(language: $language)
        case 1:  HowItWorksStep(language: language)
        case 2:  PowerKeysStep(language: language)
        case 3:  AISetupStep(language: language, appleAI: appleAI)
        default: StyleStep(language: language, selectedTheme: $selectedTheme)
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: Chrome

    private var paperBackground: some View {
        ZStack {
            LinearGradient(
                colors: [OnboardingPalette.paper, OnboardingPalette.paperDeep],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [OnboardingPalette.accent.opacity(0.10), .clear],
                center: .topLeading, startRadius: 0, endRadius: 430
            )
        }
        .ignoresSafeArea()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button(L("戻る", "Back")) { go(to: step - 1) }
                    .buttonStyle(OnboardingQuietButtonStyle())
            }
            Spacer()
            if step < stepCount - 1 {
                Button(nextLabel) { go(to: step + 1) }
                    .buttonStyle(OnboardingAccentButtonStyle())
            } else {
                Button(L("はじめる", "Start")) { finish() }
                    .buttonStyle(OnboardingAccentButtonStyle())
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// On the AI step the primary button doubles as the prominent skip:
    /// when nothing is set up it reads 「あとで設定」 (never blocks), and
    /// flips to 「次へ」 once Apple AI is available or a download is
    /// running/done.
    private var nextLabel: String {
        guard step == 3 else { return L("次へ", "Next") }
        let localEngaged: Bool
        switch LocalModelStore.shared.state {
        case .downloading, .ready: localEngaged = true
        default:                   localEngaged = false
        }
        if appleAI.isAvailable || localEngaged { return L("次へ", "Next") }
        return L("あとで設定", "Set up later")
    }

    // MARK: Actions

    private func go(to target: Int) {
        forward = target > step
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            step = max(0, min(stepCount - 1, target))
        }
    }

    private func finish() {
        UserDefaults.standard.set(
            language.rawValue,
            forKey: OnboardingWindowController.languageDefaultsKey
        )
        // FloteL10n may have resolved before this choice existed — sync the
        // live singleton so the app speaks the chosen language immediately.
        FloteL10n.shared.set(language.rawValue)
        UserDefaults.standard.set(
            selectedTheme.rawValue,
            forKey: OnboardingWindowController.defaultThemeDefaultsKey
        )
        onFinish()
    }

    private func probeAppleAI() async {
        guard let provider = FoundationModelsProviderFactory.make() else {
            // Factory returns nil below macOS 26 / without the SDK.
            appleAI = .unavailable(.osTooOld)
            return
        }
        switch await provider.availability() {
        case .available:
            appleAI = .available
        case .unavailable(let reason):
            appleAI = .unavailable(reason)
        }
    }
}

// MARK: - Step 1: Language

private struct LanguageStep: View {
    @Binding var language: OnboardingLanguage

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 10) {
                Text("Flote")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(3.5)
                    .foregroundStyle(OnboardingPalette.accent)
                Text(language.pick("ようこそ", "Welcome"))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(OnboardingPalette.ink)
                Text(language.pick("まず、言葉を選んでください", "First, pick your language"))
                    .font(.system(size: 14))
                    .foregroundStyle(OnboardingPalette.inkSoft)
            }

            HStack(spacing: 16) {
                LanguageCard(
                    title: "日本語", greeting: "こんにちは",
                    selected: language == .japanese
                ) { language = .japanese }
                LanguageCard(
                    title: "English", greeting: "Hello",
                    selected: language == .english
                ) { language = .english }
            }
        }
        .padding(.horizontal, 48)
    }
}

private struct LanguageCard: View {
    let title: String
    let greeting: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Text(greeting)
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingPalette.inkSoft)
                Text(title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(OnboardingPalette.ink)
            }
            .frame(width: 190, height: 106)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? Color.white : OnboardingPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        selected ? OnboardingPalette.accent : OnboardingPalette.ink.opacity(0.08),
                        lineWidth: selected ? 2 : 1
                    )
            )
            .shadow(
                color: OnboardingPalette.ink.opacity(selected ? 0.13 : 0.05),
                radius: selected ? 10 : 4, y: 3
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: selected)
    }
}

// MARK: - Step 2: How it works (self-drawn diagram, no assets)

private struct HowItWorksStep: View {
    let language: OnboardingLanguage
    private func L(_ ja: String, _ en: String) -> String { language.pick(ja, en) }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text(L("使い方はこれだけ", "This is all there is"))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(OnboardingPalette.ink)
                Text(L("どのアプリからでも、思いついた瞬間に。", "From any app, the moment it comes to mind."))
                    .font(.system(size: 14))
                    .foregroundStyle(OnboardingPalette.inkSoft)
            }

            HStack(alignment: .top, spacing: 12) {
                DiagramCell(caption: L("押す", "Press")) { HotkeyVisual() }
                FlowArrow()
                DiagramCell(caption: L("走り書き", "Scribble")) { ScribbleNoteVisual() }
                FlowArrow()
                DiagramCell(caption: L("整う", "Organized")) { OrganizedNoteVisual() }
            }

            Text(L(
                "付箋はどの画面の上にも浮かびます。整えたいときは付箋の杖ボタンをひとつ押すだけ。",
                "Notes float above every window. When you want order, tap the wand button on any note."
            ))
            .font(.system(size: 12.5))
            .foregroundStyle(OnboardingPalette.inkSoft)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        }
        .padding(.horizontal, 40)
    }
}

private struct DiagramCell<Content: View>: View {
    let caption: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 12) {
            content()
                .frame(width: 138, height: 116)
            Text(caption)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(OnboardingPalette.inkSoft)
        }
    }
}

private struct FlowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(OnboardingPalette.accent.opacity(0.85))
            .frame(height: 116)
    }
}

/// Physical-looking ⌥ + space keycaps (hard bottom shadow = key edge).
private struct KeycapView: View {
    let label: String
    var width: CGFloat = 44

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(OnboardingPalette.ink)
            .frame(width: width, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: OnboardingPalette.ink.opacity(0.30), radius: 0, y: 2.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(OnboardingPalette.ink.opacity(0.14), lineWidth: 1)
            )
    }
}

private struct HotkeyVisual: View {
    var body: some View {
        HStack(spacing: 7) {
            KeycapView(label: "⌥")
            Text("+")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(OnboardingPalette.inkSoft)
            KeycapView(label: "space", width: 68)
        }
    }
}

/// A tilted pastel sticky covered in hand-scribble strokes.
private struct ScribbleNoteVisual: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            scribbleLine(width: 68, tilt: -1.6)
            scribbleLine(width: 86, tilt: 1.1)
            scribbleLine(width: 52, tilt: -0.7)
            scribbleLine(width: 76, tilt: 1.5)
        }
        .padding(15)
        .frame(width: 122, height: 100, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NoteColorTheme.yellow.backgroundColor)
                .shadow(color: OnboardingPalette.ink.opacity(0.15), radius: 6, y: 3)
        )
        .rotationEffect(.degrees(-2))
    }

    private func scribbleLine(width: CGFloat, tilt: Double) -> some View {
        Capsule()
            .fill(NoteColorTheme.yellow.textColor.opacity(0.52))
            .frame(width: width, height: 3)
            .rotationEffect(.degrees(tilt))
    }
}

/// The same note after Organize: title, bullets, a checkbox — wand badge on top.
private struct OrganizedNoteVisual: View {
    private var ink: Color { NoteColorTheme.yellow.textColor }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(ink.opacity(0.75)).frame(width: 58, height: 5)
                bulletRow(width: 62)
                bulletRow(width: 48)
                checkboxRow(width: 52)
            }
            .padding(15)
            .frame(width: 122, height: 100, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(NoteColorTheme.yellow.backgroundColor)
                    .shadow(color: OnboardingPalette.ink.opacity(0.15), radius: 6, y: 3)
            )
            .rotationEffect(.degrees(1.5))

            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(OnboardingPalette.accent))
                .shadow(color: OnboardingPalette.accent.opacity(0.45), radius: 5, y: 2)
                .offset(x: 9, y: -9)
        }
    }

    private func bulletRow(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ink.opacity(0.45)).frame(width: 4, height: 4)
            Capsule().fill(ink.opacity(0.38)).frame(width: width, height: 3)
        }
    }

    private func checkboxRow(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(ink.opacity(0.55), lineWidth: 1.2)
                    .frame(width: 10, height: 10)
                Image(systemName: "checkmark")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(ink.opacity(0.65))
            }
            Capsule().fill(ink.opacity(0.38)).frame(width: width, height: 3)
        }
    }
}

// MARK: - Step 3: Power keys (the three gestures that ARE the app)

/// Keycap rows for ⌥Space / ⌥⇧A / ⌥⇧Space — the same physical-keycap
/// visual language as HowItWorksStep's HotkeyVisual, so the step reads as
/// a continuation, not a new chapter. Defaults are shown; every one is
/// rebindable in Settings > Shortcuts (KeyboardShortcuts names in
/// ShortcutNames.swift).
private struct PowerKeysStep: View {
    let language: OnboardingLanguage
    private func L(_ ja: String, _ en: String) -> String { language.pick(ja, en) }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(L("覚えるキーは 3 つ", "Three keys to remember"))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(OnboardingPalette.ink)
                Text(L(
                    "Flote にはウインドウ一覧がありません。この 3 つが入口です。",
                    "Flote has no window list. These three are the way in."
                ))
                .font(.system(size: 14))
                .foregroundStyle(OnboardingPalette.inkSoft)
            }

            VStack(spacing: 12) {
                PowerKeyRow(
                    keycaps: [("⌥", 40), ("space", 62)],
                    title: L("新しい付箋", "New note"),
                    detail: L("どのアプリの上でも、その場に 1 枚",
                              "From any app, right where you are"))
                PowerKeyRow(
                    keycaps: [("⌥", 40), ("⇧", 40), ("A", 40)],
                    title: L("全部かくす / もどす", "Hide / show all"),
                    detail: L("画面を一瞬で返してもらう。もう一度押すと復帰",
                              "Get your screen back — press again to return"))
                PowerKeyRow(
                    keycaps: [("⌥", 40), ("⇧", 40), ("space", 62)],
                    title: L("検索", "Search"),
                    detail: L("すべての付箋を横断して探す",
                              "Search across every note"))
            }
            .frame(maxWidth: 528)

            Text(L("キーは 設定 > ショートカット で変えられます。",
                   "Rebind any of them in Settings > Shortcuts."))
                .font(.system(size: 12))
                .foregroundStyle(OnboardingPalette.inkSoft)
        }
        .padding(.horizontal, 44)
    }
}

/// One gesture: keycap combo on the left, name + one-line purpose on the
/// right. Card chrome matches OnboardingOptionRow so steps 3 and 4 share
/// a silhouette.
private struct PowerKeyRow: View {
    /// (label, width) pairs rendered as KeycapView, left to right.
    let keycaps: [(String, CGFloat)]
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                    KeycapView(label: cap.0, width: cap.1)
                }
            }
            .frame(width: 158, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(OnboardingPalette.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingPalette.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OnboardingPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(OnboardingPalette.ink.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - Step 4: AI setup (on-device, never blocking)

private struct AISetupStep: View {
    let language: OnboardingLanguage
    let appleAI: AppleAIStatus
    private func L(_ ja: String, _ en: String) -> String { language.pick(ja, en) }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(L("AI はこの Mac の中だけ", "AI that never leaves this Mac"))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(OnboardingPalette.ink)
                Text(L(
                    "整理を担う頭脳です。どちらもオフラインで動き、あとから設定でも変えられます。",
                    "The brain behind Organize. Both run offline, and you can change this later in Settings."
                ))
                .font(.system(size: 14))
                .foregroundStyle(OnboardingPalette.inkSoft)
                .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                appleRow
                LocalAIRow(language: language)
            }
            .frame(maxWidth: 528)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(OnboardingPalette.inkSoft)
                Text(L("ノートは端末から出ません。", "Your notes never leave this Mac."))
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingPalette.inkSoft)
            }
        }
        .padding(.horizontal, 44)
    }

    private var appleRow: some View {
        OnboardingOptionRow(
            icon: "apple.logo",
            title: "Apple Intelligence",
            subtitle: L("macOS 内蔵。ダウンロード不要。", "Built into macOS. Nothing to download.")
        ) {
            switch appleAI {
            case .checking:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(L("確認中…", "Checking…"))
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingPalette.inkSoft)
                }
            case .available:
                Label(L("利用できます — 設定不要", "Ready — no setup needed"), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.ok)
            case .unavailable(let reason):
                Text(reasonText(reason))
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingPalette.inkSoft)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// Bilingual mapping of the provider's unavailability reasons (the
    /// provider's own `.description` is JP-only; fall back to it for any
    /// case not mapped here).
    private func reasonText(_ reason: AIProviderUnavailableReason) -> String {
        switch reason {
        case .osTooOld:
            return L("macOS 26 以降で利用できます", "Requires macOS 26 or later")
        case .appleIntelligenceOff:
            return L("Apple Intelligence がオフです", "Apple Intelligence is turned off")
        case .deviceNotEligible:
            return L("この Mac では利用できません", "Not available on this Mac")
        case .modelNotReady:
            return L("モデルを準備中です", "The system model is still getting ready")
        default:
            return reason.description
        }
    }
}

private struct LocalAIRow: View {
    let language: OnboardingLanguage
    private func L(_ ja: String, _ en: String) -> String { language.pick(ja, en) }

    var body: some View {
        OnboardingOptionRow(
            icon: "cpu",
            title: L("内蔵ローカル AI", "Built-in local AI"),
            subtitle: L("一度のダウンロードで、ずっとオフライン。", "One download, offline forever.")
        ) {
            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        // startDownload() only exists on Apple Silicon builds (MLX has no
        // x86_64 backend — see BundledLocalProvider.swift). On Intel this
        // row degrades to an honest "not available" line.
        #if arch(arm64)
        switch LocalModelStore.shared.state {
        case .notDownloaded:
            Button(L("ダウンロード（約 1 GB）", "Download (~1 GB)")) {
                LocalModelStore.shared.startDownload()
            }
            .buttonStyle(OnboardingAccentButtonStyle(compact: true))
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 5) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(OnboardingPalette.accent)
                    .frame(width: 140)
                Text("\(Int(progress * 100))% · " + L("このまま次へ進めます", "You can keep going"))
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingPalette.inkSoft)
            }
        case .ready:
            Label(L("準備完了", "Ready"), systemImage: "checkmark.seal.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(OnboardingPalette.ok)
        case .failed:
            VStack(alignment: .trailing, spacing: 5) {
                Label(L("ダウンロードに失敗しました", "Download failed"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingPalette.warn)
                Button(L("再試行", "Retry")) {
                    LocalModelStore.shared.startDownload()
                }
                .buttonStyle(OnboardingQuietButtonStyle(compact: true))
            }
        }
        #else
        Text(L("この Mac（Intel）では利用できません", "Not available on Intel Macs"))
            .font(.system(size: 12))
            .foregroundStyle(OnboardingPalette.inkSoft)
        #endif
    }
}

private struct OnboardingOptionRow<Status: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var status: () -> Status

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(OnboardingPalette.ink)
                .frame(width: 42, height: 42)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(OnboardingPalette.paperDeep)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(OnboardingPalette.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingPalette.inkSoft)
            }
            Spacer(minLength: 12)
            status()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OnboardingPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(OnboardingPalette.ink.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - Step 5: Style

private struct StyleStep: View {
    let language: OnboardingLanguage
    @Binding var selectedTheme: NoteColorTheme
    private func L(_ ja: String, _ en: String) -> String { language.pick(ja, en) }

    private let columns = Array(repeating: GridItem(.fixed(52), spacing: 14), count: 6)

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(L("最初の色を選んでください", "Pick your starting color"))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(OnboardingPalette.ink)
                Text(L(
                    "新しい付箋はこの色で生まれます。付箋ごとにいつでも変えられます。",
                    "New notes are born in this color. Any note can change it anytime."
                ))
                .font(.system(size: 14))
                .foregroundStyle(OnboardingPalette.inkSoft)
            }

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(NoteColorTheme.allCases, id: \.self) { theme in
                    ThemeSwatch(theme: theme, selected: theme == selectedTheme) {
                        selectedTheme = theme
                    }
                }
            }
            .frame(maxWidth: 400)

            MiniNotePreview(theme: selectedTheme, language: language)
        }
        .padding(.horizontal, 48)
    }
}

private struct ThemeSwatch: View {
    let theme: NoteColorTheme
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(theme.backgroundColor)
                Circle().strokeBorder(theme.toolbarColor, lineWidth: 1.5)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.textColor)
                }
            }
            .frame(width: 44, height: 44)
            .overlay(
                Circle()
                    .strokeBorder(OnboardingPalette.accent, lineWidth: selected ? 2.5 : 0)
                    .padding(-4)
            )
            .scaleEffect(selected ? 1.08 : 1.0)
            .shadow(color: OnboardingPalette.ink.opacity(0.10), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
    }
}

/// Live preview: a miniature sticky in the chosen theme, so the pick feels
/// like already owning the first note.
private struct MiniNotePreview: View {
    let theme: NoteColorTheme
    let language: OnboardingLanguage

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.toolbarColor)
                .frame(height: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(language.pick("買い物メモ", "Groceries"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textColor)
                Text(language.pick("牛乳・卵・コーヒー", "Milk, eggs, coffee"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textColor.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(theme.backgroundColor)
        }
        .frame(width: 200)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: OnboardingPalette.ink.opacity(0.16), radius: 8, y: 4)
        .rotationEffect(.degrees(-1.2))
        .animation(.easeOut(duration: 0.2), value: theme)
    }
}

// MARK: - Shared chrome

private struct OnboardingProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? OnboardingPalette.accent : OnboardingPalette.ink.opacity(0.15))
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
    }
}

private struct OnboardingAccentButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 26)
            .padding(.vertical, compact ? 7 : 11)
            .background(Capsule().fill(OnboardingPalette.accent))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct OnboardingQuietButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13.5, weight: .medium, design: .rounded))
            .foregroundStyle(OnboardingPalette.inkSoft)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 6 : 10)
            .background(
                Capsule().fill(OnboardingPalette.ink.opacity(configuration.isPressed ? 0.09 : 0.045))
            )
    }
}

extension Notification.Name {
    /// Posted once, when onboarding places the demo note after the launch
    /// panel already exists — NoteView refreshes its hint state on receipt.
    static let floteOrganizeHintChanged = Notification.Name("floteOrganizeHintChanged")
}
