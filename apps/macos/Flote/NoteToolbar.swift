import SwiftUI
import AppKit

struct NoteToolbar: View {
    let noteID: UUID
    let colorTheme: NoteColorTheme
    @Binding var pendingCommand: RichTextCommand?
    let textState: RichTextState

    @State private var showHighlightPicker = false
    @State private var showTextColorPicker = false
    @State private var showShapePicker = false

    private let buttonSize: CGFloat = 24
    private let iconSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 6) {
            // Text formatting
            formatButton(label: "B", font: .system(size: 12, weight: .bold), isActive: textState.isBold) {
                pendingCommand = .toggleBold
            }
            formatButton(label: "I", font: .system(size: 12, weight: .regular).italic(), isActive: textState.isItalic) {
                pendingCommand = .toggleItalic
            }
            formatButton(label: "U", font: .system(size: 12, weight: .regular), isActive: textState.isUnderline) {
                pendingCommand = .toggleUnderline
            }
            formatButton(label: "S", font: .system(size: 12, weight: .regular), isActive: textState.isStrikethrough) {
                pendingCommand = .toggleStrikethrough
            }

            thinDivider

            // Highlight color (popover)
            Button { showHighlightPicker.toggle() } label: {
                Image(systemName: "highlighter")
                    .font(.system(size: iconSize))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHighlightPicker, arrowEdge: .bottom) {
                highlightPopover
            }

            // Text color (popover)
            Button { showTextColorPicker.toggle() } label: {
                Image(systemName: "textformat")
                    .font(.system(size: iconSize))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTextColorPicker, arrowEdge: .bottom) {
                textColorPopover
            }

            thinDivider

            // Shapes (popover)
            Button { showShapePicker.toggle() } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: iconSize))
                    .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showShapePicker, arrowEdge: .bottom) {
                shapePopover
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(colorTheme.toolbarColor.opacity(0.6))
    }

    // MARK: - Popovers

    private var highlightPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Highlight")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                highlightDot(.yellow, NSColor.systemYellow.withAlphaComponent(0.5))
                highlightDot(.orange, NSColor.systemOrange.withAlphaComponent(0.4))
                highlightDot(.green, NSColor.systemGreen.withAlphaComponent(0.35))
                highlightDot(.blue, NSColor.systemBlue.withAlphaComponent(0.3))
                highlightDot(.pink, NSColor.systemPink.withAlphaComponent(0.3))
            }
            Button("Remove") {
                pendingCommand = .removeHighlight
                showHighlightPicker = false
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        // N10: Esc key dismisses the popover.
        .onExitCommand { showHighlightPicker = false }
    }

    private var textColorPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Text Color")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                textColorDot(.primary, NSColor.labelColor)
                textColorDot(.red, NSColor.systemRed)
                textColorDot(.blue, NSColor.systemBlue)
                textColorDot(.green, NSColor.systemGreen)
                textColorDot(.purple, NSColor.systemPurple)
                textColorDot(.orange, NSColor.systemOrange)
            }
        }
        .padding(10)
        // N10: Esc key dismisses the popover.
        .onExitCommand { showTextColorPicker = false }
    }

    private var shapePopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shapes")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                shapeButton(.arrow, sfSymbol: "arrow.right")
                shapeButton(.rectangle, sfSymbol: "rectangle")
                shapeButton(.circle, sfSymbol: "circle")
            }
            HStack(spacing: 8) {
                shapeButton(.underline, sfSymbol: "underline")
                shapeButton(.doubleUnderline, sfSymbol: "line.horizontal.3")
                shapeButton(.wavyUnderline, sfSymbol: "scribble")
            }
        }
        .padding(10)
        // N10: Esc key dismisses the popover.
        .onExitCommand { showShapePicker = false }
    }

    // MARK: - Components

    private var thinDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func formatButton(label: String, font: Font, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .foregroundColor(Color(red: 0.15, green: 0.15, blue: 0.15))
                .frame(width: buttonSize, height: buttonSize)
                .background(isActive ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func highlightDot(_ color: Color, _ nsColor: NSColor) -> some View {
        Button {
            pendingCommand = .highlight(nsColor)
            showHighlightPicker = false
        } label: {
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func textColorDot(_ color: Color, _ nsColor: NSColor) -> some View {
        Button {
            pendingCommand = .textColor(nsColor)
            showTextColorPicker = false
        } label: {
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shapeButton(_ type: ShapeType, sfSymbol: String) -> some View {
        Button {
            let center = CGPoint(x: 120, y: 80)
            let shape = ShapeAnnotation.defaultShape(type: type, centeredAt: center)
            NoteManager.shared.addShape(noteID: noteID, shape: shape)
            showShapePicker = false
        } label: {
            Image(systemName: sfSymbol)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
