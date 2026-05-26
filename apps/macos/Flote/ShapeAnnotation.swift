import SwiftUI
import AppKit

// MARK: - ShapeType

enum ShapeType: String, Codable, CaseIterable {
    case arrow
    case rectangle
    case circle
    case underline
    case doubleUnderline
    case wavyUnderline
}

// MARK: - CodableColor

struct CodableColor: Codable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ nsColor: NSColor) {
        // Try device RGB first, then sRGB, then fall back to opaque red so
        // the initialiser never force-unwraps. NSColor.red in sRGB is a
        // known-good value that should never fail conversion, but using a
        // literal avoids even that theoretical path.
        if let resolved = nsColor.usingColorSpace(.deviceRGB)
            ?? nsColor.usingColorSpace(.sRGB) {
            red = resolved.redComponent
            green = resolved.greenComponent
            blue = resolved.blueComponent
            alpha = resolved.alphaComponent
        } else {
            // Last-resort fallback: opaque red as a visible error indicator.
            red = 1; green = 0; blue = 0; alpha = 1
        }
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

// MARK: - ShapeAnnotation

struct ShapeAnnotation: Identifiable, Codable {
    let id: UUID
    var type: ShapeType
    /// Position and size relative to the note view's coordinate space.
    var frame: CGRect
    var color: CodableColor
    var lineWidth: CGFloat

    init(
        id: UUID = UUID(),
        type: ShapeType,
        frame: CGRect,
        color: CodableColor = CodableColor(NSColor.systemRed),
        lineWidth: CGFloat = 2
    ) {
        self.id = id
        self.type = type
        self.frame = frame
        self.color = color
        self.lineWidth = lineWidth
    }

    // CGRect is not Codable by default, so encode components manually.
    enum CodingKeys: String, CodingKey {
        case id, type, color, lineWidth
        case frameX, frameY, frameWidth, frameHeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(ShapeType.self, forKey: .type)
        color = try c.decode(CodableColor.self, forKey: .color)
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
        let x = try c.decode(CGFloat.self, forKey: .frameX)
        let y = try c.decode(CGFloat.self, forKey: .frameY)
        let w = try c.decode(CGFloat.self, forKey: .frameWidth)
        let h = try c.decode(CGFloat.self, forKey: .frameHeight)
        frame = CGRect(x: x, y: y, width: w, height: h)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(color, forKey: .color)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(frame.origin.x, forKey: .frameX)
        try c.encode(frame.origin.y, forKey: .frameY)
        try c.encode(frame.size.width, forKey: .frameWidth)
        try c.encode(frame.size.height, forKey: .frameHeight)
    }
}

// MARK: - Default frame helper

extension ShapeAnnotation {
    /// Creates a shape centered at the given point with sensible default dimensions.
    static func defaultShape(type: ShapeType, centeredAt center: CGPoint) -> ShapeAnnotation {
        let size: CGSize
        switch type {
        case .underline, .doubleUnderline, .wavyUnderline:
            size = CGSize(width: 80, height: 2)
        default:
            size = CGSize(width: 60, height: 30)
        }
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        return ShapeAnnotation(type: type, frame: CGRect(origin: origin, size: size))
    }
}
