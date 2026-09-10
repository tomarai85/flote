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

        KeyboardShortcuts.onKeyUp(for: .searchNotes) {
            SearchPaletteController.shared.toggle()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleAllNotes) {
            PanelManager.shared.toggleAllNotesVisibility()
        }
    }

    // MARK: - S7-4 呼び出し完成: Dock mode + hot corner

    /// Dock icon toggle (accessory <-> regular). Persisted; applied at
    /// launch by AppDelegate and live on Settings change. Default OFF —
    /// Flote's identity is the ambient menu-bar accessory.
    nonisolated static let dockModeKey = "floteDockMode"

    nonisolated static var dockModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: dockModeKey)
    }

    static func applyDockMode() {
        NSApp.setActivationPolicy(dockModeEnabled ? .regular : .accessory)
    }

    /// Hot corner (default OFF): park the pointer in the chosen screen
    /// corner for a beat -> new note. Poll-based (4 Hz, only while
    /// enabled) — no global event monitor, no accessibility permission.
    nonisolated static let hotCornerKey = "floteHotCorner"   // "", "tl", "tr", "bl", "br"

    nonisolated static var hotCorner: String {
        UserDefaults.standard.string(forKey: hotCornerKey) ?? ""
    }

    private var hotCornerTimer: Timer?
    private var cornerArmed = true   // re-arms after leaving the corner

    func applyHotCorner() {
        hotCornerTimer?.invalidate()
        hotCornerTimer = nil
        guard !Self.hotCorner.isEmpty else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in HotkeyService.shared.pollHotCorner() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hotCornerTimer = timer
    }

    private func pollHotCorner() {
        let corner = Self.hotCorner
        guard !corner.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        else { return }
        let f = screen.frame
        let margin: CGFloat = 4
        let inCorner: Bool
        switch corner {
        case "tl": inCorner = mouse.x <= f.minX + margin && mouse.y >= f.maxY - margin
        case "tr": inCorner = mouse.x >= f.maxX - margin && mouse.y >= f.maxY - margin
        case "bl": inCorner = mouse.x <= f.minX + margin && mouse.y <= f.minY + margin
        case "br": inCorner = mouse.x >= f.maxX - margin && mouse.y <= f.minY + margin
        default:   inCorner = false
        }
        if inCorner {
            // One fire per visit — re-arms only after the pointer leaves.
            // Never fire under a modal (the title-edit alert runs modal;
            // a note spawning behind it is disorienting — r3 minor).
            if cornerArmed, NSApp.modalWindow == nil {
                cornerArmed = false
                handleNewNote()
            }
        } else {
            cornerArmed = true
        }
    }

    /// No-op for API parity with the previous NSEvent-based implementation.
    /// KeyboardShortcuts handlers don't need explicit teardown — they die
    /// with the app. Kept so call sites don't break.
    func unregister() {}

    // MARK: - Handlers

    private func handleNewNote() {
        let note = NoteManager.shared.createNote()
        PanelManager.shared.createPanel(for: note, focus: true)
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
