//
//  FloteTheme.swift
//  Flote
//
//  S3 groundwork: the data-driven appearance foundation.
//
//  DESIGN PRINCIPLES
//  =================
//  1. PORTABILITY — theme specs are pure data (RGBA component structs, strings,
//     enums). Nothing in the data layer touches SwiftUI. A future Windows or
//     iOS port can consume `FloteThemeRegistry.allSpecs` verbatim (they are
//     Codable — serialize to JSON and ship). The ONLY place component data
//     becomes a SwiftUI `Color` is the single bridge extension marked
//     "SwiftUI bridge" below. Keep it that way.
//  2. ONE TABLE ENTRY PER THEME — adding a theme is exactly one new
//     `FloteThemeSpec` literal in `FloteThemeRegistry.allSpecs`. No switch
//     statements to extend, no parallel arrays.
//  3. MIGRATION IS LOSSLESS — the 11 legacy `NoteColorTheme` hues are ported
//     with their EXACT light-appearance RGB values from StickyNote.swift.
//     `specForLegacy(_:)` accepts a legacy rawValue ("yellow", "pink", …)
//     because the spec ids are identical to the legacy rawValues.
//  4. ACCESSIBILITY IS COMPUTED, NOT VIBED — every dark-variant text/background
//     pair carries its computed WCAG 2.x contrast ratio as a comment
//     (relative luminance: L = 0.2126·R + 0.7152·G + 0.0722·B on linearized
//     sRGB; CR = (L_hi + 0.05) / (L_lo + 0.05)). All dark text inks clear
//     AA 4.5:1 against BOTH the note background and the toolbar strip
//     (actual range: 5.0–13.4). Accents clear the 3:1 non-text UI minimum
//     (WCAG 1.4.11) against their own background.
//     S14: the math itself now lives in code (`FloteColorValue.contrastRatio`)
//     and a standalone harness (.harness/tests/s14-theme-contrast-test.sh)
//     asserts the floors for EVERY palette of EVERY theme — the comments are
//     documentation, the harness is the gate. Scaling the roster can never
//     silently ship an illegible theme.
//  5. SEMANTIC SLOTS ARE DERIVED BY DEFAULT (S14) — the Antinote-class color
//     grammar (keyword line / variable definition / dimmed variable use;
//     see competitive/antinote-behavior-specs.md §14 + Appendix C) is three
//     OPTIONAL palette slots. Absent slots derive from the four base roles
//     (rules documented on `Palette`), so every theme — including all 14
//     pre-S14 entries — works with zero hand-tuning, and a designed theme
//     can override any slot. Consumers: calc answers already use `accent`;
//     the queued editor work (variable def/use coloring, keyword-line
//     coloring) reads the resolved slots via `FloteInk`.
//  6. DARK THEMES OVER THE LIGHT FROST (S14) — the vibrancy layer is an
//     NSVisualEffectView pinned to `.aqua` (FloatingPanel: notes are paper),
//     and NoteView paints the theme surface over it at 0.90 opacity. A
//     dark-identity theme therefore reads dark because its background is
//     deep enough that the 10% frost bleed cannot lift it: worst case
//     (pure-white wallpaper behind the frost) the composite is
//     0.9·bg + 0.1·white, and every dark theme's ink still clears AA 4.5:1
//     against THAT composite (harness-asserted, "frost gate"). No branching,
//     no per-theme opacity knobs — just backgrounds designed with headroom.
//     Dark-identity = `isDarkTheme` (computed from background luminance);
//     both palette slots of a dark theme are the same night surface, so a
//     future explicit dark-note option is a no-op for them.
//  7. THEME FAMILIES (S16 — the Antinote editor-soul port, 2026-07-12) —
//     `family` is a spec AXIS, never per-theme code. `.paper` = the
//     original pastel/stationery world. `.editor` = the "editor-aesthetic
//     scratchpad": deep saturated grounds sampled from the owner's
//     Antinote reference shots, where the SYNTAX SLOTS (keyword /
//     variableDef / variableUse / calcAnswer) carry the identity in
//     distinct high-saturation families — the coloring is a legibility
//     feature, not decoration (owner verdict 2026-07-12: 「文字の色が
//     自動で変わって、見ている側からして使いやすい」). Editor themes
//     also carry `prefersMonospace` (advisory, consumed by
//     RichTextEditor's font resolution) and recommend dot/grid paper at
//     subtle strength. Same CR floors as everyone — the harness gates
//     the whole roster, family notwithstanding.
//  8. CUSTOM THEMES ARE USER DATA, NOT CODE (S15) — the Theme Maker stores
//     `FloteCustomTheme` (4 core slots + name + paper) as Codable JSON in
//     UserDefaults (`FloteCustomThemeStore`); semantic slots and dark
//     identity DERIVE, and `FloteCustomThemeGate` enforces the s14 floors
//     (incl. the frost gate) at save time — the machine gate is the design
//     assistant: an unreadable theme cannot be saved. Registry surfacing
//     goes through `FloteThemeRegistry.resolvedSpec(for:)`; deleting the
//     active custom theme falls back to per-note mode via a pure rule.
//
//  HOW S3 WIRING WILL CONSUME THIS FILE
//  ====================================
//  - NoteView background:  `spec.palette(for: colorScheme).background.color`
//    layered over NSVisualEffectView when `AppearanceSettings.shared.useVibrancy`
//    (light frosted float: vibrancy behind a pastel tint), plain fill otherwise.
//    Window alpha comes from `AppearanceSettings.shared.panelOpacity`.
//  - Toolbar strip:        `palette.toolbar.color` (replaces NoteColorTheme.toolbarColor).
//  - Text ink:             `palette.text.color` — this makes the WCAG-tuned ink
//    (currently computed but never consumed) finally reach the NSTextView
//    typing attributes. Single source of truth from here on.
//  - Checkbox accent:      `palette.accent.color` fills the Things-3-style
//    circular checkboxes (white/paper checkmark on the accent fill).
//  - Paper pattern:        `PaperPatternView(type: settings.paperType,
//    ink: palette.text.color)` overlaid between the background and the text.
//  - Settings picker:      iterate `FloteThemeRegistry.allSpecs` (21 curated
//    named themes, grouped light/dark via `isDarkTheme`) + `PaperType.allCases`;
//    write choices to `AppearanceSettings.shared`, live-refresh via
//    `.floteAppearanceChanged`.
//
//  This file intentionally supersedes the `PanelStyle` scaffold in
//  StickyNote.swift (dead code, removed by the lead during S3 wiring).
//

import SwiftUI
import AppKit
import Observation

// MARK: - FloteColorValue (portable RGBA components)
// S14-THEME-PURE-BEGIN (the contrast harness compiles everything between
// the PURE markers standalone with `import Foundation` only — keep SwiftUI/
// AppKit types out of the marked regions).

/// A device-independent sRGB color as plain numeric components.
///
/// This is the portability seam: specs store `FloteColorValue`, never
/// `SwiftUI.Color`. Components are 0.0–1.0 in sRGB, matching the literals
/// that were previously hardcoded in `NoteColorTheme`.
struct FloteColorValue: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double = 1.0

    /// Compact table literal: `.rgb(1.000, 0.976, 0.769)`.
    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> FloteColorValue {
        FloteColorValue(red: red, green: green, blue: blue)
    }

    // MARK: WCAG 2.x contrast math (S14 — the discipline the header
    // documents, now executable so the theme harness can gate the roster).

    /// WCAG relative luminance (linearized sRGB, D65 weights). Ignores
    /// `opacity` — composite first (`composited(over:)`) when it matters.
    var relativeLuminance: Double {
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// WCAG contrast ratio, 1.0–21.0. Symmetric.
    func contrastRatio(against other: FloteColorValue) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Source-over composite of `self` (using its `opacity`) onto an opaque
    /// base, in gamma sRGB per channel — matching how SwiftUI/AppKit blend
    /// a translucent ink over the note surface. Result is opaque.
    func composited(over base: FloteColorValue) -> FloteColorValue {
        let a = opacity
        return FloteColorValue(
            red:   a * red   + (1 - a) * base.red,
            green: a * green + (1 - a) * base.green,
            blue:  a * blue  + (1 - a) * base.blue,
            opacity: 1.0)
    }

    /// Same color with its opacity multiplied — the derivation primitive
    /// for the dimmed semantic slots (`variableUse` = def at 55%).
    func dimmed(_ factor: Double) -> FloteColorValue {
        var c = self
        c.opacity *= factor
        return c
    }
}

// MARK: - ThemeFamily (S16 — the visual world a theme belongs to)

/// Which visual world a theme belongs to. A spec AXIS (data), never
/// per-theme code — family behaviors hang off spec fields.
/// - `.paper`: the original Flote world — pastel / stationery grounds,
///   one body ink, semantic slots as quiet derivations.
/// - `.editor`: the Antinote-class "editor-aesthetic scratchpad" — deep
///   saturated grounds where the syntax slots (keyword / variableDef /
///   variableUse / calcAnswer) ARE the identity: distinct
///   high-saturation families that make the note easier to read, not
///   prettier. Editor themes prefer a monospaced body and recommend
///   dot/grid paper at subtle strength.
enum ThemeFamily: String, Codable, Hashable, Sendable {
    case paper
    case editor
}

// MARK: - FloteThemeSpec (pure data)

/// A complete named theme: light + dark palettes, bilingual display names.
///
/// `id` is the stable persistence key (stored in note JSON / UserDefaults).
/// For the 11 ported hues it equals the legacy `NoteColorTheme.rawValue`,
/// which is what makes migration a no-op.
struct FloteThemeSpec: Identifiable, Codable, Hashable, Sendable {

    /// The four color roles a note surface needs, for one appearance —
    /// plus three OPTIONAL semantic slots (S14) for the Antinote-class
    /// in-text color grammar. Optional slots derive from the base four,
    /// so pre-S14 themes need no hand-tuning and old serialized specs
    /// decode unchanged (`decodeIfPresent`).
    struct Palette: Codable, Hashable, Sendable {
        /// Note body fill (behind text / behind the vibrancy tint).
        var background: FloteColorValue
        /// Toolbar / title strip fill, slightly offset from `background`
        /// (darker in light appearance, lighter "elevated" in dark).
        var toolbar: FloteColorValue
        /// Text ink. Every pair clears WCAG AA 4.5:1 against both
        /// `background` and `toolbar` (ratios documented per entry).
        var text: FloteColorValue
        /// Control accent — Things-3-style circular checkbox fill, links,
        /// selection tint, and the calc ANSWER ink (RichTextEditor already
        /// paints `= results` with `FloteInk.accent`). Clears 3:1 non-text
        /// contrast vs `background`.
        var accent: FloteColorValue

        // S14/S16 semantic slots (Antinote grammar, spec §14 + Appendix C).
        // nil = derived; a designed theme may override any of them.
        // DERIVATION RULES (single source of truth = the resolved
        // accessors below):
        //   keyword     ?? accent               (Antinote: keyword shares
        //                                        the answer/caret family)
        //   variableDef ?? accent               (teal-class when designed)
        //   variableUse ?? variableDef @ 55%    (the "dimmed quote" —
        //                                        a USE visibly defers to
        //                                        its DEFINITION)
        //   calcAnswer  ?? accent               (pre-S16 behavior exactly:
        //                                        answers rendered in accent)

        /// Mode-keyword line ink ("math" / "list" first line). Queued
        /// consumer: keyword-line coloring (Appendix C work item d).
        var keyword: FloteColorValue? = nil
        /// Variable DEFINITION name ink (`price: 300`). Queued consumer:
        /// live semantic coloring (Appendix C work item b — the parse
        /// already exists: RichTextEditor.variableDefinition(inLine:)).
        var variableDef: FloteColorValue? = nil
        /// Variable USE ink inside an expression — dimmed relative to the
        /// definition by design (sub-AA on purpose; harness asserts it is
        /// strictly lower-contrast than the def, not that it clears AA).
        var variableUse: FloteColorValue? = nil
        /// Calc ANSWER ink (`= 96` results) — S16. In the editor family
        /// the answer is the loudest voice on the note (Antinote: red /
        /// burnt orange / neon green answers), its OWN family distinct
        /// from the keyword. nil derives to `accent`, which is byte-exact
        /// pre-S16 behavior (RichTextEditor painted answers with accent).
        var calcAnswer: FloteColorValue? = nil

