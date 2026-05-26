import SwiftUI

enum StowState: String, Codable {
    case expanded
    case rolledUp
    case mini
}

struct StickyNote: Identifiable, Codable {
    let id: UUID
    var text: String
    var richTextData: Data?
    var position: CGPoint
    var size: CGSize
    var colorTheme: NoteColorTheme
    var createdAt: Date
    var modifiedAt: Date
    var zOrder: Int
    var stowState: StowState
    var expandedSize: CGSize?
    var expandedPosition: CGPoint?
    var shapeAnnotations: [ShapeAnnotation]
    /// Short AI-generated title shown on the rolled-up scroll.
    /// Populated by Organize; nil until first successful organize.
    var rolledTitle: String?
    /// どのGroupに所属するか。新モデルでは起動時migrationで必ずInboxを割り当てるため
    /// 実質non-nilだが、nil許容のまま残す(古いJSON対策)。
    var groupID: UUID?
    /// 画面にFloatingPanelを立ち上げるかどうか。
    /// false = note自体はGroupに存在するがPanelは非表示 (「しまう」状態)。
    /// true = Panel起動中 (AppDelegateが起動時に復元)。
    var isPanelOpen: Bool
    /// Groupに最後に入った/移動した日時。Groupsタブでの並び順に使う。
    var sortedAt: Date?

    init(
        id: UUID = UUID(),
        text: String = "",
        richTextData: Data? = nil,
        position: CGPoint = CGPoint(x: 200, y: 400),
        size: CGSize = GoldenRatio.medium,
        colorTheme: NoteColorTheme = .yellow,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        zOrder: Int = 0,
        stowState: StowState = .expanded,
        expandedSize: CGSize? = nil,
        expandedPosition: CGPoint? = nil,
        shapeAnnotations: [ShapeAnnotation] = [],
        rolledTitle: String? = nil,
        groupID: UUID? = nil,
        isPanelOpen: Bool = true,
        sortedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.richTextData = richTextData
        self.position = position
        self.size = size
        self.colorTheme = colorTheme
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.zOrder = zOrder
        self.stowState = stowState
        self.expandedSize = expandedSize
        self.expandedPosition = expandedPosition
        self.shapeAnnotations = shapeAnnotations
        self.rolledTitle = rolledTitle
        self.groupID = groupID
        self.isPanelOpen = isPanelOpen
        self.sortedAt = sortedAt
    }

    // CGPoint and CGSize do not conform to Codable, so we handle manually.
    enum CodingKeys: String, CodingKey {
        case id, text, richTextData, positionX, positionY, sizeWidth, sizeHeight
        case colorTheme, createdAt, modifiedAt, zOrder
        case stowState
        case expandedSizeWidth, expandedSizeHeight
        case expandedPositionX, expandedPositionY
        case shapeAnnotations
        case rolledTitle
        case groupID
        // New unified-model keys
        case isPanelOpen, sortedAt
        // Legacy keys — decoded for backward compatibility, not encoded
        case isArchived, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        richTextData = try c.decodeIfPresent(Data.self, forKey: .richTextData)
        let x = try c.decode(CGFloat.self, forKey: .positionX)
        let y = try c.decode(CGFloat.self, forKey: .positionY)
        position = CGPoint(x: x, y: y)
        let w = try c.decode(CGFloat.self, forKey: .sizeWidth)
        let h = try c.decode(CGFloat.self, forKey: .sizeHeight)
        size = CGSize(width: w, height: h)
        colorTheme = try c.decode(NoteColorTheme.self, forKey: .colorTheme)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        zOrder = try c.decode(Int.self, forKey: .zOrder)
        stowState = (try? c.decode(StowState.self, forKey: .stowState)) ?? .expanded
        let esw = try? c.decodeIfPresent(CGFloat.self, forKey: .expandedSizeWidth)
        let esh = try? c.decodeIfPresent(CGFloat.self, forKey: .expandedSizeHeight)
        if let w = esw ?? nil, let h = esh ?? nil {
            expandedSize = CGSize(width: w, height: h)
        } else {
            expandedSize = nil
        }
        let epx = try? c.decodeIfPresent(CGFloat.self, forKey: .expandedPositionX)
        let epy = try? c.decodeIfPresent(CGFloat.self, forKey: .expandedPositionY)
        if let x = epx ?? nil, let y = epy ?? nil {
            expandedPosition = CGPoint(x: x, y: y)
        } else {
            expandedPosition = nil
        }
        shapeAnnotations = (try? c.decodeIfPresent([ShapeAnnotation].self, forKey: .shapeAnnotations)) ?? []
        rolledTitle = try? c.decodeIfPresent(String.self, forKey: .rolledTitle)
        groupID = try? c.decodeIfPresent(UUID.self, forKey: .groupID)

