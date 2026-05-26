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

    /// Global fallback binding for "archive current note". Unbound by default —
    /// the primary path is FloatingPanel's native ⌘W via `performClose`.
    /// Users who want a different global key can set one here.
    static let archiveNote = Self("archiveNote")
}