        /// Resolved keyword ink (never nil).
        var resolvedKeyword: FloteColorValue { keyword ?? accent }
        /// Resolved variable-definition ink (never nil). Clears 3:1 vs
        /// `background` (harness-asserted).
        var resolvedVariableDef: FloteColorValue { variableDef ?? accent }
        /// Resolved variable-use ink (never nil). Carries alpha < 1 when
        /// derived — composite over `background` for contrast math.
        var resolvedVariableUse: FloteColorValue {
            variableUse ?? resolvedVariableDef.dimmed(0.55)
        }
        /// Resolved calc-answer ink (never nil). Clears 3:1 vs
        /// `background` including the frost gate (harness-asserted).
        var resolvedCalcAnswer: FloteColorValue { calcAnswer ?? accent }
    }

    /// Stable identity, persisted. Never rename an existing id.
    let id: String
    /// Japanese display name (primary UI language).
    let nameJP: String
    /// English display name.
    let nameEN: String
    /// Palette for light system appearance.
    let light: Palette
    /// Palette for dark system appearance.
    let dark: Palette
    /// True for the soft pastel family (S3 wiring may use this to pick a
    /// stronger vibrancy tint for pastels vs the muted curated themes).
    var isPastel: Bool = true
    /// The paper pattern this theme was designed around (S14, Antinote
    /// ground truth: dot-grid vs square-grid paper is part of a theme's
    /// identity). ADVISORY data: the Settings swatch previews it, but the
    /// user's global paper choice is never overridden by selecting a theme.
    var recommendedPaper: PaperType = .blank
    /// Visual world (S16). `.editor` themes group separately in Settings
    /// and render the syntax-preview swatch (the slots are the identity).
    var family: ThemeFamily = .paper
    /// Editor-family themes read best with a monospaced body (every
    /// Antinote reference frame is mono). ADVISORY like `recommendedPaper`:
    /// the font swap itself is resolved by RichTextEditor / FontPreference
    /// (contract with font-controls, 2026-07-12) via
    /// `FloteInk.prefersMonospace(legacyTheme:)`; the user's own font
    /// choice in Settings is never rewritten.
    var prefersMonospace: Bool = false

    /// Dark-identity theme (S14): the RENDERED palette (notes are paper —
    /// always the `light` slot, see NoteView.themePalette) is a night
    /// surface. Computed from background luminance, not stored — data
    /// cannot drift from appearance. Threshold 0.35 splits the roster
    /// cleanly (light identities ≥ 0.60, dark identities ≤ 0.04).
    var isDarkTheme: Bool { light.background.relativeLuminance < 0.35 }

    /// Pure-data palette selection (no SwiftUI dependency — portable).
    func palette(dark isDark: Bool) -> Palette {
        isDark ? dark : light
    }
}

// MARK: - FloteThemeRegistry (the single theme table)

/// Static registry of every named theme Flote ships (27: 21 paper-family
/// [15 light + 6 dark identity] + 6 editor-family [5 dark + 1 light]).
///
/// Adding a theme = appending exactly one `FloteThemeSpec` literal to
/// `allSpecs`. Order here is display order in the Settings picker:
/// the 11 legacy pastels first (in `NoteColorTheme` case order, so the
/// picker feels familiar), then the curated light themes, then the S14
/// dark-identity themes, then the S16 editor family (the Settings grid
/// groups by family and light/dark via `family` / `isDarkTheme`, so
/// registry order only matters within each group).
///
/// Dark variants for the 11 ported pastels were generated by keeping the
/// hue, deepening HSL lightness to ~28% of the light value (landing at a
/// consistent 0.18–0.26 dark-surface band), and softening saturation —
/// then the ink was lifted until it cleared AA against both background and
/// toolbar. All ratios below are computed, not estimated.
enum FloteThemeRegistry {

