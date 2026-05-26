import SwiftUI
import AppKit

/// User-selectable font for note body text and the rolled-up scroll title.
/// Choices are persisted in UserDefaults under "floteFontFamily".
enum AppFont: String, CaseIterable, Identifiable {
    case hiraginoSans          // default, clean Japanese sans
    case hiraginoMincho        // classic Japanese serif, literary feel
    case sfPro                 // Apple system sans (Japanese falls back to system)
    case newYork               // Apple serif, editorial
    case monaco                // monospace, code-like
    case menlo                 // monospace, slightly warmer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hiraginoSans:   return "ヒラギノ角ゴ (Sans)"
        case .hiraginoMincho: return "ヒラギノ明朝 (Serif)"
        case .sfPro:          return "SF Pro (System)"
        case .newYork:        return "New York (Serif)"
        case .monaco:          return "Monaco (Mono)"
        case .menlo:           return "Menlo (Mono)"
        }
    }

    /// Font name string for NSFont(name:size:) lookup. Falls back to system.
    var fontName: String {
        switch self {
        case .hiraginoSans:   return "HiraginoSans-W3"
        case .hiraginoMincho: return "HiraMinProN-W3"
        case .sfPro:          return ".AppleSystemUIFont"
        case .newYork:        return "NewYork"
        case .monaco:          return "Monaco"
        case .menlo:           return "Menlo"
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if self == .sfPro {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        return NSFont(name: fontName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }
}

/// Observable font preference. SwiftUI views re-render when the user changes
/// the setting in SettingsView.
@MainActor
@Observable
final class FontPreference {
    static let shared = FontPreference()
    private let defaultsKey = "floteFontFamily"

    var current: AppFont {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: defaultsKey)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let font = AppFont(rawValue: raw) {
            current = font
        } else {
            current = .hiraginoSans
        }
    }
}