        // New field: default true so old payloads without isPanelOpen resume as open.
        // Legacy migration: if the old isArchived flag was true, the note was
        // explicitly put away, so treat that as a closed panel.
        let legacyArchived = (try? c.decodeIfPresent(Bool.self, forKey: .isArchived)) ?? false
        let explicitPanelOpen = try? c.decodeIfPresent(Bool.self, forKey: .isPanelOpen)
        isPanelOpen = explicitPanelOpen ?? !legacyArchived

        // sortedAt falls back to legacy archivedAt if the new key is absent.
        let newSorted = try? c.decodeIfPresent(Date.self, forKey: .sortedAt)
        let legacySorted = try? c.decodeIfPresent(Date.self, forKey: .archivedAt)
        sortedAt = newSorted ?? legacySorted
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(richTextData, forKey: .richTextData)
        try c.encode(position.x, forKey: .positionX)
        try c.encode(position.y, forKey: .positionY)
        try c.encode(size.width, forKey: .sizeWidth)
        try c.encode(size.height, forKey: .sizeHeight)
        try c.encode(colorTheme, forKey: .colorTheme)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(zOrder, forKey: .zOrder)
        try c.encode(stowState, forKey: .stowState)
        try c.encodeIfPresent(expandedSize?.width, forKey: .expandedSizeWidth)
        try c.encodeIfPresent(expandedSize?.height, forKey: .expandedSizeHeight)
        try c.encodeIfPresent(expandedPosition?.x, forKey: .expandedPositionX)
        try c.encodeIfPresent(expandedPosition?.y, forKey: .expandedPositionY)
        try c.encode(shapeAnnotations, forKey: .shapeAnnotations)
        try c.encodeIfPresent(rolledTitle, forKey: .rolledTitle)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encode(isPanelOpen, forKey: .isPanelOpen)
        try c.encodeIfPresent(sortedAt, forKey: .sortedAt)
        // Legacy keys (isArchived, archivedAt) are intentionally NOT encoded.
        // They survive only via the backward-compat decode path.
    }
}