    static let allSpecs: [FloteThemeSpec] = [

        // ── 11 legacy hues ─────────────────────────────────────────────
        // Light palettes are byte-exact ports of NoteColorTheme
        // (StickyNote.swift). Do not "correct" them: visual losslessness
        // of the migration depends on these literals.

        FloteThemeSpec(
            id: "yellow", nameJP: "菜の花", nameEN: "Yellow",
            light: .init(
                background: .rgb(1.000, 0.976, 0.769),
                toolbar:    .rgb(0.953, 0.925, 0.698),
                text:       .rgb(0.220, 0.188, 0.040),  // CR 15.1:1 (ported ink)
                accent:     .rgb(0.700, 0.536, 0.154)), // amber, CR 3.0:1 vs bg
            dark: .init(
                background: .rgb(0.364, 0.340, 0.131),
                toolbar:    .rgb(0.445, 0.415, 0.160),
                text:       .rgb(0.968, 0.961, 0.933),  // CR 6.8:1 vs bg, 5.1:1 vs toolbar
                accent:     .rgb(0.780, 0.644, 0.328))),// CR 3.1:1 vs bg

        FloteThemeSpec(
            id: "pink", nameJP: "桜", nameEN: "Pink",
            light: .init(
                background: .rgb(1.000, 0.878, 0.902),
                toolbar:    .rgb(0.953, 0.820, 0.847),
                text:       .rgb(0.239, 0.094, 0.125),  // CR 12.2:1 (ported ink)
                accent:     .rgb(0.820, 0.180, 0.394)), // rose, CR 4.0:1 vs bg
            dark: .init(
                background: .rgb(0.382, 0.138, 0.186),
                toolbar:    .rgb(0.463, 0.167, 0.225),
                text:       .rgb(0.922, 0.838, 0.856),  // CR 8.4:1 vs bg, 7.0:1 vs toolbar
                accent:     .rgb(0.820, 0.344, 0.503))),// CR 3.0:1 vs bg

        FloteThemeSpec(
            id: "blue", nameJP: "勿忘草", nameEN: "Blue",
            light: .init(
                background: .rgb(0.831, 0.918, 1.000),
                toolbar:    .rgb(0.769, 0.867, 0.953),
                text:       .rgb(0.063, 0.125, 0.220),  // CR 12.5:1 (ported ink)
                accent:     .rgb(0.180, 0.458, 0.820)), // cobalt, CR 3.7:1 vs bg
            dark: .init(
                background: .rgb(0.136, 0.260, 0.377),
                toolbar:    .rgb(0.165, 0.316, 0.458),
                text:       .rgb(0.838, 0.871, 0.922),  // CR 7.7:1 vs bg, 6.2:1 vs toolbar
                accent:     .rgb(0.344, 0.550, 0.820))),// CR 3.0:1 vs bg

        FloteThemeSpec(
            id: "green", nameJP: "若葉", nameEN: "Green",
            light: .init(
                background: .rgb(0.863, 0.976, 0.863),
                toolbar:    .rgb(0.800, 0.933, 0.800),
                text:       .rgb(0.063, 0.157, 0.063),  // CR 13.9:1 (ported ink)
                accent:     .rgb(0.136, 0.620, 0.217)), // leaf, CR 3.1:1 vs bg
            dark: .init(
                background: .rgb(0.169, 0.346, 0.169),
                toolbar:    .rgb(0.205, 0.420, 0.205),
                text:       .rgb(0.838, 0.922, 0.838),  // CR 6.6:1 vs bg, 5.1:1 vs toolbar
                accent:     .rgb(0.294, 0.700, 0.362))),// CR 3.1:1 vs bg

        FloteThemeSpec(
            id: "purple", nameJP: "菫", nameEN: "Purple",
            light: .init(
                background: .rgb(0.918, 0.831, 0.976),
                toolbar:    .rgb(0.867, 0.784, 0.933),
                text:       .rgb(0.125, 0.039, 0.220),  // CR 11.5:1 (ported ink)
                accent:     .rgb(0.553, 0.180, 0.820)), // violet, CR 4.4:1 vs bg
            dark: .init(
                background: .rgb(0.271, 0.161, 0.345),
                toolbar:    .rgb(0.330, 0.195, 0.421),
                text:       .rgb(0.878, 0.838, 0.922),  // CR 8.7:1 vs bg, 7.3:1 vs toolbar
                accent:     .rgb(0.652, 0.361, 0.860))),// CR 3.0:1 vs bg

        FloteThemeSpec(
            id: "orange", nameJP: "杏", nameEN: "Orange",
            light: .init(
                background: .rgb(1.000, 0.922, 0.780),
                toolbar:    .rgb(0.953, 0.871, 0.710),
                text:       .rgb(0.235, 0.157, 0.000),  // CR 13.4:1 (ported ink)
                accent:     .rgb(0.780, 0.435, 0.172)), // terracotta, CR 3.1:1 vs bg
            dark: .init(
                background: .rgb(0.366, 0.283, 0.132),
                toolbar:    .rgb(0.447, 0.346, 0.161),
                text:       .rgb(0.922, 0.894, 0.838),  // CR 6.9:1 vs bg, 5.3:1 vs toolbar
                accent:     .rgb(0.800, 0.537, 0.336))),// CR 3.0:1 vs bg

        FloteThemeSpec(
            id: "coral", nameJP: "珊瑚", nameEN: "Coral",
            light: .init(
                background: .rgb(1.000, 0.867, 0.835),
                toolbar:    .rgb(0.953, 0.812, 0.773),
                text:       .rgb(0.239, 0.063, 0.031),  // CR 12.3:1 (ported ink)
                accent:     .rgb(0.820, 0.308, 0.180)), // brick, CR 3.4:1 vs bg
            dark: .init(
                background: .rgb(0.378, 0.183, 0.136),
                toolbar:    .rgb(0.458, 0.222, 0.165),
                text:       .rgb(0.922, 0.851, 0.838),  // CR 8.0:1 vs bg, 6.5:1 vs toolbar
                accent:     .rgb(0.800, 0.429, 0.336))),// CR 3.1:1 vs bg

        FloteThemeSpec(
            id: "mint", nameJP: "薄荷", nameEN: "Mint",
            light: .init(
                background: .rgb(0.831, 0.976, 0.945),
                toolbar:    .rgb(0.773, 0.933, 0.898),
                text:       .rgb(0.031, 0.192, 0.173),  // CR 13.8:1 (ported ink)
                accent:     .rgb(0.132, 0.600, 0.506)), // teal, CR 3.1:1 vs bg
            dark: .init(
                background: .rgb(0.161, 0.345, 0.306),
                toolbar:    .rgb(0.195, 0.421, 0.372),
                text:       .rgb(0.852, 0.928, 0.919),  // CR 6.6:1 vs bg, 5.0:1 vs toolbar
                accent:     .rgb(0.294, 0.700, 0.619))),// CR 3.2:1 vs bg

        FloteThemeSpec(
            id: "lavender", nameJP: "藤", nameEN: "Lavender",
            light: .init(
                background: .rgb(0.894, 0.867, 1.000),
                toolbar:    .rgb(0.843, 0.812, 0.953),
                text:       .rgb(0.110, 0.031, 0.220),  // CR 11.7:1 (ported ink)
                accent:     .rgb(0.372, 0.180, 0.820)), // iris, CR 5.8:1 vs bg
            dark: .init(
                background: .rgb(0.187, 0.138, 0.382),
                toolbar:    .rgb(0.227, 0.167, 0.463),
                text:       .rgb(0.873, 0.838, 0.922),  // CR 9.7:1 vs bg, 8.4:1 vs toolbar
                accent:     .rgb(0.523, 0.370, 0.880))),// CR 3.0:1 vs bg

        FloteThemeSpec(
            id: "peach", nameJP: "桃", nameEN: "Peach",
            light: .init(
                background: .rgb(1.000, 0.906, 0.867),
                toolbar:    .rgb(0.953, 0.855, 0.812),
                text:       .rgb(0.239, 0.125, 0.039),  // CR 12.4:1 (ported ink)
                accent:     .rgb(0.820, 0.394, 0.180)), // persimmon, CR 3.2:1 vs bg
            dark: .init(
                background: .rgb(0.382, 0.209, 0.138),
                toolbar:    .rgb(0.463, 0.254, 0.167),
                text:       .rgb(0.922, 0.874, 0.838),  // CR 7.8:1 vs bg, 6.3:1 vs toolbar
                accent:     .rgb(0.780, 0.478, 0.328))),// CR 3.1:1 vs bg

        FloteThemeSpec(
            id: "sky", nameJP: "空", nameEN: "Sky",
            light: .init(
                background: .rgb(0.863, 0.945, 1.000),
                toolbar:    .rgb(0.808, 0.898, 0.953),
                text:       .rgb(0.024, 0.125, 0.188),  // CR 14.0:1 (ported ink)
                accent:     .rgb(0.167, 0.562, 0.760)), // cerulean, CR 3.1:1 vs bg
            dark: .init(
                background: .rgb(0.138, 0.284, 0.382),
                toolbar:    .rgb(0.167, 0.344, 0.463),
                text:       .rgb(0.838, 0.890, 0.922),  // CR 7.3:1 vs bg, 5.8:1 vs toolbar
                accent:     .rgb(0.311, 0.597, 0.740))),// CR 3.0:1 vs bg

        // ── 3 new curated themes ───────────────────────────────────────
        // A deliberately muted trio to complement the 11 bright pastels:
        // a neutral (sumi), a cool (moonlight), a warm (latte).
        // isPastel: false — S3 wiring can use a quieter vibrancy tint here.

        /// 墨 — ink on washi paper. Warm paper white with charcoal ink;
        /// the accent is 朱 (shu, vermilion seal red), so a completed
        /// checkbox reads like a hanko stamp on an ink document.
        FloteThemeSpec(
            id: "sumi", nameJP: "墨", nameEN: "Sumi Ink",
            light: .init(
                background: .rgb(0.957, 0.945, 0.914),
                toolbar:    .rgb(0.918, 0.902, 0.859),
                text:       .rgb(0.169, 0.165, 0.153),  // CR 12.7:1 vs bg, 11.5:1 vs toolbar
                accent:     .rgb(0.796, 0.255, 0.149)), // vermilion, CR 4.3:1 vs bg
            dark: .init(
                background: .rgb(0.110, 0.110, 0.102),
                toolbar:    .rgb(0.153, 0.153, 0.143),
                text:       .rgb(0.910, 0.894, 0.855),  // CR 13.4:1 vs bg, 11.8:1 vs toolbar
                accent:     .rgb(0.886, 0.373, 0.267)), // CR 4.8:1 vs bg
            isPastel: false),

        /// 月光 — moonlight silver. Cool silver-blue paper by day, deep
        /// night slate with moonlit ink after dark. The quiet cool option
        /// for people who find pastels too sweet.
        FloteThemeSpec(
            id: "moonlight", nameJP: "月光", nameEN: "Moonlight",
            light: .init(
                background: .rgb(0.914, 0.929, 0.957),
                toolbar:    .rgb(0.855, 0.878, 0.918),
                text:       .rgb(0.118, 0.149, 0.200),  // CR 12.9:1 vs bg, 11.5:1 vs toolbar
                accent:     .rgb(0.353, 0.486, 0.651)), // steel blue, CR 3.7:1 vs bg
            dark: .init(
                background: .rgb(0.102, 0.122, 0.169),
                toolbar:    .rgb(0.141, 0.165, 0.216),
                text:       .rgb(0.843, 0.871, 0.922),  // CR 12.2:1 vs bg, 10.6:1 vs toolbar
                accent:     .rgb(0.561, 0.659, 0.816)), // pale moon, CR 6.8:1 vs bg
            isPastel: false),

        /// 珈琲 — latte. Warm cream over espresso ink with a caramel
        /// accent; dark appearance is a dark-roast surface with foam-white
        /// ink. The warm neutral the pastel set was missing.
        FloteThemeSpec(
            id: "latte", nameJP: "珈琲", nameEN: "Latte",
            light: .init(
                background: .rgb(0.937, 0.894, 0.827),
                toolbar:    .rgb(0.894, 0.839, 0.757),
                text:       .rgb(0.200, 0.149, 0.102),  // CR 11.7:1 vs bg, 10.2:1 vs toolbar
                accent:     .rgb(0.663, 0.443, 0.294)), // caramel, CR 3.2:1 vs bg
            dark: .init(
                background: .rgb(0.141, 0.110, 0.082),
                toolbar:    .rgb(0.188, 0.153, 0.118),
                text:       .rgb(0.918, 0.875, 0.808),  // CR 12.7:1 vs bg, 11.1:1 vs toolbar
                accent:     .rgb(0.784, 0.565, 0.392)), // CR 6.1:1 vs bg
            isPastel: false),

        /// 白磁 — white porcelain. The clean near-neutral the pastel set
        /// lacked: a barely-warm gallery white with slate ink and a quiet
        /// indigo accent. For people who want a sticky that reads as a
        /// plain sheet of good paper.
        FloteThemeSpec(
            id: "porcelain", nameJP: "白磁", nameEN: "Porcelain",
            light: .init(
                background: .rgb(0.972, 0.970, 0.962),
                toolbar:    .rgb(0.928, 0.926, 0.916),
                text:       .rgb(0.168, 0.176, 0.190),  // CR 12.9:1 vs bg, 11.7:1 vs toolbar
                accent:     .rgb(0.290, 0.400, 0.680)), // indigo, CR 5.2:1 vs bg
            dark: .init(
                background: .rgb(0.118, 0.122, 0.130),
                toolbar:    .rgb(0.160, 0.165, 0.175),
                text:       .rgb(0.900, 0.902, 0.906),  // CR 13.2:1 vs bg, 11.5:1 vs toolbar
                accent:     .rgb(0.560, 0.660, 0.900)), // CR 7.0:1 vs bg
            isPastel: false),

        // ── 6 dark-identity themes (S14) ───────────────────────────────
        // Antinote's world: a dark rounded panel floating over the desktop
        // wallpaper. These render dark ALWAYS (the light slot IS the night
        // surface; notes never follow OS appearance — NoteView contract),
        // so dark == light by design and a future explicit dark-note mode
        // changes nothing for them. Backgrounds sit at ≤ 0.04 relative
        // luminance so the aqua frost's 10% bleed (design principle 6)
        // cannot lift them: every ink below also clears AA against the
        // worst-case composite 0.9·bg + 0.1·white ("frost gate", CRs noted
        // as "frost"). variableDef is hand-designed per theme (Antinote
        // grammar: a def reads as its own family, not the answer family);
        // keyword and variableUse stay derived.

        /// 夜空 — night sky. Deep indigo panel, moonlit ink, star-gold
        /// accent, teal variable defs. Designed around dot paper — a faint
        /// star field behind the text.
        FloteThemeSpec(
            id: "nightsky", nameJP: "夜空", nameEN: "Night Sky",
            light: .init(
                background: .rgb(0.078, 0.098, 0.180),
                toolbar:    .rgb(0.112, 0.138, 0.238),
                text:       .rgb(0.878, 0.892, 0.932),  // CR 13.6:1 vs bg, 12.1:1 vs toolbar, 10.2:1 frost
                accent:     .rgb(0.906, 0.760, 0.420),  // star gold, CR 10.2:1 vs bg, 7.7:1 frost
                variableDef: .rgb(0.478, 0.780, 0.760)), // teal, CR 8.9:1 vs bg
            dark: .init(
                background: .rgb(0.078, 0.098, 0.180),
                toolbar:    .rgb(0.112, 0.138, 0.238),
                text:       .rgb(0.878, 0.892, 0.932),
                accent:     .rgb(0.906, 0.760, 0.420),
                variableDef: .rgb(0.478, 0.780, 0.760)),
            isPastel: false, recommendedPaper: .dots),

        /// 深海 — deep sea. Abyssal blue-green panel, foam ink, bright
        /// cyan accent, warm sand variable defs (cool answers / warm defs
        /// keeps the two families apart at a glance). Square-grid paper —
        /// a sonar chart.
        FloteThemeSpec(
            id: "deepsea", nameJP: "深海", nameEN: "Deep Sea",
            light: .init(
                background: .rgb(0.043, 0.110, 0.145),
                toolbar:    .rgb(0.066, 0.152, 0.194),
                text:       .rgb(0.855, 0.912, 0.916),  // CR 13.9:1 vs bg, 12.4:1 vs toolbar, 10.5:1 frost
                accent:     .rgb(0.360, 0.788, 0.824),  // cyan, CR 8.9:1 vs bg, 6.7:1 frost
                variableDef: .rgb(0.870, 0.742, 0.520)), // sand, CR 9.7:1 vs bg
            dark: .init(
                background: .rgb(0.043, 0.110, 0.145),
                toolbar:    .rgb(0.066, 0.152, 0.194),
                text:       .rgb(0.855, 0.912, 0.916),
                accent:     .rgb(0.360, 0.788, 0.824),
                variableDef: .rgb(0.870, 0.742, 0.520)),
            isPastel: false, recommendedPaper: .grid),

        /// 炭 — charcoal. True neutral graphite with an ember-orange
        /// accent and cool steel variable defs; the no-color dark option.
        /// Blank paper — pure focus.
        FloteThemeSpec(
            id: "charcoal", nameJP: "炭", nameEN: "Charcoal",
            light: .init(
                background: .rgb(0.118, 0.118, 0.126),
                toolbar:    .rgb(0.161, 0.161, 0.172),
                text:       .rgb(0.906, 0.900, 0.890),  // CR 13.3:1 vs bg, 11.6:1 vs toolbar, 9.8:1 frost
                accent:     .rgb(0.930, 0.552, 0.350),  // ember, CR 6.8:1 vs bg, 5.0:1 frost
                variableDef: .rgb(0.560, 0.740, 0.850)), // steel, CR 8.3:1 vs bg
            dark: .init(
                background: .rgb(0.118, 0.118, 0.126),
                toolbar:    .rgb(0.161, 0.161, 0.172),
                text:       .rgb(0.906, 0.900, 0.890),
                accent:     .rgb(0.930, 0.552, 0.350),
                variableDef: .rgb(0.560, 0.740, 0.850)),
            isPastel: false),

        /// 常磐 — evergreen (tokiwa: the unchanging green of pines).
        /// Deep forest panel, spring-bud accent, warm straw variable defs.
        /// Ruled paper — a field notebook.
        FloteThemeSpec(
            id: "evergreen", nameJP: "常磐", nameEN: "Evergreen",
            light: .init(
                background: .rgb(0.055, 0.125, 0.096),
                toolbar:    .rgb(0.081, 0.170, 0.132),
                text:       .rgb(0.870, 0.915, 0.886),  // CR 13.7:1 vs bg, 12.0:1 vs toolbar, 10.2:1 frost
                accent:     .rgb(0.492, 0.800, 0.522),  // spring bud, CR 8.8:1 vs bg, 6.6:1 frost
                variableDef: .rgb(0.840, 0.760, 0.480)), // straw, CR 9.6:1 vs bg
            dark: .init(
                background: .rgb(0.055, 0.125, 0.096),
                toolbar:    .rgb(0.081, 0.170, 0.132),
                text:       .rgb(0.870, 0.915, 0.886),
                accent:     .rgb(0.492, 0.800, 0.522),
                variableDef: .rgb(0.840, 0.760, 0.480)),
            isPastel: false, recommendedPaper: .lines),

        /// 宵 — dusk (yoi: the hour just after sunset). Plum-violet panel,
        /// pale wisteria accent, sea-green variable defs. Dot paper — the
        /// first stars coming out.
        FloteThemeSpec(
            id: "dusk", nameJP: "宵", nameEN: "Dusk",
            light: .init(
                background: .rgb(0.132, 0.092, 0.172),
                toolbar:    .rgb(0.176, 0.126, 0.226),
                text:       .rgb(0.906, 0.882, 0.930),  // CR 13.3:1 vs bg, 11.9:1 vs toolbar, 10.0:1 frost
                accent:     .rgb(0.760, 0.610, 0.930),  // wisteria, CR 7.5:1 vs bg, 5.6:1 frost
                variableDef: .rgb(0.480, 0.780, 0.720)), // sea green, CR 8.7:1 vs bg
            dark: .init(
                background: .rgb(0.132, 0.092, 0.172),
                toolbar:    .rgb(0.176, 0.126, 0.226),
                text:       .rgb(0.906, 0.882, 0.930),
                accent:     .rgb(0.760, 0.610, 0.930),
                variableDef: .rgb(0.480, 0.780, 0.720)),
            isPastel: false, recommendedPaper: .dots),

        /// 雨雲 — rain cloud. Slate blue-gray panel — softer than 炭,
        /// cooler than 夜空 — with a rain-blue accent and warm amber
        /// variable defs. Square-grid paper — window glass in the rain.
        FloteThemeSpec(
            id: "raincloud", nameJP: "雨雲", nameEN: "Rain Cloud",
            light: .init(
                background: .rgb(0.130, 0.148, 0.166),
                toolbar:    .rgb(0.172, 0.194, 0.216),
                text:       .rgb(0.888, 0.902, 0.912),  // CR 12.2:1 vs bg, 10.4:1 vs toolbar, 8.9:1 frost
                accent:     .rgb(0.560, 0.750, 0.880),  // rain blue, CR 7.8:1 vs bg, 5.7:1 frost
                variableDef: .rgb(0.860, 0.720, 0.540)), // amber, CR 8.2:1 vs bg
            dark: .init(
                background: .rgb(0.130, 0.148, 0.166),
                toolbar:    .rgb(0.172, 0.194, 0.216),
                text:       .rgb(0.888, 0.902, 0.912),
                accent:     .rgb(0.560, 0.750, 0.880),
                variableDef: .rgb(0.860, 0.720, 0.540)),
            isPastel: false, recommendedPaper: .grid),

        // ── 6 editor-family themes (S16 — the Antinote soul port) ──────
        // Ground truth = the owner's Antinote reference shots (2026-07-12,
        // scratchpad/antinote-shots/): moody DEEP grounds sampled from the
        // frames — not invented, not pastel — and the syntax slots carry
        // the identity: keyword / variableDef / variableUse / calcAnswer
        // each in a distinct high-saturation family. The coloring is a
        // LEGIBILITY feature (owner: 「文字の色が自動で変わって、見ている
        // 側からして使いやすい」). keyword derives from accent (the caret/
        // checkbox family IS the keyword family in every reference frame);
        // variableDef and calcAnswer are designed per theme. All CR floors
        // + frost gate harness-asserted like every other entry; the five
        // dark grounds sit at ≤ 0.02 luminance (frost headroom, principle 6).

        /// 夜の森 — the mononoke-frame port: near-black green-tinted
        /// ground, green keyword/caret, mint variable defs (uses dim to
        /// the quoted teal), RED answers. Dot paper, faint.
        FloteThemeSpec(
            id: "nightforest", nameJP: "夜の森", nameEN: "Night Forest",
            light: .init(
                background: .rgb(0.106, 0.122, 0.106),  // sampled #1B1F1B panel
                toolbar:    .rgb(0.150, 0.170, 0.150),
                text:       .rgb(0.929, 0.929, 0.906),  // CR 14.2:1 vs bg, 10.5:1 frost
                accent:     .rgb(0.365, 0.647, 0.345),  // keyword/caret green, CR 5.5:1
                variableDef: .rgb(0.560, 0.831, 0.745), // mint teal, CR 9.8:1
                calcAnswer: .rgb(0.918, 0.353, 0.302)), // answer red, CR 4.8:1, 3.6:1 frost
            dark: .init(
                background: .rgb(0.106, 0.122, 0.106),
                toolbar:    .rgb(0.150, 0.170, 0.150),
                text:       .rgb(0.929, 0.929, 0.906),
                accent:     .rgb(0.365, 0.647, 0.345),
                variableDef: .rgb(0.560, 0.831, 0.745),
                calcAnswer: .rgb(0.918, 0.353, 0.302)),
            isPastel: false, recommendedPaper: .dots,
            family: .editor, prefersMonospace: true),

        /// 試写室 — the a24-frame port: charcoal with a green-black cast,
        /// CREAM body text, dim-teal keyword, burnt-orange answers, dot
        /// grid. The quiet film-poster one.
        FloteThemeSpec(
            id: "screeningroom", nameJP: "試写室", nameEN: "Screening Room",
            light: .init(
                background: .rgb(0.086, 0.102, 0.090),  // sampled #161A17 panel
                toolbar:    .rgb(0.125, 0.145, 0.128),
                text:       .rgb(0.922, 0.875, 0.769),  // cream, CR 13.3:1 vs bg, 10.0:1 frost
                accent:     .rgb(0.431, 0.620, 0.580),  // dim teal (keyword), CR 5.9:1
                variableDef: .rgb(0.588, 0.784, 0.737), // lifted teal, CR 8.9:1
                calcAnswer: .rgb(0.808, 0.482, 0.271)), // burnt orange, CR 5.5:1, 4.1:1 frost
            dark: .init(
                background: .rgb(0.086, 0.102, 0.090),
                toolbar:    .rgb(0.125, 0.145, 0.128),
                text:       .rgb(0.922, 0.875, 0.769),
                accent:     .rgb(0.431, 0.620, 0.580),
                variableDef: .rgb(0.588, 0.784, 0.737),
                calcAnswer: .rgb(0.808, 0.482, 0.271)),
            isPastel: false, recommendedPaper: .dots,
            family: .editor, prefersMonospace: true),

        /// 首都高 — the tokyodrift-frame port: violet-tinted charcoal,
        /// cyan keyword, lavender variable defs, NEON-GREEN answers,
        /// square grid. The night-drive one.
        FloteThemeSpec(
            id: "neoncircuit", nameJP: "首都高", nameEN: "Neon Circuit",
            light: .init(
                background: .rgb(0.137, 0.129, 0.157),  // sampled #232128 panel
                toolbar:    .rgb(0.180, 0.171, 0.204),
                text:       .rgb(0.925, 0.918, 0.941),  // CR 13.3:1 vs bg, 9.8:1 frost
                accent:     .rgb(0.322, 0.722, 0.910),  // cyan (keyword), CR 7.1:1
                variableDef: .rgb(0.757, 0.627, 0.941), // lavender, CR 7.2:1
                calcAnswer: .rgb(0.231, 0.839, 0.357)), // neon green, CR 8.3:1
            dark: .init(
                background: .rgb(0.137, 0.129, 0.157),
                toolbar:    .rgb(0.180, 0.171, 0.204),
                text:       .rgb(0.925, 0.918, 0.941),
                accent:     .rgb(0.322, 0.722, 0.910),
                variableDef: .rgb(0.757, 0.627, 0.941),
                calcAnswer: .rgb(0.231, 0.839, 0.357)),
            isPastel: false, recommendedPaper: .grid,
            family: .editor, prefersMonospace: true),

        /// 設計図 — the light editor theme (gundam-shot class): pale cool
        /// grid paper with cobalt keyword, teal-ink variable defs, and
        /// ORANGE answers — an engineering drawing you can type on. The
        /// dark slot is the same drawing at night (light-identity theme,
        /// so notes render the light slot; the night slot serves a future
        /// dark-note mode).
        FloteThemeSpec(
            id: "blueprint", nameJP: "設計図", nameEN: "Blueprint",
            light: .init(
                background: .rgb(0.961, 0.969, 0.976),  // pale drafting white
                toolbar:    .rgb(0.906, 0.922, 0.937),
                text:       .rgb(0.145, 0.165, 0.196),  // slate ink, CR 13.4:1
                accent:     .rgb(0.075, 0.365, 0.740),  // cobalt (keyword), CR 5.9:1
                variableDef: .rgb(0.000, 0.443, 0.435), // teal ink, CR 5.5:1
                calcAnswer: .rgb(0.784, 0.380, 0.060)), // marker orange, CR 3.8:1
            dark: .init(
                background: .rgb(0.075, 0.110, 0.161),
                toolbar:    .rgb(0.108, 0.150, 0.212),
                text:       .rgb(0.886, 0.914, 0.941),  // CR 14.0:1 vs bg
                accent:     .rgb(0.420, 0.660, 0.960),  // lifted cobalt, CR 7.0:1
                variableDef: .rgb(0.420, 0.780, 0.760),
                calcAnswer: .rgb(0.960, 0.620, 0.320)),
            isPastel: false, recommendedPaper: .grid,
            family: .editor, prefersMonospace: true),

        /// 夜光虫 — original, same reference language: abyssal ink-blue
        /// ground, electric-cyan keyword, warm-sand variable defs,
        /// MAGENTA answers — bioluminescence on a night sea. Dot paper.
        FloteThemeSpec(
            id: "noctiluca", nameJP: "夜光虫", nameEN: "Noctiluca",
            light: .init(
                background: .rgb(0.051, 0.075, 0.110),  // abyss #0D131C
                toolbar:    .rgb(0.084, 0.114, 0.157),
                text:       .rgb(0.878, 0.910, 0.925),  // CR 15.0:1 vs bg, 11.5:1 frost
                accent:     .rgb(0.290, 0.867, 0.878),  // electric cyan, CR 11.3:1
                variableDef: .rgb(0.914, 0.729, 0.427), // warm sand, CR 10.4:1
                calcAnswer: .rgb(0.949, 0.408, 0.584)), // magenta, CR 6.4:1, 4.9:1 frost
            dark: .init(
                background: .rgb(0.051, 0.075, 0.110),
                toolbar:    .rgb(0.084, 0.114, 0.157),
                text:       .rgb(0.878, 0.910, 0.925),
                accent:     .rgb(0.290, 0.867, 0.878),
                variableDef: .rgb(0.914, 0.729, 0.427),
                calcAnswer: .rgb(0.949, 0.408, 0.584)),
            isPastel: false, recommendedPaper: .dots,
            family: .editor, prefersMonospace: true),

        /// 琥珀 — original, same reference language: warm-black CRT
        /// ground, bright-amber keyword, phosphor-green variable defs,
        /// signal-red answers — a dual-phosphor terminal. Square grid
        /// (the character cell).
        FloteThemeSpec(
            id: "amberterminal", nameJP: "琥珀", nameEN: "Amber Terminal",
            light: .init(
                background: .rgb(0.086, 0.071, 0.051),  // warm black #16120D
                toolbar:    .rgb(0.125, 0.104, 0.078),
                text:       .rgb(0.941, 0.882, 0.769),  // warm cream, CR 14.4:1, 11.1:1 frost
                accent:     .rgb(0.976, 0.702, 0.200),  // bright amber, CR 10.2:1
                variableDef: .rgb(0.557, 0.812, 0.467), // phosphor green, CR 10.1:1
                calcAnswer: .rgb(0.929, 0.435, 0.286)), // signal red, CR 6.2:1, 4.7:1 frost
            dark: .init(
                background: .rgb(0.086, 0.071, 0.051),
                toolbar:    .rgb(0.125, 0.104, 0.078),
                text:       .rgb(0.941, 0.882, 0.769),
                accent:     .rgb(0.976, 0.702, 0.200),
                variableDef: .rgb(0.557, 0.812, 0.467),
                calcAnswer: .rgb(0.929, 0.435, 0.286)),
            isPastel: false, recommendedPaper: .grid,
            family: .editor, prefersMonospace: true),
    ]

