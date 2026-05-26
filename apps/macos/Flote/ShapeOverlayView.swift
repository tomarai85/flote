import SwiftUI

// MARK: - ShapeOverlayView

struct ShapeOverlayView: View {
    let noteID: UUID
    @Binding var shapes: [ShapeAnnotation]
    @State private var selectedID: UUID?
    // Store the shape frame at drag/resize start to avoid stale-capture bugs.
    // Keyed by shape ID to avoid cross-shape interference.
    @State private var dragStartFrames: [UUID: CGRect] = [:]
    @State private var resizeStartFrames: [UUID: CGRect] = [:]

    private let handleSize: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach($shapes) { $shape in
                    shapeView(shape: $shape, containerSize: geo.size)
                }
            }
        }
    }

    // MARK: - Per-shape view

    @ViewBuilder
    private func shapeView(shape: Binding<ShapeAnnotation>, containerSize: CGSize) -> some View {
        let s = shape.wrappedValue
        let isSelected = selectedID == s.id

        ZStack(alignment: .bottomTrailing) {
            // Shape canvas
            Canvas { ctx, size in
                drawShape(s, in: ctx, size: size)
            }
            .frame(width: max(s.frame.width, 4), height: max(s.frame.height, 4))

            // Resize handle (bottom-right corner), only when selected
            if isSelected {
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1))
                    .frame(width: handleSize, height: handleSize)
                    .offset(x: handleSize / 2, y: handleSize / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let sid = s.id
                                if resizeStartFrames[sid] == nil {
                                    resizeStartFrames[sid] = shape.wrappedValue.frame
                                }
                                guard let startFrame = resizeStartFrames[sid] else { return }
                                let newW = max(20, startFrame.width + value.translation.width)
                                let newH = max(10, startFrame.height + value.translation.height)
                                shape.wrappedValue.frame.size = CGSize(width: newW, height: newH)
                            }
                            .onEnded { _ in
                                resizeStartFrames.removeValue(forKey: s.id)
                                NoteManager.shared.updateShape(noteID: noteID, shape: shape.wrappedValue)
                            }
                    )
            }
        }
        // Outline when selected
        .overlay(
            isSelected
                ? RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1, antialiased: true)
                : nil
        )
        .position(
            x: s.frame.midX,
            y: s.frame.midY
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    let sid = s.id
                    if dragStartFrames[sid] == nil {
                        dragStartFrames[sid] = shape.wrappedValue.frame
                    }
                    guard let startFrame = dragStartFrames[sid] else { return }
                    shape.wrappedValue.frame.origin = CGPoint(
                        x: startFrame.origin.x + value.translation.width,
                        y: startFrame.origin.y + value.translation.height
                    )
                }
                .onEnded { _ in
                    dragStartFrames.removeValue(forKey: s.id)
                    NoteManager.shared.updateShape(noteID: noteID, shape: shape.wrappedValue)
                }
        )
        .onTapGesture {
            selectedID = selectedID == s.id ? nil : s.id
        }
        .contextMenu {
            Button("Delete Shape") {
                // N3: remove via model only. The @Binding is sourced from
                // NoteManager.shared (Observable), so the view re-renders
                // automatically — a local removeAll is redundant and can race.
                NoteManager.shared.removeShape(noteID: noteID, shapeID: s.id)
                if selectedID == s.id { selectedID = nil }
            }
        }
    }

    // MARK: - Canvas drawing

    private func drawShape(_ shape: ShapeAnnotation, in ctx: GraphicsContext, size: CGSize) {
        let ctx = ctx
        ctx.stroke(
            pathForShape(shape, size: size),
            with: .color(shape.color.color),
            style: StrokeStyle(lineWidth: shape.lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func pathForShape(_ shape: ShapeAnnotation, size: CGSize) -> Path {
        switch shape.type {
        case .arrow:
            return arrowPath(in: size)
        case .rectangle:
            return Path(CGRect(x: shape.lineWidth / 2, y: shape.lineWidth / 2,
                               width: size.width - shape.lineWidth,
                               height: size.height - shape.lineWidth))
        case .circle:
            return Path(ellipseIn: CGRect(x: shape.lineWidth / 2, y: shape.lineWidth / 2,
                                          width: size.width - shape.lineWidth,
                                          height: size.height - shape.lineWidth))
        case .underline:
            return underlinePath(in: size, count: 1)
        case .doubleUnderline:
            return underlinePath(in: size, count: 2)
        case .wavyUnderline:
            return wavyPath(in: size)
        }
    }

    private func arrowPath(in size: CGSize) -> Path {
        var path = Path()
        let headSize: CGFloat = min(size.height * 0.6, 12)
        let y = size.height / 2
        path.move(to: CGPoint(x: 2, y: y))
        path.addLine(to: CGPoint(x: size.width - headSize, y: y))
        // Arrowhead
        path.move(to: CGPoint(x: size.width - headSize, y: y - headSize / 2))
        path.addLine(to: CGPoint(x: size.width - 2, y: y))
        path.addLine(to: CGPoint(x: size.width - headSize, y: y + headSize / 2))
        return path
    }

    private func underlinePath(in size: CGSize, count: Int) -> Path {
        var path = Path()
        let spacing: CGFloat = 4
        let totalH = CGFloat(count - 1) * spacing
        let startY = (size.height - totalH) / 2
        for i in 0..<count {
            let y = startY + CGFloat(i) * spacing
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        return path
    }

    private func wavyPath(in size: CGSize) -> Path {
        var path = Path()
        let y = size.height / 2
        let amplitude: CGFloat = min(size.height * 0.4, 4)
        let wavelength: CGFloat = 10
        var x: CGFloat = 0
        path.move(to: CGPoint(x: 0, y: y))
        while x < size.width {
            let nextX = min(x + wavelength / 2, size.width)
            let midX = (x + nextX) / 2
            let direction: CGFloat = (Int(x / (wavelength / 2)) % 2 == 0) ? -1 : 1
            path.addQuadCurve(
                to: CGPoint(x: nextX, y: y),
                control: CGPoint(x: midX, y: y + direction * amplitude)
            )
            x = nextX
        }
        return path
    }
}
