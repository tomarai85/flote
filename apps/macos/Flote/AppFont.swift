import SwiftUI
import AppKit

/// User-selectable font for note body text and the rolled-up scroll title.
/// Choices are persisted in UserDefaults under "floteFontFamily".
///
/// CURATED (Tom 2026-07-10: "英語のやつが変な形" — a JP-first font forces its
/// Latin glyphs, which read awkward; old Monaco was worse). Every choice must
/// look good in BOTH scripts:
///   - System / Rounded / Mono use Apple's cascade — SF for Latin, Hiragino
///     auto-fallback for JP — the best of both by construction.
///   - Explicit Hiragino / New York remain for users who WANT that voice
///     (their Latin is a deliberate aesthetic, not an accident).
/// Removed: monaco, menlo (dated Latin; persisted selections fall back to
/// the default via the FontPreference init guard).
enum AppFont: String, CaseIterable, Identifiable {
    case sfPro                 // DEFAULT: SF Latin + Hiragino JP cascade
    case sfRounded             // warm rounded SF — the design direction's title voice
    case hiraginoSans          // explicit JP sans voice
    case hiraginoMincho        // classic JP serif, literary
    case newYork               // Apple serif, editorial
    case sfMono                // modern mono (SF Mono via system API)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sfPro:          return "標準 (SF + ヒラギノ)"
        case .sfRounded:      return "丸ゴシック (SF Rounded)"
        case .hiraginoSans:   return "ヒラギノ角ゴ (Sans)"
        case .hiraginoMincho: return "ヒラギノ明朝 (Serif)"
        case .newYork:        return "New York (Serif)"
        case .sfMono:         return "SF Mono (等幅)"
        }
    }

    /// Font name string for NSFont(name:size:) lookup. Falls back to system.
    /// System-designed cases (.sfPro/.sfRounded/.sfMono) don't use this.
    var fontName: String {
        switch self {
        case .sfPro, .sfRounded, .sfMono: return ".AppleSystemUIFont"
        case .hiraginoSans:   return "HiraginoSans-W3"
        case .hiraginoMincho: return "HiraMinProN-W3"
        case .newYork:        return "NewYork"
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch self {
        case .sfPro:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .sfRounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let desc = base.fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: desc, size: size) {
                return rounded
            }
            return base
        case .sfMono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        default:
            return NSFont(name: fontName, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: weight)
        }
    }
}

// TEXTSIZE-PURE-BEGIN
/// S16: pure clamp/step policy for the GLOBAL body text size (⌘+/⌘−/⌘0,
/// Settings stepper). Global by design — Antinote parity; no per-note
/// override this slice. Kept Foundation-only so text-size-test.sh compiles
/// the shipping logic standalone (same pattern as the S10/S11/S12 regions).
enum FloteTextSize {
    static let minSize: CGFloat = 9
    static let maxSize: CGFloat = 18
    static let defaultSize: CGFloat = 11
    static let step: CGFloat = 1

    /// Whole-point clamp. Non-finite input (corrupt defaults) falls back to
    /// the default; fractional input snaps to the nearest point so a
    /// hand-edited 10.5 can never make ⌘+ walk off the whole-point grid.
    static func clamped(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return defaultSize }
        return min(max(size.rounded(), minSize), maxSize)
    }

    static func increased(from size: CGFloat) -> CGFloat {
        clamped(clamped(size) + step)
    }

    static func decreased(from size: CGFloat) -> CGFloat {
        clamped(clamped(size) - step)
    }
}
// TEXTSIZE-PURE-END

/// Observable font preference. SwiftUI views re-render when the user changes
/// the setting in SettingsView.
@MainActor
@Observable
final class FontPreference {
    static let shared = FontPreference()
    private let defaultsKey = "floteFontFamily"
    private let sizeKey = "floteBodySize"