    /// O(1) id lookup table, built once from `allSpecs`.
    private static let specsByID: [String: FloteThemeSpec] =
        Dictionary(uniqueKeysWithValues: allSpecs.map { ($0.id, $0) })

    /// The spec used when a stored id no longer resolves (theme removed,
    /// corrupted prefs). Yellow — the historical default sticky color.
    static let fallbackSpec: FloteThemeSpec =
        allSpecs.first { $0.id == "yellow" } ?? allSpecs[0]

    /// Look up a theme by stable id. `nil` if unknown (caller decides
    /// whether to fall back — the Settings picker should surface "missing",
    /// note rendering should use `specForLegacy` / `fallbackSpec`).
    static func spec(for id: String) -> FloteThemeSpec? {
        specsByID[id]
    }

    /// Resolve a legacy `NoteColorTheme.rawValue` (persisted in existing
    /// note JSON) to its spec. Total function: unknown values fall back to
    /// yellow so old data can never render un-themed. Because the 11 ported
    /// spec ids equal the legacy rawValues, this is a straight lookup —
    /// migration needs no data rewrite at all.
    static func specForLegacy(_ rawValue: String) -> FloteThemeSpec {
        specsByID[rawValue] ?? fallbackSpec
    }
}

// MARK: - PaperType (paper texture presets)

