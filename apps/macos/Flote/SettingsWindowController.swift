import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    func show(section: SettingsSection = .general) {
        SettingsState.shared.selectedSection = section
        if let window = window {
            // M-1: if the user minimized Settings to the Dock, makeKeyAndOrderFront
            // alone leaves the window iconified — restore it before bringing forward.
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Fixed window size. Disable resize and full-screen so the layout
        // stays predictable regardless of SwiftUI intrinsic sizing quirks.
        // Wider than before to fit the Groups 2-pane layout (tree + cards).
        let fixedSize = NSSize(width: 960, height: 600)

        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = []
        hosting.preferredContentSize = fixedSize

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: fixedSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.contentViewController = hosting
        win.title = "Flote"
        win.setContentSize(fixedSize)
        win.contentMinSize = fixedSize
        win.contentMaxSize = fixedSize
        win.collectionBehavior.insert(.fullScreenNone)
        // Hold the window ourselves so close just hides; we explicitly tear
        // down the hosting view in the close observer below to cut the
        // @Observable -> NSHostingView -> AutoLayout cycle that caused the
        // runtime SIGABRT when the closed window kept receiving layout
        // notifications from NoteManager/GroupManager.
        win.isReleasedWhenClosed = false
        // Pin the settings window to a light appearance so the warm paper
        // tones stay consistent whether the user runs macOS in dark mode or not.
        win.appearance = NSAppearance(named: .aqua)
        win.center()
        self.window = win

        // When the user closes the window, detach the hosting view so any
        // pending Observable-driven layout pass has nothing to invalidate.
        // The next show() rebuilds everything fresh.
        if let existing = closeObserver {
            NotificationCenter.default.removeObserver(existing)
            closeObserver = nil
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.window?.contentViewController = nil
            self.window = nil
            if let obs = self.closeObserver {
                NotificationCenter.default.removeObserver(obs)
                self.closeObserver = nil
            }
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