extension StickyNote {
    /// Title shown on the rolled-up scroll AND in the Groups list. Prefer the
    /// AI-generated `rolledTitle`; if the note was never Organized (or the
    /// title got wiped by an older bug), fall back to the first non-blank
    /// line of the body clipped to 12 glyphs so the scroll never looks blank.
    /// Returns nil only when the note is completely empty.
    var displayTitle: String? {
        if let t = rolledTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            return t
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
            // Skip lines that would look wrong as a scroll label: markdown
            // headers, bullets, and checkbox items (any state). A blanket
            // `trimmingCharacters` would leak "x" out of "[x] done" since
            // `trimmingCharacters` stops at the first non-match.
            // Also skip pure date/time headers ("4月17日 10:30-",
            // "2026/04/17", etc.) — they surface no task content, which is
            // exactly what the user reported as useless titles.
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  !trimmed.hasPrefix("-"),
                  !trimmed.hasPrefix("*"),
                  !trimmed.hasPrefix("[ ]"),
                  !trimmed.hasPrefix("[x]"),
                  !trimmed.hasPrefix("[X]"),
                  !trimmed.hasPrefix("[\u{2713}]"),
                  !StickyNote.looksLikeDateTimeOnly(trimmed) else { continue }
            // Strip leftover emphasis characters from the ends only (safe:
            // all targets are in this small set). Does not touch interior.
            let cleaned = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_` "))
            guard !cleaned.isEmpty else { continue }
            return cleaned.count > 12 ? String(cleaned.prefix(12)) : cleaned
        }
        return nil
    }

    /// Returns true if the string contains only date/time-like tokens:
    /// digits, Japanese date/time units (年月日時分秒曜), and separators.
    /// Used to skip lines like "4月17日 10:30-" when picking a fallback
    /// title from the note body — pure timestamps can't serve as a
    /// "glance and remember" title.
    static func looksLikeDateTimeOnly(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        guard !scalars.isEmpty else { return false }
        // Must contain at least one digit or 曜 to qualify as a date/time
        // header in the first place — otherwise it's just arbitrary text.
        let digits = CharacterSet.decimalDigits
        let hasDigit = scalars.contains { digits.contains($0) }
        let hasWeekday = s.contains("曜")
        guard hasDigit || hasWeekday else { return false }
        // Permitted characters in a pure date/time line.
        let allowed = digits
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "年月日時分秒曜/:-−－‐—–：〜~.,、()（）"))
        return scalars.allSatisfy { allowed.contains($0) }
    }
}

enum NoteColorTheme: String, Codable, CaseIterable {
    case yellow
    case pink
    case blue
    case green
    case purple
    case orange
    case coral
    case mint
    case lavender
    case peach
    case sky

    var backgroundColor: Color {
        switch self {
        case .yellow:   return Color(red: 1.000, green: 0.976, blue: 0.769)
        case .pink:     return Color(red: 1.000, green: 0.878, blue: 0.902)
        case .blue:     return Color(red: 0.831, green: 0.918, blue: 1.000)
        case .green:    return Color(red: 0.863, green: 0.976, blue: 0.863)
        case .purple:   return Color(red: 0.918, green: 0.831, blue: 0.976)
        case .orange:   return Color(red: 1.000, green: 0.922, blue: 0.780)
        case .coral:    return Color(red: 1.000, green: 0.867, blue: 0.835)
        case .mint:     return Color(red: 0.831, green: 0.976, blue: 0.945)
        case .lavender: return Color(red: 0.894, green: 0.867, blue: 1.000)
        case .peach:    return Color(red: 1.000, green: 0.906, blue: 0.867)
        case .sky:      return Color(red: 0.863, green: 0.945, blue: 1.000)
        }
    }

    var toolbarColor: Color {
        switch self {
        case .yellow:   return Color(red: 0.953, green: 0.925, blue: 0.698)
        case .pink:     return Color(red: 0.953, green: 0.820, blue: 0.847)
        case .blue:     return Color(red: 0.769, green: 0.867, blue: 0.953)
        case .green:    return Color(red: 0.800, green: 0.933, blue: 0.800)
        case .purple:   return Color(red: 0.867, green: 0.784, blue: 0.933)
        case .orange:   return Color(red: 0.953, green: 0.871, blue: 0.710)
        case .coral:    return Color(red: 0.953, green: 0.812, blue: 0.773)
        case .mint:     return Color(red: 0.773, green: 0.933, blue: 0.898)
        case .lavender: return Color(red: 0.843, green: 0.812, blue: 0.953)
        case .peach:    return Color(red: 0.953, green: 0.855, blue: 0.812)
        case .sky:      return Color(red: 0.808, green: 0.898, blue: 0.953)
        }
    }

    // N2: Per-theme text colours meeting WCAG AA 4.5:1 contrast against each
    // background.  Luminance (L) = 0.2126*R + 0.7152*G + 0.0722*B (linearised).
    // Contrast = (L_lighter + 0.05) / (L_darker + 0.05).
    //
    // All pastel backgrounds are light (L ~ 0.7–0.9), so a dark brown/charcoal
    // (#383028, L≈0.040) is the best universal choice — contrast 8:1+ against
    // every theme.  Per-theme tuning lets us shift slightly toward each hue for
    // a warmer pairing while still clearing 4.5:1.
    var textColor: Color {
        switch self {
        // yellow bg L≈0.928  → dark brown #38300A  L≈0.034  CR≈15.1
        case .yellow:   return Color(red: 0.220, green: 0.188, blue: 0.040)
        // pink   bg L≈0.841  → dark rose  #3D1820  L≈0.032  CR≈12.2
        case .pink:     return Color(red: 0.239, green: 0.094, blue: 0.125)
        // blue   bg L≈0.833  → dark navy  #102038  L≈0.028  CR≈12.5
        case .blue:     return Color(red: 0.063, green: 0.125, blue: 0.220)
        // green  bg L≈0.890  → dark forest #102810  L≈0.030  CR≈13.9
        case .green:    return Color(red: 0.063, green: 0.157, blue: 0.063)
        // purple bg L≈0.773  → deep indigo #200A38  L≈0.025  CR≈11.5
        case .purple:   return Color(red: 0.125, green: 0.039, blue: 0.220)
        // orange bg L≈0.878  → dark amber  #3C2800  L≈0.031  CR≈13.4
        case .orange:   return Color(red: 0.235, green: 0.157, blue: 0.000)
        // coral  bg L≈0.820  → dark brick  #3D1008  L≈0.028  CR≈12.3
        case .coral:    return Color(red: 0.239, green: 0.063, blue: 0.031)
        // mint   bg L≈0.880  → dark teal   #08312C  L≈0.029  CR≈13.8
        case .mint:     return Color(red: 0.031, green: 0.192, blue: 0.173)
        // lavender bg L≈0.780 → dark violet #1C0838  L≈0.023  CR≈11.7
        case .lavender: return Color(red: 0.110, green: 0.031, blue: 0.220)
        // peach  bg L≈0.837  → dark sienna #3D200A  L≈0.030  CR≈12.4
        case .peach:    return Color(red: 0.239, green: 0.125, blue: 0.039)
        // sky    bg L≈0.862  → dark cerulean #062030  L≈0.026  CR≈14.0
        case .sky:      return Color(red: 0.024, green: 0.125, blue: 0.188)
        }
    }
}