    var current: AppFont {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: defaultsKey)
        }
    }

    /// S16: global body point size. Clamping, persistence and live
    /// propagation all ride the didSet, so ANY writer (Settings stepper,
    /// ⌘+/⌘−/⌘0 in the editor) gets the full behavior for free. Open
    /// editors observe .floteBodyFontChanged and re-resolve.
    var bodySize: CGFloat {
        didSet {
            let clamped = FloteTextSize.clamped(bodySize)
            // Assigning inside didSet does not recurse (Swift guarantee).
            if clamped != bodySize { bodySize = clamped }
            guard bodySize != oldValue else { return }
            UserDefaults.standard.set(Double(bodySize), forKey: sizeKey)
            NotificationCenter.default.post(name: .floteBodyFontChanged, object: nil)
        }
    }

    /// S16 monospace hook (contract with the appearance side): when the
    /// ACTIVE theme spec prefers monospace, the body font resolves to
    /// SF Mono at the user's size regardless of the family choice. NOT
    /// persisted here — the theme spec is the source of truth; the
    /// appearance side re-asserts this flag at launch and on every theme
    /// activation. A late set is safe: the didSet posts
    /// .floteBodyFontChanged and every open editor live-swaps.
    var themePrefersMonospace: Bool = false {
        didSet {
            guard themePrefersMonospace != oldValue else { return }
            NotificationCenter.default.post(name: .floteBodyFontChanged, object: nil)
        }
    }

    /// THE body-font resolution point. Family = the theme's monospace
    /// override (SF Mono via the system API — same as AppFont.sfMono;
    /// the API is non-optional so the contract's "fallback Menlo" branch
    /// is unreachable and documented instead of dead code) or the user's
    /// family choice. Size = the global body size unless an explicit size
    /// is passed (title/preview call sites keep their own metrics).
    /// JP glyphs under SF Mono fall through the system cascade (Hiragino)
    /// automatically — same mechanism the curated AppFont list relies on.
    func resolvedBodyFont(size: CGFloat? = nil,
                          weight: NSFont.Weight = .regular) -> NSFont {
        let pt = size ?? bodySize
        if themePrefersMonospace {
            return NSFont.monospacedSystemFont(ofSize: pt, weight: weight)
        }
        return current.nsFont(size: pt, weight: weight)
    }

    /// Keeps the block-based observer alive for the singleton's lifetime
    /// (an unretained token is deallocated and observation stops).
    @ObservationIgnored private var themeObserver: NSObjectProtocol?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let font = AppFont(rawValue: raw) {
            current = font
        } else {
            // Default = the system cascade: SF Latin + Hiragino JP — the one
            // combination that never produces awkward glyphs in either script.
            current = .sfPro
        }
        let stored = UserDefaults.standard.object(forKey: sizeKey) as? Double
        bodySize = FloteTextSize.clamped(
            stored.map { CGFloat($0) } ?? FloteTextSize.defaultSize)

        // S16 monospace hook, PULL side (agreed with the appearance layer):
        // the theme layer posts .floteAppearanceChanged carrying
        // userInfo["prefersMonospace"] (Bool, resolved from the ACTIVE
        // theme spec — incl. once at launch after restoring the persisted
        // theme); we mirror it here and the didSet fans out to open
        // editors. The stringly userInfo key keeps the two layers
        // compile-independent: this side builds without the theme layer's
        // new symbols and no-ops harmlessly until the key arrives.
        themeObserver = NotificationCenter.default.addObserver(
            forName: .floteAppearanceChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let mono = note.userInfo?["prefersMonospace"] as? Bool else { return }
            MainActor.assumeIsolated { self?.themePrefersMonospace = mono }
        }
    }
}

extension Notification.Name {
    /// S16: posted when the RESOLVED body font changes (global size step,
    /// theme monospace flag). Observed by every open editor's Coordinator,
    /// which re-resolves family + size live. Distinct from
    /// .floteAppearanceChanged (ink re-derivation) — both handlers are
    /// idempotent, so delivery order never matters.
    static let floteBodyFontChanged = Notification.Name("floteBodyFontChanged")
}