/// The paper texture drawn between the note background and the text.
/// Pure data enum (Codable rawValue persists in UserDefaults); the actual
/// drawing lives in `PaperPatternView` below. Stays inside the PURE region:
/// `FloteThemeSpec.recommendedPaper` references it, so the contrast harness
/// compiles it too.
enum PaperType: String, CaseIterable, Codable, Identifiable, Sendable {
    case blank
    case lines
    case dots
    case grid

    var id: String { rawValue }

    /// Japanese display name for the Settings picker.
    var displayNameJP: String {
        switch self {
        case .blank: return "無地"
        case .lines: return "罫線"
        case .dots:  return "ドット"
        case .grid:  return "方眼"
        }
    }

    /// English display name.
    var displayNameEN: String {
        switch self {
        case .blank: return "Blank"
        case .lines: return "Lines"
        case .dots:  return "Dots"
        case .grid:  return "Grid"
        }
    }

    /// Pattern pitch in points. Lines are wider (text line rhythm),
    /// dots/grid tighter (bullet-journal feel).
    ///
    /// Grid = 19, matching FloteLayoutManager.fallbackRulePitch (the
    /// default 11pt body line + 2.5 spacing): the editor's horizontal
    /// rules are line-coupled (~19pt), so a 22pt vertical pitch produced
    /// visibly NON-SQUARE cells — the "coarse/ugly grid" in the owner's
    /// 2026-07-12 screenshot. One shared pitch keeps cells square with
    /// the default line height everywhere the constant is consumed
    /// (editor verticals, empty-note fallback, Settings swatches).
    var patternSpacing: CGFloat {
        switch self {
        case .blank: return 0
        case .lines: return 26
        case .dots:  return 18
        case .grid:  return 19
        }
    }

    /// Default pattern ink opacity — low enough to stay texture, not content.
    static let defaultPatternOpacity: Double = 0.10
}

// MARK: - FloteCustomTheme (S15 Theme Maker — user themes as DATA)

/// A user-created theme. FOUR core slots plus a name — deliberately not
/// Antinote's 26 knobs: the semantic slots (keyword / variableDef /
/// variableUse) always DERIVE via the `Palette` rules, dark identity
/// derives from luminance, and the toolbar/text/accent relationships are
/// enforced by `FloteCustomThemeGate` at save time. The Theme Maker asks
/// for four colors; the system supplies the rest of the discipline.
struct FloteCustomTheme: Codable, Hashable, Identifiable, Sendable {
    /// Namespaced stable id — `custom.<UUID>`. The prefix guarantees a
    /// custom id can never collide with (or shadow) a built-in spec id.
    var id: String = FloteCustomTheme.newID()
    /// User-typed display name (JP OK). Used for both name slots.
    var name: String
    /// The four core slots (same roles as `FloteThemeSpec.Palette`).
    var background: FloteColorValue
    var toolbar: FloteColorValue
    var text: FloteColorValue
    var accent: FloteColorValue
    /// Advisory paper, same semantics as built-ins (previewed in the
    /// picker swatch, never overrides the user's global paper choice).
    var recommendedPaper: PaperType = .blank

    static let idPrefix = "custom."
    static func newID() -> String { idPrefix + UUID().uuidString }

    /// Dark identity — DERIVED from background luminance (the exact
    /// `FloteThemeSpec.isDarkTheme` math and threshold), never a toggle.
    var isDark: Bool { background.relativeLuminance < 0.35 }

    /// Bridge into registry currency. light == dark == the one designed
    /// palette (a custom theme has one face, like the S14 dark-identity
    /// built-ins); semantic slots stay nil (= derived).
    var spec: FloteThemeSpec {
        let palette = FloteThemeSpec.Palette(
            background: background, toolbar: toolbar, text: text, accent: accent)
        return FloteThemeSpec(
            id: id, nameJP: name, nameEN: name,
            light: palette, dark: palette,
            isPastel: false, recommendedPaper: recommendedPaper)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, background, toolbar, text, accent, recommendedPaper
    }
}

extension FloteCustomTheme {
    /// Tolerant decode: `recommendedPaper` is optional-with-default (a
    /// missing or unknown paper value degrades to `.blank`, it never kills
    /// the theme). The colors and name are load-bearing — absent/corrupt
    /// values fail the element, and `FloteCustomThemeCodec` skips it
    /// (fail closed: skip that theme, never crash).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        background = try c.decode(FloteColorValue.self, forKey: .background)
        toolbar = try c.decode(FloteColorValue.self, forKey: .toolbar)
        text = try c.decode(FloteColorValue.self, forKey: .text)
        accent = try c.decode(FloteColorValue.self, forKey: .accent)
        recommendedPaper =
            (try? c.decodeIfPresent(PaperType.self, forKey: .recommendedPaper)) ?? .blank
    }
}

// MARK: - FloteCustomThemeGate (the machine gate IS the design assistant)

/// Save-time contrast validation for custom themes: the SAME floors and the
/// SAME pure math the s14 harness asserts for every built-in, packaged so
/// the live Settings readout, the SAVE gate, and the s15 harness share one
/// implementation. SAVE stays disabled while any floor fails — a user
/// cannot create an unreadable theme.
enum FloteCustomThemeGate {
    /// WCAG AA body text.
    static let textFloor: Double = 4.5
    /// WCAG 1.4.11 non-text UI.
    static let accentFloor: Double = 3.0

    /// Worst-case rendered surface (design principle 6 / the s14 frost
    /// gate): NoteView paints the theme surface at 0.90 opacity over the
    /// aqua-pinned frost, so a pure-white wallpaper lifts the background
    /// to 0.9·bg + 0.1·white. Floors must hold THERE too — a dark custom
    /// theme carries the same headroom the dark built-ins do.
    static func frostedSurface(of background: FloteColorValue) -> FloteColorValue {
        var surface = background
        surface.opacity = 0.90
        return surface.composited(over: .rgb(1, 1, 1))
    }

    /// Effective text/background CR — the worst of the raw and frosted
    /// surfaces (floor 4.5).
    static func textOnBackground(text: FloteColorValue,
                                 background: FloteColorValue) -> Double {
        min(text.contrastRatio(against: background),
            text.contrastRatio(against: frostedSurface(of: background)))
    }

    /// text/toolbar CR (raw — the pair s14 gates for every palette; floor 4.5).
    static func textOnToolbar(text: FloteColorValue,
                              toolbar: FloteColorValue) -> Double {
        text.contrastRatio(against: toolbar)
    }

    /// Effective accent/background CR — raw + frost minimum (floor 3.0).
    /// Because a custom theme's semantic slots always derive from accent
    /// (keyword = variableDef = accent), this floor IS the s14
    /// keyword/variableDef floor as well.
    static func accentOnBackground(accent: FloteColorValue,
                                   background: FloteColorValue) -> Double {
        min(accent.contrastRatio(against: background),
            accent.contrastRatio(against: frostedSurface(of: background)))
    }

    /// Every violated floor, machine-readable. Empty == saveable.
    static func violations(background: FloteColorValue, toolbar: FloteColorValue,
                           text: FloteColorValue, accent: FloteColorValue) -> [String] {
        var v: [String] = []
        if textOnBackground(text: text, background: background) < textFloor {
            v.append("text/background")
        }
        if textOnToolbar(text: text, toolbar: toolbar) < textFloor {
            v.append("text/toolbar")
        }
        if accentOnBackground(accent: accent, background: background) < accentFloor {
            v.append("accent/background")
        }
        return v
    }

    static func passes(_ theme: FloteCustomTheme) -> Bool {
        violations(background: theme.background, toolbar: theme.toolbar,
                   text: theme.text, accent: theme.accent).isEmpty
    }
}

// MARK: - FloteCustomThemeCodec (pure persistence rules)

/// Custom-theme persistence as pure Data-in/Data-out functions, so the s15
/// harness exercises the exact shipping round-trip and fail-closed rules.
enum FloteCustomThemeCodec {

    /// Element wrapper that swallows a single corrupt entry instead of
    /// failing the whole array.
    private struct Lossy: Decodable {
        let theme: FloteCustomTheme?
        init(from decoder: Decoder) {
            theme = try? FloteCustomTheme(from: decoder)
        }
    }

    /// Decode stored JSON, fail closed at every level: a corrupt blob
    /// yields `[]`; a corrupt ELEMENT is skipped; an element outside the
    /// `custom.` id namespace (it could shadow a built-in) or duplicating
    /// an earlier id is skipped. Never throws, never crashes.
    static func decode(_ data: Data) -> [FloteCustomTheme] {
        guard let items = try? JSONDecoder().decode([Lossy].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return items.compactMap { $0.theme }.filter { theme in
            theme.id.hasPrefix(FloteCustomTheme.idPrefix) && seen.insert(theme.id).inserted
        }
    }

    static func encode(_ themes: [FloteCustomTheme]) -> Data? {
        try? JSONEncoder().encode(themes)
    }

    /// Pure fallback rule for deletion: removing the ACTIVE theme id
    /// returns nil (= per-note default mode — the graceful landing, never
    /// a dangling id or blank palette); removing any other id leaves the
    /// current selection untouched.
    static func activeTheme(afterDeleting id: String, current: String?) -> String? {
        current == id ? nil : current
    }
}

// S14-THEME-PURE-END

// MARK: - SurfaceMaterial (S3c texture axis)

/// The note's surface finish — a texture layer independent of the color
/// theme AND the paper pattern (three orthogonal axes: hue x paper x
/// material). Pure data enum; the drawing lives in `MaterialOverlayView`.
///
/// Adding a material = one case here + one branch in `MaterialOverlayView`.
enum SurfaceMaterial: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Plain pastel — exactly the pre-S3c surface. The default.
    case standard
    /// 和紙 — sparse fiber-and-fleck paper grain.
    case washi
    /// 金属 — vertically brushed sheen with a cool cast.
    case metal
    /// ガラス — glossy diagonal highlight with a deeper rim.
    case glass

    var id: String { rawValue }

    /// Japanese display name for the Settings picker.
    var displayNameJP: String {
        switch self {
        case .standard: return "標準"
        case .washi:    return "和紙"
        case .metal:    return "金属"
        case .glass:    return "ガラス"
        }
    }

    /// English display name.
    var displayNameEN: String {
        switch self {
        case .standard: return "Standard"
        case .washi:    return "Washi"
        case .metal:    return "Metal"
        case .glass:    return "Glass"
        }
    }
}

// MARK: - PaperPatternView (SwiftUI, Canvas-drawn, DPI-crisp)

/// Draws the selected `PaperType` pattern at low opacity over any note
/// background.
///
/// S3 wiring: overlay this between the background fill and the text view —
///
///     ZStack {
///         palette.background.color            // or vibrancy + tint
///         PaperPatternView(type: settings.paperType,
///                          ink: palette.text.color)
///         NoteTextView(...)
///     }
///
/// Crispness: positions are snapped to the device pixel grid using the
/// environment `displayScale`, and strokes are true hairlines (1 physical
/// pixel), so lines never straddle pixels and blur on Retina or 1x displays.
struct PaperPatternView: View {
    /// Which pattern to draw. `.blank` draws nothing.
    var type: PaperType
    /// Pattern ink — pass the theme's text ink so the pattern automatically
    /// harmonizes with every theme in both appearances.
    var ink: Color
    /// Opacity applied to `ink`. Defaults to `PaperType.defaultPatternOpacity`.
    var patternOpacity: Double = PaperType.defaultPatternOpacity
    /// Line pitch override — pass the editor's text line height so 罫線/方眼
    /// rows align with the written lines instead of drifting through them
    /// (Tom 2026-07-10: 「横の線がずれる」). nil = the type's default spacing.
    var spacingOverride: CGFloat? = nil

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard type != .blank, size.width > 0, size.height > 0 else { return }

