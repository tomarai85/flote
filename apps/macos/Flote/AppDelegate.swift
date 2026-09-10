import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the app from the Dock (belt-and-suspenders alongside LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        // S6 reminders: without a delegate, a notification that fires while
        // the accessory app is frontmost is silently swallowed. Presenting
        // in-app too keeps the reminder visible in every state. Setting the
        // delegate does NOT prompt — permission is requested on first use.
        UNUserNotificationCenter.current().delegate = self

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

        // F2 empty-note hygiene: retire day-old ghost stickies (strictly
        // empty, panel closed, no group/title intent) before panels restore.
        // Runs after migration so intent-bearing notes already carry their
        // groupID exemption. Skipped when the keychain blocked the load —
        // an empty in-memory array must never trigger file cleanup.
        if !NoteManager.shared.loadBlockedByKeychain {
            NoteManager.shared.purgeStaleEmptyNotesAtLaunch()
        }

        // Ensure notes always start expanded to avoid stale stow geometry.
        NoteManager.shared.resetStowStateOnLaunch()

        // Only notes whose panel was open at last save get a floating panel.
        // Everything else lives in Groups until the user opens it.
        let panelOpen = NoteManager.shared.panelOpenNotes
        if NoteManager.shared.loadBlockedByKeychain {
            // Store intact but unreadable — creating a "first" note here
            // would sit on top of the user's real data (r3b NEW-3).
        } else if panelOpen.isEmpty {
            let note = NoteManager.shared.createNote()
            PanelManager.shared.createPanel(for: note)
        } else {
            for note in panelOpen {
                PanelManager.shared.createPanel(for: note)
            }
        }

        // Register global hotkey Option+Space to focus or create note.
        HotkeyService.shared.register()
        // S7-4: Dock icon + hot-corner per saved prefs (both default OFF).
        HotkeyService.applyDockMode()
        HotkeyService.shared.applyHotCorner()

        // S7C currency conversion: warm the FX/crypto rates cache. Async,
        // never blocks launch; no-op while the cached rates.json is < 24h
        // old. The calculator also triggers this lazily on a currency line.
        RatesService.shared.refreshIfNeeded()

        // S5: one-time first-run onboarding (language / how-to / AI setup /
        // style). No-op on every launch after completion — zero interruption.
        OnboardingWindowController.shared.showIfNeeded()

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

        // S16 font bridge — launch re-assert (contract with font-controls,
        // 2026-07-12). AppearanceSettings restores the persisted theme
        // SILENTLY (by design: no notification storm at init), so the one
        // fact FontPreference needs — "does the active theme prefer a
        // monospaced body?" — is re-posted once here, after panels (and
        // therefore FontPreference's observer) exist. Touching .shared
        // first guarantees the observer is registered even on a
        // zero-panel launch. The dedicated key matches no existing
        // observer filter, so nothing else re-runs.
        _ = FontPreference.shared
        NotificationCenter.default.post(
            name: .floteAppearanceChanged,
            object: AppearanceSettings.shared,
            userInfo: ["key": "fontBridgeLaunch",
                       "prefersMonospace":
                        AppearanceSettings.shared.appThemeSpec?.prefersMonospace ?? false])
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

extension AppDelegate {
    /// Show reminder banners even when a Flote panel is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
