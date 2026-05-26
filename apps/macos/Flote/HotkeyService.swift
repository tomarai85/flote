import AppKit
import KeyboardShortcuts

/// Registers all user-customizable global hotkeys. Keys live in UserDefaults
/// under names declared in `ShortcutNames.swift`, so the Settings > Shortcuts
/// `KeyboardShortcuts.Recorder` UI drives this without any extra plumbing.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()
    private var registered = false

    private init() {}

    func register() {
        guard !registered else { return }
        registered = true

        KeyboardShortcuts.onKeyUp(for: .newNote) { [weak self] in
            self?.handleNewNote()
        }

        KeyboardShortcuts.onKeyUp(for: .viewGroups) { [weak self] in
            self?.handleViewGroups()
        }

        KeyboardShortcuts.onKeyUp(for: .archiveNote) { [weak self] in
            self?.handleArchiveFocusedNote()
        }
    }

    /// No-op for API parity with the previous NSEvent-based implementation.
    /// KeyboardShortcuts handlers don't need explicit teardown — they die
    /// with the app. Kept so call sites don't break.
    func unregister() {}

    // MARK: - Handlers

    private func handleNewNote() {
        let note = NoteManager.shared.createNote()
        PanelManager.shared.createPanel(for: note)
    }

    private func handleViewGroups() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowController.shared.show(section: .groups)
    }

    /// Archive via the global binding: find whichever FloatingPanel is key and
    /// archive that note. If no Flote panel is focused, do nothing silently.
    private func handleArchiveFocusedNote() {
        guard let panel = NSApp.keyWindow as? FloatingPanel else { return }
        panel.archiveAndClose()
    }
}