            let scale = max(context.environment.displayScale, 1)
            let hairline = 1 / scale
            let shading = GraphicsContext.Shading.color(ink.opacity(patternOpacity))
            let spacing = spacingOverride ?? type.patternSpacing

            /// Snap a coordinate onto the pixel grid, offset by half a
            /// physical pixel so a hairline stroke fills exactly one pixel row.
            func snapped(_ v: CGFloat) -> CGFloat {
                ((v * scale).rounded() + 0.5) / scale
            }

            switch type {
            case .blank:
                break

            case .lines:
                var path = Path()
                var y = spacing
                while y < size.height {
                    let sy = snapped(y)
                    path.move(to: CGPoint(x: 0, y: sy))
                    path.addLine(to: CGPoint(x: size.width, y: sy))
                    y += spacing
                }
                context.stroke(path, with: shading, lineWidth: hairline)

            case .grid:
                var path = Path()
                var y = spacing
                while y < size.height {
                    let sy = snapped(y)
                    path.move(to: CGPoint(x: 0, y: sy))
                    path.addLine(to: CGPoint(x: size.width, y: sy))
                    y += spacing
                }
                var x = spacing
                while x < size.width {
                    let sx = snapped(x)
                    path.move(to: CGPoint(x: sx, y: 0))
                    path.addLine(to: CGPoint(x: sx, y: size.height))
                    x += spacing
                }
                context.stroke(path, with: shading, lineWidth: hairline)

            case .dots:
                var path = Path()
                let radius: CGFloat = 1.2
                var y = spacing
                while y < size.height {
                    var x = spacing
                    while x < size.width {
                        // Snap centers (not edges) — a filled dot tolerates
                        // sub-pixel edges; centering keeps rows even.
                        let cx = (x * scale).rounded() / scale
                        let cy = (y * scale).rounded() / scale
                        path.addEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                                   width: radius * 2, height: radius * 2))
                        x += spacing
                    }
                    y += spacing
                }
                context.fill(path, with: shading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - MaterialOverlayView (S3c surface finishes)

/// Renders the selected `SurfaceMaterial` as a translucent texture layer.
///
/// NoteView layering (bottom → top): photo/tint background → THIS →
/// paper pattern → text. Everything here is deliberately faint: at default
/// settings a material must read as a FINISH on the pastel, never as
/// content. All randomness is deterministic (coordinate-hashed), so panels
/// never shimmer across SwiftUI re-renders and every note shows the same
/// grain.
///
/// Opacity rationale (tested against the light pastel palettes, whose
/// backgrounds sit around 0.83–1.0 luminance). S16 (2026-07-12): every
/// layer amplified ~1.7–1.9x from the original values — at the original
/// strengths switching materials was a squint test; the owner's brief is
/// "switching must be unmistakable". The caps below are the tasteful
/// ceilings: they bind at preview boost (intensity 3) and keep any
/// future boost from turning a finish into a poster.
/// - washi flecks 5.5% / fibers 4% on a denser 55% cell fill: visible
///   paper grain at arm's length, still texture rather than dirt.
/// - metal cast 14% + streaks ≤7%: the cool cast reads as a different
///   MATERIAL now, not just a different hue; streaks break the flatness.
/// - glass gloss peaks at 22% white + a 28% catch-light: white-on-
///   near-white needs the most contrast of the three to register, and a
///   highlight (adding light) stays tasteful at higher opacity than
///   grime (adding dark) would.
struct MaterialOverlayView: View {
    var material: SurfaceMaterial
    /// Grain ink for washi. Defaults to the warm note ink; pass the theme
    /// ink so the grain harmonizes with curated themes (sumi, moonlight…).
    var ink: Color = Color(.sRGB, red: 0.22, green: 0.18, blue: 0.14, opacity: 1)
    /// Opacity multiplier. 1 = the designed in-note strength. The Settings
    /// preview cards pass ~3 so a 52x36 swatch still communicates the
    /// texture. Individual layers clamp to sane maxima.
    var intensity: Double = 1

    var body: some View {
        Group {
            switch material {
            case .standard:
                EmptyView()
            case .washi:
                washi
            case .metal:
                metal
            case .glass:
                glass
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Clamped layer opacity: base * intensity, capped so preview boosting
    /// can never turn a texture into a poster.
    private func alpha(_ base: Double, cap: Double = 0.5) -> Double {
        min(base * intensity, cap)
    }

    // MARK: washi — sparse fiber + fleck grain

    private var washi: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let cell: CGFloat = 13
            let cols = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            var flecks = Path()
            var fibers = Path()
            for row in 0...rows {
                for col in 0...cols {
                    // Sparse: only ~55% of cells carry anything, so the
                    // texture stays airy like real washi, not TV static.
                    guard Self.hash01(col, row, 0) < 0.55 else { continue }
                    let x = (CGFloat(col) + CGFloat(Self.hash01(col, row, 1))) * cell
                    let y = (CGFloat(row) + CGFloat(Self.hash01(col, row, 2))) * cell
                    if Self.hash01(col, row, 3) < 0.55 {
                        // Fleck: 0.5–1.2pt — pulp specks.
                        let r = 0.5 + CGFloat(Self.hash01(col, row, 4)) * 0.7
                        flecks.addEllipse(in: CGRect(x: x - r, y: y - r,
                                                     width: r * 2, height: r * 2))
                    } else {
                        // Fiber: 3–7pt strand at a shallow random angle.
                        let len = 3 + CGFloat(Self.hash01(col, row, 5)) * 4
                        let angle = (CGFloat(Self.hash01(col, row, 6)) - 0.5) * .pi * 0.6
                        let dx = cos(angle) * len / 2
                        let dy = sin(angle) * len / 2
                        fibers.move(to: CGPoint(x: x - dx, y: y - dy))
                        fibers.addLine(to: CGPoint(x: x + dx, y: y + dy))
                    }
                }
            }
            context.fill(flecks, with: .color(ink.opacity(alpha(0.055, cap: 0.20))))
            context.stroke(fibers, with: .color(ink.opacity(alpha(0.040, cap: 0.16))),
                           lineWidth: 1.0)
        }
    }

    // MARK: metal — brushed vertical sheen

    private var metal: some View {
        ZStack {
            // Cool desaturation cast: pulls the warm pastel toward steel
            // without hiding its hue.
            Color(.sRGB, red: 0.62, green: 0.66, blue: 0.72, opacity: 1)
                .opacity(alpha(0.14, cap: 0.32))
            // Brushed grain: full-height hairline streaks at random pitch.
            // Two buckets (light/dark) — the alternation is what reads as
            // "brushed" rather than "striped".
            Canvas(rendersAsynchronously: false) { context, size in
                guard size.width > 0, size.height > 0 else { return }
                var light = Path()
                var dark = Path()
                var x: CGFloat = 0
                var i = 0
                while x < size.width {
                    let roll = Self.hash01(i, 0, 7)
                    if roll < 0.42 {
                        light.move(to: CGPoint(x: x, y: 0))
                        light.addLine(to: CGPoint(x: x, y: size.height))
                    } else if roll < 0.78 {
                        dark.move(to: CGPoint(x: x, y: 0))
                        dark.addLine(to: CGPoint(x: x, y: size.height))
                    } // else: skip — gaps keep the grain irregular.
                    x += 1.5 + CGFloat(Self.hash01(i, 1, 8)) * 2.2
                    i += 1
                }
                context.stroke(light, with: .color(.white.opacity(alpha(0.070, cap: 0.24))),
                               lineWidth: 0.8)
                context.stroke(dark, with: .color(.black.opacity(alpha(0.050, cap: 0.18))),
                               lineWidth: 0.8)
            }
            // Sheen: two soft vertical highlight bands, asymmetric on
            // purpose (symmetry reads as a gradient fill, not a reflection).
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0),                          location: 0.00),
                    .init(color: .white.opacity(alpha(0.16, cap: 0.38)),     location: 0.28),
                    .init(color: .white.opacity(0),                          location: 0.46),
                    .init(color: .white.opacity(alpha(0.08, cap: 0.24)),     location: 0.74),
                    .init(color: .white.opacity(0),                          location: 1.00),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    // MARK: glass — diagonal gloss + rim

    private var glass: some View {
        ZStack {
            // Gloss: one diagonal highlight falling from the top-left —
            // the classic "light source above the desk" read — with a
            // faint counter-glint near the bottom-right.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(alpha(0.22, cap: 0.48)), location: 0.00),
                    .init(color: .white.opacity(alpha(0.10, cap: 0.28)), location: 0.20),
                    .init(color: .white.opacity(0),                      location: 0.42),
                    .init(color: .white.opacity(0),                      location: 0.68),
                    .init(color: .white.opacity(alpha(0.08, cap: 0.22)), location: 0.90),
                    .init(color: .white.opacity(0),                      location: 1.00),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Crisp 1pt catch-light along the top edge — the cue that the
            // surface is a slab with thickness, not a printed gradient.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(alpha(0.28, cap: 0.55)))
                    .frame(height: 1)
                Spacer(minLength: 0)
            }
            // Rim vignette: edges sit a touch deeper than the center, the
            // way light falls off through the thickness of real glass.
            GeometryReader { geo in
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.00),
                        .init(color: .clear, location: 0.70),
                        .init(color: Color.black.opacity(alpha(0.10, cap: 0.22)), location: 1.00),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.72
                )
            }
        }
    }

    // MARK: deterministic hash

    /// Coordinate-seeded hash → [0, 1). Same (x, y, salt) always yields the
    /// same value: the texture is stable across renders, panels, and
    /// launches (SplitMix64-style avalanche).
    private static func hash01(_ x: Int, _ y: Int, _ salt: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(bitPattern: Int64(salt)) &* 0x1656_67B1_9E37_79F9
        h ^= h >> 30
        h &*= 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27
        h &*= 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Double(h % 1_048_576) / 1_048_576
    }
}

// MARK: - Appearance change notification

extension Notification.Name {
    /// Posted by `AppearanceSettings` on the main thread whenever any
    /// app-wide appearance value changes. `userInfo["key"]` names the
    /// changed property ("panelOpacity", "paperType", "useVibrancy",
    /// "appTheme"). AppKit-side observers (NSPanel alpha, NSVisualEffectView
    /// material) subscribe to this; pure SwiftUI views can instead observe
    /// `AppearanceSettings.shared` directly via `@Observable` tracking.
    static let floteAppearanceChanged = Notification.Name("floteAppearanceChanged")
}

// MARK: - AppearanceSettings (app-wide, persisted)

/// App-wide appearance state, persisted in `UserDefaults.standard`.
///
/// Single `@MainActor` singleton: SwiftUI views read properties directly
/// (Observation tracks access and invalidates automatically); AppKit code
/// that lives outside the SwiftUI update loop listens for
/// `.floteAppearanceChanged` instead.
///
/// Persistence: every mutation writes through to UserDefaults immediately
/// and posts one notification. Loading happens once, in the stored-property
/// default expressions (which never trigger `didSet`, so app launch is
/// silent — no spurious notification storm).
@MainActor
@Observable
final class AppearanceSettings {

    /// Shared app-wide instance. Use this everywhere; the type is a class
    /// specifically so all windows observe the same state.
    static let shared = AppearanceSettings()

    /// Allowed window opacity range. S16 (2026-07-12): floor lowered
    /// 0.7 → 0.3 so the slider visibly matters — Antinote reaches ~10%,
    /// but below ~30% body text dies over any busy wallpaper (the whole
    /// window fades, ink included: NSPanel.alphaValue), so 0.3 is OUR
    /// floor. The ghost-note look is available; the unreadable one is not.
    /// (`nonisolated`: immutable Sendable constant, read by the nonisolated
    /// UserDefaults loaders below — legal under Swift 6 isolation checking.)
    nonisolated static let panelOpacityRange: ClosedRange<Double> = 0.3...1.0
    /// 角丸 (S7-3, the "どこも未実装" leapfrog). S16 (2026-07-12): range
    /// extended 8–16 → 4–24 per the owner — 4 reads as a crisp card,
    /// 24 as a soft capsule; both are legitimate identities, so the
    /// slider now spans them. The value is app-level and changes ONLY
    /// through Settings — never per-note, never stow-coupled, never
    /// animated (the 2026-04-17 crash family). PanelManager applies it
    /// to AppKit layers outside of any in-flight animation (the safe
    /// path — unchanged by the range extension).
    nonisolated static let cornerRadiusRange: ClosedRange<Double> = 4.0...24.0

