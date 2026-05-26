import SwiftUI

struct MiniNoteView: View {
    let noteID: UUID

    private var note: StickyNote? {
        NoteManager.shared.note(byID: noteID)
    }

    private var accentColor: Color {
        note?.colorTheme.toolbarColor ?? Color(red: 0.957, green: 0.929, blue: 0.698)
    }

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

            if firstCharacter.isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary.opacity(0.5))
            } else {
                Text(firstCharacter)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary.opacity(0.7))
            }
        }
        .frame(width: 36, height: 36)
        .onTapGesture {
            PanelManager.shared.toggleMini(noteID: noteID)
        }
    }
}
