import AppKit
import SwiftUI

/// Draws a rolled-up sticky note as a scroll viewed at a slight angle from the right.
/// Only the right end cap (cross-section) is visible.
struct PaperCurlView: View {

    let paperColor: Color
    let toolbarColor: Color
    var rollThickness: CGFloat = 0.5
    /// Short AI-generated title overlay. Rendered centered on the cylinder.
    var title: String? = nil

    var body: some View {
        ZStack {
            scrollCanvas
            if let title = title, !title.isEmpty {
                titleOverlay(title)
            }
        }
    }

    private func titleOverlay(_ title: String) -> some View {
        // Readable text color from toolbar color darkened.
        let tbNS = NSColor(toolbarColor).usingColorSpace(.sRGB) ?? NSColor(toolbarColor)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        tbNS.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let textColor = Color(red: max(0, tr * 0.25),
                              green: max(0, tg * 0.25),
                              blue: max(0, tb * 0.25))

        // Place the title ONLY on the cylindrical body (not centered over the
        // full frame). The top 7pt is a flat paper strip which should stay
        // clean; the cylinder occupies y=7…26 (19pt tall).
        // flatH (7) + padding visually anchors the text to the roll center.
        let flatStripHeight: CGFloat = 7
        return GeometryReader { geo in
            let avail = max(40, geo.size.width - 28)
            VStack(spacing: 0) {
                // Spacer matching the flat strip so text lives on the cylinder.
                Color.clear.frame(height: flatStripHeight)
                HStack {
                    Spacer(minLength: 0)
                    Text(title)
                        .font(titleFont(for: title, availableWidth: avail))
                        .foregroundColor(textColor.opacity(0.88))
                        .lineLimit(1)
                        // Allow only a gentle shrink — previous 0.6 produced
                        // ~7pt text on long titles which was unreadable.
                        // Anything that still won't fit gets truncated instead.
                        .minimumScaleFactor(0.9)
                        .truncationMode(.tail)
                        .frame(maxWidth: avail)
                    Spacer(minLength: 0)
                }
                .frame(height: geo.size.height - flatStripHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .allowsHitTesting(false)
    }

    /// Pick a readable size for the title. Floor loosened to 9pt per user
    /// request — the scroll area is narrow, and 9pt at viewing distance on
    /// the rolled cylinder still reads fine. Ceiling stays at 13pt so tall
    /// glyphs don't bump the cylinder edge. Longer titles get proportionally
    /// smaller sizes down to 9pt; shorter titles get up to 13pt.
    private func titleFont(for title: String, availableWidth: CGFloat) -> Font {
        let pref = FontPreference.shared.current
        // Rough CJK glyph width: ~1.0x of point size. Latin is ~0.55x but we
        // err on the side of the wider metric so mixed titles don't overflow.
        let charCount = CGFloat(max(1, title.count))
        let maxSizeByWidth = availableWidth / charCount
        let size = min(13, max(9, maxSizeByWidth))
        if pref == .sfPro {
            return .system(size: size, weight: .semibold, design: .rounded)
        }
        return Font(pref.nsFont(size: size, weight: .semibold) as CTFont)
    }

    private var scrollCanvas: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            // Resolve colors
            let bgNS = NSColor(paperColor).usingColorSpace(.sRGB) ?? NSColor(paperColor)
            let tbNS = NSColor(toolbarColor).usingColorSpace(.sRGB) ?? NSColor(toolbarColor)
            var bgR: CGFloat = 0, bgG: CGFloat = 0, bgB: CGFloat = 0, bgA: CGFloat = 0
            var tbR: CGFloat = 0, tbG: CGFloat = 0, tbB: CGFloat = 0, tbA: CGFloat = 0
            bgNS.getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)
            tbNS.getRed(&tbR, green: &tbG, blue: &tbB, alpha: &tbA)

            func darken(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, by d: CGFloat) -> Color {
                Color(red: max(0, min(1, r * (1 - d))),
                      green: max(0, min(1, g * (1 - d))),
                      blue: max(0, min(1, b * (1 - d))))
            }
            func mixC(_ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
                (bgR + (tbR - bgR) * t, bgG + (tbG - bgG) * t, bgB + (tbB - bgB) * t)
            }

            // ── Layout ──
            let cornerR: CGFloat = 5
            let flatH: CGFloat = 7
            let rollH: CGFloat = h - flatH
            let nearCapW: CGFloat = 8 + rollThickness * 4
            let rollTop = flatH

            let nearCapRect = CGRect(x: w - nearCapW, y: rollTop, width: nearCapW, height: rollH)
            let nearTopY = rollTop
            let nearBotY = rollTop + rollH

            // ── Layer 1: Cylinder body ──
            var bodyPath = Path()
            let leftR: CGFloat = rollH / 2
            bodyPath.move(to: CGPoint(x: leftR, y: rollTop))
            bodyPath.addLine(to: CGPoint(x: w - nearCapW / 2, y: nearTopY))
            bodyPath.addCurve(
                to: CGPoint(x: w - nearCapW / 2, y: nearBotY),
                control1: CGPoint(x: w, y: nearTopY),
                control2: CGPoint(x: w, y: nearBotY)
            )
            bodyPath.addLine(to: CGPoint(x: leftR, y: rollTop + rollH))
            bodyPath.addCurve(
                to: CGPoint(x: leftR, y: rollTop),
                control1: CGPoint(x: 0, y: rollTop + rollH),
                control2: CGPoint(x: 0, y: rollTop)
            )
            bodyPath.closeSubpath()

            // Matte paper shading: Lambertian (diffuse) — light from above,
            // monotonic darkening downward. NO specular hotspot, NO
            // "brighter than base" stops. This is what distinguishes paper
            // (absorbs/scatters light) from metal/plastic (reflects back).
            let bodyGradient = Gradient(stops: [
                // Lit top (matches paper strip, no brightening)
                .init(color: darken(tbR, tbG, tbB, by: 0.0),  location: 0.0),
                .init(color: darken(tbR, tbG, tbB, by: 0.05), location: 0.22),
                .init(color: darken(tbR, tbG, tbB, by: 0.10), location: 0.50),
                .init(color: darken(tbR, tbG, tbB, by: 0.16), location: 0.75),
                // Shadow bottom (contact shadow)
                .init(color: darken(tbR, tbG, tbB, by: 0.22), location: 1.0),
            ])
            context.fill(bodyPath, with: .linearGradient(
                bodyGradient,
                startPoint: CGPoint(x: w / 2, y: rollTop),
                endPoint: CGPoint(x: w / 2, y: rollTop + rollH)
            ))

            // ── Layer 2: Flat paper strip ──
            // Paper edges align vertically with cylinder edges to avoid
            // jagged transitions. Top has rounded corners.
            let (m3r, m3g, m3b) = mixC(0.3)
            let paperLeft: CGFloat = leftR      // flush with cylinder left
            let paperRight: CGFloat = w - nearCapW / 2
            var paperPath = Path()
            paperPath.move(to: CGPoint(x: paperLeft + cornerR, y: 0))
            paperPath.addLine(to: CGPoint(x: paperRight - cornerR, y: 0))
            paperPath.addQuadCurve(to: CGPoint(x: paperRight, y: cornerR),
                                   control: CGPoint(x: paperRight, y: 0))
            paperPath.addLine(to: CGPoint(x: paperRight, y: rollTop))
            paperPath.addLine(to: CGPoint(x: paperLeft, y: rollTop))
            paperPath.addLine(to: CGPoint(x: paperLeft, y: cornerR))
            paperPath.addQuadCurve(to: CGPoint(x: paperLeft + cornerR, y: 0),
                                   control: CGPoint(x: paperLeft, y: 0))
            paperPath.closeSubpath()

            let paperGradient = Gradient(stops: [
                .init(color: paperColor, location: 0.0),
                .init(color: paperColor, location: 0.35),
                .init(color: darken(m3r, m3g, m3b, by: 0.0), location: 0.70),
                // Bottom matches cylinder top for seamless transition
                .init(color: darken(tbR, tbG, tbB, by: 0.05), location: 1.0),
            ])
            context.fill(paperPath, with: .linearGradient(
                paperGradient,
                startPoint: CGPoint(x: w / 2, y: 0),
                endPoint: CGPoint(x: w / 2, y: rollTop)
            ))

            // ── Layer 3: Near end cap (rolled paper cross-section) ──
            // Softer shadows — paper cross-section scatters light, not a deep hole.
            var nearCap = Path()
            nearCap.addEllipse(in: nearCapRect)
            let nearCapGrad = Gradient(stops: [
                .init(color: darken(tbR, tbG, tbB, by: 0.12), location: 0.0),
                .init(color: darken(tbR, tbG, tbB, by: 0.20), location: 0.35),
                .init(color: darken(tbR, tbG, tbB, by: 0.28), location: 0.70),
                .init(color: darken(tbR, tbG, tbB, by: 0.34), location: 1.0),
            ])
            context.fill(nearCap, with: .linearGradient(
                nearCapGrad,
                startPoint: CGPoint(x: w - nearCapW / 2, y: nearTopY),
                endPoint: CGPoint(x: w - nearCapW / 2, y: nearBotY)
            ))

            let capCenter = CGPoint(x: w - nearCapW / 2, y: rollTop + rollH / 2)

            // Bright spiral (the visible edges of the rolled paper layers).
            // Light color against the dark background = clear paper layers.
            var spiral = Path()
            let turns: CGFloat = 1.1
            let steps = 56
            let maxRX = nearCapW / 2 - 1.2
            let maxRY = rollH / 2 - 1.2
            for i in 0...steps {
                let progress = CGFloat(i) / CGFloat(steps)
                let angle = progress * turns * 2.0 * .pi
                let rx = maxRX * (1.0 - progress * 0.85)
                let ry = maxRY * (1.0 - progress * 0.85)
                let x = capCenter.x + rx * cos(angle)
                let y = capCenter.y + ry * sin(angle)
                if i == 0 {
                    spiral.move(to: CGPoint(x: x, y: y))
                } else {
                    spiral.addLine(to: CGPoint(x: x, y: y))
                }
            }
            // Matte paper: spiral is soft shadow lines (layer edges), NOT bright
            // etched metal. Thin darker strokes against the lighter cap.
            context.stroke(
                spiral,
                with: .color(darken(tbR, tbG, tbB, by: 0.18)),
                lineWidth: 0.6
            )

            // Soft hollow center (paper core, not an ink dot)
            var core = Path()
            core.addEllipse(in: CGRect(
                x: capCenter.x - 1.0,
                y: capCenter.y - 1.0,
                width: 2.0, height: 2.0
            ))
            context.fill(core, with: .color(darken(tbR, tbG, tbB, by: 0.42)))

            // ── Layer 4: Warm ambient tint (replaces specular highlight) ──
            // Paper reflects warm light through fibers. Use paper color, not white.
            // Opacity kept under 5% so it reads as diffuse ambient, not sheen.
            let hlTop = rollTop + rollH * 0.08
            let hlBot = rollTop + rollH * 0.55
            var hlBand = Path()
            hlBand.addRect(CGRect(
                x: leftR + 2,
                y: hlTop,
                width: w - nearCapW / 2 - (leftR + 2),
                height: hlBot - hlTop
            ))
            let warmTint = Color(red: 1.0, green: 0.96, blue: 0.88)
            context.fill(hlBand, with: .linearGradient(
                Gradient(stops: [
                    .init(color: warmTint.opacity(0.05), location: 0.0),
                    .init(color: warmTint.opacity(0.03), location: 0.55),
                    .init(color: warmTint.opacity(0.0),  location: 1.0),
                ]),
                startPoint: CGPoint(x: 0, y: hlTop),
                endPoint: CGPoint(x: 0, y: hlBot)
            ))

            // ── Layer 5: Paper fiber stripes (subtle texture) ──
            // 5 faint near-horizontal lines simulating paper grain.
            for i in 0..<5 {
                let seed = CGFloat(i) * 7.3
                let offsetY = rollTop + rollH * (CGFloat(i) / 5.0 + 0.1 + 0.04 * sin(seed))
                var fiber = Path()
                fiber.move(to: CGPoint(x: leftR + 1, y: offsetY))
                fiber.addLine(to: CGPoint(
                    x: w - nearCapW / 2 - 1,
                    y: offsetY + sin(seed * 1.3) * 0.5
                ))
                context.stroke(fiber,
                               with: .color(.white.opacity(0.04)),
                               lineWidth: 0.4)
            }

            // ── Layer 6: Junction edges (subtle, matte-appropriate) ──
            // Top: very faint fiber catch-light (much reduced from metallic level)
            var topEdge = Path()
            topEdge.move(to: CGPoint(x: leftR + 1, y: rollTop - 0.5))
            topEdge.addLine(to: CGPoint(x: w - nearCapW / 2 - 1, y: nearTopY - 0.5))
            context.stroke(topEdge, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
            // Under: warm-tinted shadow (paper shadow is not pure black)
            var shadowEdge = Path()
            shadowEdge.move(to: CGPoint(x: leftR + 1, y: rollTop + 1.0))
            shadowEdge.addLine(to: CGPoint(x: w - nearCapW / 2 - 1, y: nearTopY + 1.0))
            context.stroke(
                shadowEdge,
                with: .color(darken(tbR, tbG, tbB, by: 0.35).opacity(0.5)),
                lineWidth: 0.6
            )
        }
        // Fill the panel height (26px) so the entire rolled-up area is tappable.
        // M5-1: provide an explicit minHeight so drawingGroup() can size the
        // Metal texture before SwiftUI resolves the layout, preventing a
        // transient 0×0 texture on the first render pass.
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: .infinity)
        // Composite the 6-layer canvas into a single Metal texture so SwiftUI
        // doesn't re-rasterize every gradient individually on each frame.
        // This is safe because the canvas is purely decorative (no interactivity).
        .drawingGroup()
    }
}