    private enum Keys {
        static let paperStrength = "floteAppearance.paperStrength"
        static let panelOpacity = "floteAppearance.panelOpacity"
        static let paperType    = "floteAppearance.paperType"
        static let useVibrancy  = "floteAppearance.useVibrancy"
        static let appTheme     = "floteAppearance.appTheme"
        static let cornerRadius = "floteAppearance.cornerRadius"
        static let surfaceMaterial = "floteAppearance.surfaceMaterial"
        static let customBackgroundFileName = "floteAppearance.customBackgroundFileName"
        static let customBackgroundDimming  = "floteAppearance.customBackgroundDimming"
    }

    // MARK: Stored settings

    /// Note window opacity, 0.7–1.0 (default 1.0 = fully opaque).
    /// S3 wiring: applied as the NSPanel `alphaValue` (window-level, so
    /// vibrancy, shadows, and text fade together).
    /// Out-of-range writes are clamped (the re-assignment inside `didSet`
    /// re-enters once and then settles via the equality guard).
    var cornerRadius: Double = AppearanceSettings.loadCornerRadius() {
        didSet {
            let clamped = min(max(cornerRadius, Self.cornerRadiusRange.lowerBound),
                              Self.cornerRadiusRange.upperBound)
            if clamped != cornerRadius {
                cornerRadius = clamped
                return
            }
            UserDefaults.standard.set(cornerRadius, forKey: Keys.cornerRadius)
            notify("cornerRadius")
        }
    }

    var panelOpacity: Double = AppearanceSettings.loadPanelOpacity() {
        didSet {
            let clamped = min(max(panelOpacity, Self.panelOpacityRange.lowerBound),
                              Self.panelOpacityRange.upperBound)
            if clamped != panelOpacity {
                panelOpacity = clamped
                return
            }
            UserDefaults.standard.set(panelOpacity, forKey: Keys.panelOpacity)
            notify("panelOpacity")
        }
    }

    /// Paper texture drawn on every note (default `.blank`).
    /// S3 wiring: feeds `PaperPatternView(type:ink:)` in NoteView.
    /// 罫線/ドット/方眼 の濃さ (Tom 2026-07-10: pattern strength must be
    /// user-adjustable). Multiplies the pattern ink opacity.
    var paperStrength: Double = AppearanceSettings.loadPaperStrength() {
        didSet {
            UserDefaults.standard.set(paperStrength, forKey: Keys.paperStrength)
            notify("paperStrength")
        }
    }

    var paperType: PaperType = AppearanceSettings.loadPaperType() {
        didSet {
            UserDefaults.standard.set(paperType.rawValue, forKey: Keys.paperType)
            notify("paperType")
        }
    }

    /// Whether note backgrounds sit on NSVisualEffectView vibrancy
    /// (the "light frosted float" look, default true) or a plain opaque
    /// fill (crisper, cheaper, and the automatic fallback when
    /// "Reduce transparency" is on in System Settings).
    var useVibrancy: Bool = AppearanceSettings.loadUseVibrancy() {
        didSet {
            UserDefaults.standard.set(useVibrancy, forKey: Keys.useVibrancy)
            notify("useVibrancy")
        }
    }

    /// App-wide theme override.
    /// - `nil` (default): legacy per-note behavior — each note renders its
    ///   own `colorTheme` hue via `FloteThemeRegistry.specForLegacy(_:)`.
    /// - non-nil: a `FloteThemeSpec.id`; every note renders that theme
    ///   regardless of its stored per-note hue (the per-note value is
    ///   preserved, so switching back to `nil` restores each note's color).
    var appTheme: String? = AppearanceSettings.loadAppTheme() {
        didSet {
            if let appTheme {
                UserDefaults.standard.set(appTheme, forKey: Keys.appTheme)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.appTheme)
            }
            notify("appTheme")
        }
    }

    /// S3c: surface finish rendered by `MaterialOverlayView` (default
    /// `.standard` = the pre-S3c plain pastel).
    var surfaceMaterial: SurfaceMaterial = AppearanceSettings.loadSurfaceMaterial() {
        didSet {
            UserDefaults.standard.set(surfaceMaterial.rawValue, forKey: Keys.surfaceMaterial)
            notify("surfaceMaterial")
        }
    }

    /// S3c: file name (inside `backgroundsDirectory`) of the user's custom
    /// note-background photo, or `nil` when none is set. Mutate ONLY via
    /// `setCustomBackground(from:)` / `removeCustomBackground()` — they own
    /// the file lifecycle (copy-in, delete-old) and the decoded image cache.
    private(set) var customBackgroundFileName: String? =
        AppearanceSettings.loadCustomBackgroundFileName() {
        didSet {
            if let customBackgroundFileName {
                UserDefaults.standard.set(customBackgroundFileName,
                                          forKey: Keys.customBackgroundFileName)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.customBackgroundFileName)
            }
            notify("customBackground")
        }
    }

    /// Decoded custom-background image, cached so NoteView never hits the
    /// disk during a render pass. Kept in lockstep with
    /// `customBackgroundFileName` by the mutators below. (`NSImage` is the
    /// one AppKit type in this file — AppearanceSettings is the app-glue
    /// layer, not the portable spec layer above.)
    private(set) var customBackgroundImage: NSImage? =
        AppearanceSettings.loadInitialCustomBackgroundImage()

    /// White-dimming strength laid over the custom photo (0 = photo raw,
    /// 0.8 = mostly paper). 0.35 default keeps typical photos readable
    /// without washing them out. Out-of-range writes clamp like
    /// `panelOpacity`.
    var customBackgroundDimming: Double = AppearanceSettings.loadCustomBackgroundDimming() {
        didSet {
            let clamped = min(max(customBackgroundDimming,
                                  Self.customBackgroundDimmingRange.lowerBound),
                              Self.customBackgroundDimmingRange.upperBound)
            if clamped != customBackgroundDimming {
                customBackgroundDimming = clamped
                return
            }
            UserDefaults.standard.set(customBackgroundDimming,
                                      forKey: Keys.customBackgroundDimming)
            notify("customBackgroundDimming")
        }
    }

    nonisolated static let customBackgroundDimmingRange: ClosedRange<Double> = 0.0...0.8

    // MARK: Custom background file management

    /// Where imported background photos live. We copy the user's file here
    /// during the NSOpenPanel grant, so no security-scoped bookmark is ever
    /// needed afterward (sandbox-safe by construction).
    nonisolated static var backgroundsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flote", isDirectory: true)
            .appendingPathComponent("Backgrounds", isDirectory: true)
    }

    /// Import `sourceURL` as the custom note background: copy it into
    /// `backgroundsDirectory` under a fresh UUID name (extension preserved),
    /// validate it decodes as an image, then swap state and delete the
    /// previous photo. Throws without touching current state if the copy or
    /// decode fails — a corrupt pick can never leave settings pointing at a
    /// blank background. Never touches note data.
    func setCustomBackground(from sourceURL: URL) throws {
        let fm = FileManager.default
        let dir = Self.backgroundsDirectory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "img" : sourceURL.pathExtension
        let fileName = UUID().uuidString + "." + ext
        let dest = dir.appendingPathComponent(fileName)
        try fm.copyItem(at: sourceURL, to: dest)
        guard let image = NSImage(contentsOf: dest), image.isValid else {
            try? fm.removeItem(at: dest)
            throw CocoaError(.fileReadCorruptFile)
        }
        let old = customBackgroundFileName
        customBackgroundImage = image
        customBackgroundFileName = fileName  // didSet persists + notifies
        if let old, old != fileName {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
    }

    /// Remove the custom background photo (state + file on disk).
    func removeCustomBackground() {
        if let old = customBackgroundFileName {
            try? FileManager.default.removeItem(
                at: Self.backgroundsDirectory.appendingPathComponent(old))
        }
        customBackgroundImage = nil
        customBackgroundFileName = nil  // didSet clears UserDefaults + notifies
    }

    // MARK: Derived

    /// Resolved spec for `appTheme`, or `nil` when in per-note mode or the
    /// stored id no longer exists. NoteView logic:
    /// `settings.appThemeSpec ?? FloteThemeRegistry.specForLegacy(note.colorTheme.rawValue)`.
    /// S15: routes through `resolvedSpec(for:)`, so a custom theme id works
    /// everywhere a built-in id does (NoteView, StowAnimator, FloteInk) with
    /// zero consumer changes — and a DELETED custom id resolves to nil,
    /// which lands in the per-note fallback (never a crash, never a blank
    /// palette).
    var appThemeSpec: FloteThemeSpec? {
        appTheme.flatMap { FloteThemeRegistry.resolvedSpec(for: $0) }
    }

    // MARK: Lifecycle

    private init() {}

    private func notify(_ key: String) {
        // S16 font bridge (contract with font-controls, 2026-07-12):
        // every appearance post carries the ACTIVE theme's resolved
        // monospace preference. FontPreference reads
        // `userInfo["prefersMonospace"] as? Bool` — a stringly key by
        // design, so neither branch needs the other's symbols to compile.
        NotificationCenter.default.post(
            name: .floteAppearanceChanged,
            object: self,
            userInfo: ["key": key,
                       "prefersMonospace": appThemeSpec?.prefersMonospace ?? false])
    }

    // MARK: One-shot UserDefaults loaders
    // Used as stored-property default expressions: they run during
    // initialization, where Swift never invokes property observers, so
    // loading persisted values can't post notifications or write back.

    /// 線の濃さ multiplier on the 0.10 base pattern opacity. S16
    /// (2026-07-12): extended 0.3–2.0 → 0.2–5.0 — at 2.0x the "max" was
    /// still a whisper (0.20 ink alpha; the owner's grid shot read weak).
    /// New span: 0.2x = 0.02 alpha (barely-there texture) … 5.0x = 0.50
    /// alpha (clearly bold, Antinote heavy-grid class). Both pattern
    /// consumers already clamp with min(1.0, …), so the ceiling is safe.
    nonisolated static let paperStrengthRange: ClosedRange<Double> = 0.2...5.0

    private nonisolated static func loadPaperStrength() -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.paperStrength) != nil else { return 1.0 }
        return min(max(defaults.double(forKey: Keys.paperStrength),
                       paperStrengthRange.lowerBound),
                   paperStrengthRange.upperBound)
    }

    private nonisolated static func loadPanelOpacity() -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.panelOpacity) != nil else { return 1.0 }
        return min(max(defaults.double(forKey: Keys.panelOpacity),
                       panelOpacityRange.lowerBound),
                   panelOpacityRange.upperBound)
    }

    private nonisolated static func loadPaperType() -> PaperType {
        guard let raw = UserDefaults.standard.string(forKey: Keys.paperType),
              let type = PaperType(rawValue: raw) else { return .blank }
        return type
    }

    private nonisolated static func loadUseVibrancy() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.useVibrancy) != nil else { return true }
        return defaults.bool(forKey: Keys.useVibrancy)
    }

    private nonisolated static func loadCornerRadius() -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.cornerRadius) != nil else { return 12 }
        return min(max(defaults.double(forKey: Keys.cornerRadius),
                       cornerRadiusRange.lowerBound), cornerRadiusRange.upperBound)
    }

    private nonisolated static func loadAppTheme() -> String? {
        UserDefaults.standard.string(forKey: Keys.appTheme)
    }

    private nonisolated static func loadSurfaceMaterial() -> SurfaceMaterial {
        guard let raw = UserDefaults.standard.string(forKey: Keys.surfaceMaterial),
              let material = SurfaceMaterial(rawValue: raw) else { return .standard }
        return material
    }

    private nonisolated static func loadCustomBackgroundFileName() -> String? {
        UserDefaults.standard.string(forKey: Keys.customBackgroundFileName)
    }

    /// One-shot decode of the persisted background photo at launch.
    /// A missing/corrupt file simply yields `nil` (note renders the plain
    /// themed surface); the stale file name is left in place so the user's
    /// choice survives e.g. a temporarily unreadable disk.
    private nonisolated static func loadInitialCustomBackgroundImage() -> NSImage? {
        guard let name = loadCustomBackgroundFileName() else { return nil }
        let url = backgroundsDirectory.appendingPathComponent(name)
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }

    private nonisolated static func loadCustomBackgroundDimming() -> Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.customBackgroundDimming) != nil else { return 0.35 }
        return min(max(defaults.double(forKey: Keys.customBackgroundDimming),
                       customBackgroundDimmingRange.lowerBound),
                   customBackgroundDimmingRange.upperBound)
    }
}

