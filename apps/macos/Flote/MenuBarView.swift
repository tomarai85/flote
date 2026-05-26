import SwiftUI

struct MenuBarView: View {
    var body: some View {
        Button("New Note") {
            let note = NoteManager.shared.createNote()
            PanelManager.shared.createPanel(for: note)
        }
        .keyboardShortcut(" ", modifiers: [.option])

        Divider()

        Button("Settings...") {
            SettingsWindowController.shared.show()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("View Groups...") {
            SettingsWindowController.shared.show(section: .groups)
        }

        Button("View History...") {
            SettingsWindowController.shared.show(section: .history)
        }

        Divider()

        Button("Restart Flote") {
            restartApp()
        }

        Button("Quit Flote") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func restartApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
