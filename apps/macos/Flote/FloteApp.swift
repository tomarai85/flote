import SwiftUI

@main
struct FloteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Flote", systemImage: "note.text") {
            MenuBarView()
        }
        .menuBarExtraStyle(.menu)
    }
}
