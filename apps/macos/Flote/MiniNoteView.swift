import SwiftUI

struct MiniNoteView: View {
    let noteID: UUID

    private var note: StickyNote? {
        NoteManager.shared.note(byID: noteID)
    }

    /// Mini dot follows the same resolution as NoteView.themePalette
    /// (app-wide theme wins, else the note's legacy hue; light-pinned) —
    /// it previously bypassed theming entirely (Evaluator #2).
    private var palette: FloteThemeSpec.Palette {
        FloteInk.spec(legacyTheme: note?.colorTheme.rawValue).palette(dark: false)
    }

    private var accentColor: Color { palette.toolbar.color }

    private var inkColor: Color { palette.text.color }

    private var firstCharacter: String {
        guard let text = note?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = text.first else { return "" }
        return String(first)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(accentColor)
                .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)

            if note?.isLocked == true {
                // Locked notes leak nothing, not even one character.
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(inkColor.opacity(0.5))
            } else if firstCharacter.isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(inkColor.opacity(0.5))
            } else {
                Text(firstCharacter)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(inkColor.opacity(0.7))
            }
        }
        .frame(width: 36, height: 36)
        .onTapGesture {
            PanelManager.shared.toggleMini(noteID: noteID)
        }
    }
}
