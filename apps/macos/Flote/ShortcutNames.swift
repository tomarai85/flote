import KeyboardShortcuts

/// Shortcut names consumed by the `KeyboardShortcuts` package.
/// Each name is persisted in UserDefaults under the hood, so once a user
/// rebinds a shortcut it survives relaunch.
extension KeyboardShortcuts.Name {
    /// Global: create a new note from any app. Default: ⌥Space.
    static let newNote = Self(
        "newNote",
        default: .init(.space, modifiers: [.option])
    )

    /// Global: open Settings and jump to the Groups tab. Default: ⌃⌥G.
    static let viewGroups = Self(
        "viewGroups",
        default: .init(.g, modifiers: [.control, .option])
    )

    /// Global: open the search palette. Default: ⌥⇧Space.
    static let searchNotes = Self(
        "searchNotes",
        default: .init(.space, modifiers: [.option, .shift])
    )

    /// Global: hide/show ALL open note panels at once ("get my screen back").
    /// Default: ⌥⇧A. Antinote ships ⌥A, but bare ⌥A swallows "å" and fights
    /// JP input sources — ⌥⇧ keeps the mnemonic without stealing a common
    /// key. Users can rebind. Visual dismissal only: model state
    /// (isPanelOpen) is untouched and the hidden set resets on relaunch.
    static let toggleAllNotes = Self(
        "toggleAllNotes",
        default: .init(.a, modifiers: [.option, .shift])
    )

    /// Global fallback binding for "archive current note". Unbound by default —
    /// the primary path is FloatingPanel's native ⌘W via `performClose`.
    /// Users who want a different global key can set one here.
    static let archiveNote = Self("archiveNote")
}
