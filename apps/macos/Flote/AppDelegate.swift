import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the app from the Dock (belt-and-suspenders alongside LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        // Load persisted notes, history, groups, and learning examples.
        NoteManager.shared.load()
        NoteManager.shared.loadHistory()
        GroupManager.shared.load()  // creates Inbox on first launch
        LearningManager.shared.load()

        // Unified-model migration: every note must belong to a group. Any note
        // that survived from the old schema without a groupID gets placed in Inbox.
        if let inboxID = GroupManager.shared.inboxID {
            NoteManager.shared.migrateLegacyFields(inboxID: inboxID)
        }

        // Ensure notes always start expanded to avoid stale stow geometry.
        NoteManager.shared.resetStowStateOnLaunch()

        // Only notes whose panel was open at last save get a floating panel.
        // Everything else lives in Groups until the user opens it.
        let panelOpen = NoteManager.shared.panelOpenNotes
        if panelOpen.isEmpty {
            let note = NoteManager.shared.createNote()
            PanelManager.shared.createPanel(for: note)
        } else {
            for note in panelOpen {
                PanelManager.shared.createPanel(for: note)
            }
        }

        // Register global hotkey Option+Space to focus or create note.
        HotkeyService.shared.register()

        // When another app activates, resign key from all Flote panels so
        // the other app's windows can receive keyboard input normally.
        // Without this, a nonActivatingPanel that was clicked earlier holds
        // key status and steals keystrokes from the newly-active app.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let info = notification.userInfo,
                  let app = info[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            for window in NSApp.windows where window is FloatingPanel {
                window.resignKey()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyService.shared.unregister()
        // Remove the workspace observer so it does not fire after the app has
        // begun tearing down. Without this, a late applicationDidActivate
        // notification could attempt to access NSApp.windows on a partially
        // dealloc'd app delegate.
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        // Flush all three debounced savers synchronously so nothing gets lost
        // between files. Order matches the load order (groups first so notes
        // referencing group IDs are guaranteed to resolve on next launch).
        GroupManager.shared.flushSaveNow()
        LearningManager.shared.flushSaveNow()
        NoteManager.shared.cancelPendingSave()
        NoteManager.shared.save()
        NoteManager.shared.teardown()
        // Sprint 3 D8: ensure UserDefaults (URL, font, prompt presets, shortcuts)
        // are written to disk before the process exits.
        UserDefaults.standard.synchronize()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