// MARK: - FloteCustomThemeStore (S15 Theme Maker — persistence + app glue)

/// User-created themes, persisted as Codable JSON in `UserDefaults`.
///
/// STORAGE DECISION: UserDefaults (key `floteCustomThemes`), not a file in
/// Application Support. A custom theme serializes to ~300 bytes (four RGBA
/// quadruples + name + paper + id); even an absurd 200-theme library is
/// well under 100 KB — orders of magnitude below any practical defaults
/// budget — and ALL other appearance state (theme choice, paper, opacity…)
/// already lives in UserDefaults, so reset/migration semantics stay in one
/// place. A file store would add a second persistence path to corrupt and
/// buy nothing.
///
/// All encode/decode/validation rules live in the PURE region
/// (`FloteCustomThemeCodec` / `FloteCustomThemeGate`) — this class is the
/// thin @MainActor shell that owns UserDefaults and change notification.
@MainActor
@Observable
final class FloteCustomThemeStore {

    static let shared = FloteCustomThemeStore()

    nonisolated static let defaultsKey = "floteCustomThemes"

    /// All custom themes, in creation order (= picker display order).
    /// Loaded once at init through the fail-closed codec: a corrupt blob or
    /// element can thin the list, never crash the app.
    private(set) var themes: [FloteCustomTheme] = FloteCustomThemeStore.load()

    private init() {}

    /// Resolve a custom theme id to registry currency. O(n) over a list
    /// that is user-created (tens, not thousands) — a dictionary would be
    /// premature.
    func spec(for id: String) -> FloteThemeSpec? {
        themes.first { $0.id == id }?.spec
    }

    func theme(for id: String) -> FloteCustomTheme? {
        themes.first { $0.id == id }
    }

    /// Insert or update (matched by id). FAIL-CLOSED: refuses a theme that
    /// violates the contrast floors or has a blank name — the Theme Maker
    /// UI disables SAVE first; this is the machine gate behind the button
    /// (the same pure function, so a future caller cannot sneak an
    /// unreadable theme past the roster discipline).
    @discardableResult
    func upsert(_ theme: FloteCustomTheme) -> Bool {
        guard FloteCustomThemeGate.passes(theme),
              !theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              theme.id.hasPrefix(FloteCustomTheme.idPrefix)
        else { return false }
        if let index = themes.firstIndex(where: { $0.id == theme.id }) {
            themes[index] = theme
        } else {
            themes.append(theme)
        }
        persist()
        return true
    }

    /// Delete by id. If the deleted theme is the ACTIVE app-wide theme,
    /// the selection falls back to per-note default mode (`appTheme = nil`)
    /// via the pure rule — the picker never shows a phantom selection and
    /// notes never lose their palette (NoteView's `specForLegacy` fallback
    /// covers even the one frame between resolve and reassign).
    func delete(id: String) {
        guard themes.contains(where: { $0.id == id }) else { return }
        themes.removeAll { $0.id == id }
        persist()
        let settings = AppearanceSettings.shared
        let resolved = FloteCustomThemeCodec.activeTheme(afterDeleting: id,
                                                         current: settings.appTheme)
        if resolved != settings.appTheme {
            settings.appTheme = resolved  // didSet persists + notifies
        }
    }

    private func persist() {
        if let data = FloteCustomThemeCodec.encode(themes) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        // AppKit-side theme consumers (panel chrome, editor ink) observe
        // this name with `object: nil` — editing the ACTIVE custom theme
        // must repaint live, exactly like switching appTheme does.
        // Carries the font-bridge bool like AppearanceSettings.notify()
        // (custom themes are always paper-family ⇒ resolves false unless
        // a built-in editor theme is somehow active — same one rule).
        NotificationCenter.default.post(
            name: .floteAppearanceChanged,
            object: self,
            userInfo: ["key": "customThemes",
                       "prefersMonospace":
                        AppearanceSettings.shared.appThemeSpec?.prefersMonospace ?? false])
    }

    private nonisolated static func load() -> [FloteCustomTheme] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return FloteCustomThemeCodec.decode(data)
    }
}

// S15: the single resolution point that makes custom themes usable
// everywhere a built-in is. Kept OUTSIDE the PURE region (it touches the
// UserDefaults-backed store); `FloteThemeRegistry` itself stays pure data.
extension FloteThemeRegistry {
    /// Built-in OR custom spec for `id` — the lookup the app-wide theme
    /// selection routes through (`AppearanceSettings.appThemeSpec`).
    /// Built-ins win (the `custom.` namespace makes a collision impossible
    /// anyway); unknown ids stay nil so callers keep their existing
    /// fallback behavior.
    @MainActor
    static func resolvedSpec(for id: String) -> FloteThemeSpec? {
        spec(for: id) ?? FloteCustomThemeStore.shared.spec(for: id)
    }
}

// MARK: - i18n foundation (S6)

/// App-wide UI language. v1 ships JP/EN; the mechanism (not string tables)
/// is the deliverable — every new user-facing string goes through `L(_:_:)`
/// so a locale sweep later is mechanical, and the user can switch language
/// after onboarding (Settings > 一般) instead of being locked to the
/// first-run choice.
///
/// Persistence shares the onboarding key ("floteLanguage"): the onboarding
/// choice IS the initial app language, and a later Settings change updates
/// the same key. Absent key = guessed from the system language.
@MainActor
@Observable
final class FloteL10n {
    static let shared = FloteL10n()

    /// Same key OnboardingWindowController writes — one source of truth.
    nonisolated static let defaultsKey = "floteLanguage"

    /// "ja" or "en".
    private(set) var language: String = FloteL10n.loadLanguage()

    private init() {}

    func set(_ lang: String) {
        guard lang == "ja" || lang == "en", lang != language else { return }
        language = lang
        UserDefaults.standard.set(lang, forKey: Self.defaultsKey)
        // AppKit-side consumers (menus rebuild per click) need no push;
        // SwiftUI consumers re-render via Observation on `language`.
    }

    private nonisolated static func loadLanguage() -> String {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey),
           stored == "ja" || stored == "en" {
            return stored
        }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? "ja" : "en"
    }
}

/// The app-wide string picker. Reads the @Observable language, so SwiftUI
/// views calling this inside `body` re-render on a language switch.
@MainActor
func L(_ ja: String, _ en: String) -> String {
    FloteL10n.shared.language == "ja" ? ja : en
}

/// Nonisolated picker for non-UI contexts (LocalizedError conformances,
/// background formatting). Reads the persisted value directly — no
/// Observation, so callers do NOT re-render on switch; use only where a
/// stale read until the next call is harmless.
nonisolated func LN(_ ja: String, _ en: String) -> String {
    let stored = UserDefaults.standard.string(forKey: FloteL10n.defaultsKey)
    let lang = (stored == "ja" || stored == "en")
        ? stored!
        : ((Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? "ja" : "en")
    return lang == "ja" ? ja : en
}

// MARK: - Platform bridge (SwiftUI + AppKit)
// The ONLY place FloteColorValue data becomes a platform color. A Windows
// port swaps these extensions for its own toolkit bridge; nothing above
// this line needs to change.

extension FloteColorValue {
    /// SwiftUI color in explicit sRGB (matches how the legacy literals in
    /// `NoteColorTheme` were interpreted, so the port is visually lossless).
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    /// AppKit color in the same explicit sRGB space, for NSAttributedString
    /// attributes and layout-manager draws.
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}

/// Single resolution point for the note ink and accent (Evaluator #2).
/// Every site that used to hardcode the cream-paper ink (0.22/0.18/0.14)
/// or the amber accent resolves here, so non-cream themes (墨, 勿忘草, …)
/// keep their per-entry documented contrast ratios. Notes are paper —
/// always the light palette, mirroring `NoteView.themePalette`.
@MainActor
enum FloteInk {

    /// Active spec: the app-wide theme wins; per-note mode falls back to
    /// the note's own legacy hue (each of the 11 pastels carries a
    /// DIFFERENT ported ink — 菜の花 is warm brown, 勿忘草 is navy).
    static func spec(legacyTheme rawValue: String? = nil) -> FloteThemeSpec {
        AppearanceSettings.shared.appThemeSpec
            ?? FloteThemeRegistry.specForLegacy(rawValue ?? "yellow")
    }

    /// Text ink as an AppKit color; `alpha` for secondary/faded uses.
    static func text(legacyTheme rawValue: String? = nil, alpha: Double = 1.0) -> NSColor {
        spec(legacyTheme: rawValue).palette(dark: false).text.nsColor
            .withAlphaComponent(alpha)
    }

    /// Control accent (checkbox fill, calc answers) as an AppKit color.
    static func accent(legacyTheme rawValue: String? = nil) -> NSColor {
        spec(legacyTheme: rawValue).palette(dark: false).accent.nsColor
    }

    // S14 semantic inks (resolved — derivation documented on Palette).
    // Queued consumers: keyword-line + variable def/use live coloring in
    // RichTextEditor (Appendix C work items b/d). Exposed here so that
    // wiring is a one-line attribute change per site, same as accent().

    /// Mode-keyword line ink ("math" / "list" trigger line).
    static func keyword(legacyTheme rawValue: String? = nil) -> NSColor {
        spec(legacyTheme: rawValue).palette(dark: false).resolvedKeyword.nsColor
    }

    /// Variable DEFINITION name ink (`price: 300`).
    static func variableDef(legacyTheme rawValue: String? = nil) -> NSColor {
        spec(legacyTheme: rawValue).palette(dark: false).resolvedVariableDef.nsColor
    }

    /// Variable USE ink — dimmed vs the definition by design; the returned
    /// color may carry alpha < 1 (NSAttributedString composites at draw).
    static func variableUse(legacyTheme rawValue: String? = nil) -> NSColor {
        spec(legacyTheme: rawValue).palette(dark: false).resolvedVariableUse.nsColor
    }

    /// Calc ANSWER ink (S16). Derives to `accent` for every paper-family
    /// theme (byte-exact pre-S16 behavior); the editor family designs it
    /// as its own high-saturation slot. Consumer: RichTextEditor's answer
    /// painting (contract with font-controls, 2026-07-12 — swap
    /// `FloteInk.accent` → `FloteInk.calcAnswer` at the answer sites).
    static func calcAnswer(legacyTheme rawValue: String? = nil) -> NSColor {
        spec(legacyTheme: rawValue).palette(dark: false).resolvedCalcAnswer.nsColor
    }

    /// Whether the ACTIVE theme prefers a monospaced body (S16 editor
    /// family). Same resolution path as every ink above — app-wide theme
    /// wins, else the note's legacy hue (always paper ⇒ false). Consumer:
    /// RichTextEditor / FontPreference body-font resolution (contract
    /// with font-controls, 2026-07-12).
    static func prefersMonospace(legacyTheme rawValue: String? = nil) -> Bool {
        spec(legacyTheme: rawValue).prefersMonospace
    }
}

extension FloteThemeSpec {
    /// Palette for the current SwiftUI color scheme — the call NoteView
    /// makes every render:
    ///
    ///     let palette = spec.palette(for: colorScheme)
    ///     // palette.background.color / .toolbar.color / .text.color / .accent.color
    func palette(for scheme: ColorScheme) -> Palette {
        palette(dark: scheme == .dark)
    }
}
