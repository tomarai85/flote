import SwiftUI

struct NoteView: View {
    let noteID: UUID

    @State private var isOrganizing = false
    @State private var organizeError: String?
    @State private var showErrorOverlay = false
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var reloadTrigger = 0
    @State private var isHoveringOrganize = false
    @State private var showCopiedToast = false
    @State private var isSorting = false
    @State private var editorState = RichTextState()
    @State private var organizeUndoData: (richData: Data?, plain: String, title: String?)?
    @State private var isEditingRolledTitle = false
    @State private var rolledTitleDraft = ""

    private var note: StickyNote? {
        NoteManager.shared.note(byID: noteID)
    }

    private var background: Color {
        note?.colorTheme.backgroundColor ?? Color(red: 1.0, green: 0.976, blue: 0.769)
    }

    private var toolbarColor: Color {
        note?.colorTheme.toolbarColor ?? Color(red: 0.953, green: 0.925, blue: 0.698)
    }

    private var stowState: StowState {
        note?.stowState ?? .expanded
    }

    var body: some View {
        Group {
            switch stowState {
            case .mini:
                MiniNoteView(noteID: noteID)
            case .rolledUp:
                rolledUpView
            case .expanded:
                expandedView
            }
        }
        // Use a constant corner radius so the clipShape value never changes
        // as a side effect of stowState transitions. Tying it to stowState
        // was the extra SwiftUI invalidation that raced with AppKit's layout
        // settle and caused _postWindowNeedsUpdateConstraints to re-enter.
        // Reproduced in crash Flote-2026-04-17-181410.ips.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDisappear {
            // Cancel the auto-dismiss timer when the view leaves the hierarchy
            // (panel closed or note switched) to prevent a delayed setState.
            errorDismissTask?.cancel()
        }
        // NOTE: Do NOT add SwiftUI .animation(value: stowState) here.
        // StowAnimator already runs an NSAnimationContext frame animation on
        // the window; a SwiftUI implicit animation on top of it causes
        // NSHostingView.updateAnimatedWindowSize to reenter the constraint
        // pass and throw (_postWindowNeedsUpdateConstraints). See crash
        // Flote-2026-04-17-132651.ips.
    }

    // MARK: - Rolled-up view (3D paper curl using CATransformLayer)

    /// Genuine 3D paper curl using Core Animation's CATransformLayer.
    /// Unlike SwiftUI's rotation3DEffect, this provides real perspective,
    /// visible back-face, and shadow casting via m34 perspective transform.
    private var rolledUpView: some View {
        let textLen = note?.text.count ?? 0
        let thickness = min(1.0, max(0.2, CGFloat(textLen) / 200.0))
        return ZStack {
            PaperCurlView(
                paperColor: background,
                toolbarColor: toolbarColor,
                rollThickness: thickness,
                title: isEditingRolledTitle ? nil : note?.displayTitle
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // Allow rolling/expanding even while Organize / AI Sort is
                // in flight. StowAnimator uses a snapshot window so the real
                // panel isn't resized during the 0.3s animation, and
                // fitPanelToContent's own animatingNoteIDs / stowState
                // guards suppress layout writes during stow. Completion
                // handlers of the background Task still write model updates
                // (updateRichText / updateRolledTitle), which take effect
                // when the panel is expanded next.
                guard !isEditingRolledTitle else { return }
                PanelManager.shared.toggleStow(noteID: noteID)
            }
            // Right-click (two-finger click on trackpad) is the entry point to
            // title editing. A double-tap path was tried but SwiftUI fires the
            // single-tap before it resolves the double-tap, so the first click
            // always toggled stow and raced against beginTitleEdit.
            .overlay(
                RightClickDetector {
                    guard !isEditingRolledTitle else { return }
                    beginTitleEdit()
                }
            )

            if isEditingRolledTitle {
                // Transparent backdrop commits (and exits) when the user taps
                // anywhere outside the text field. Without this, a
                // .nonactivatingPanel never loses first-responder to outside
                // clicks, trapping the user in edit mode.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { commitTitleEdit() }
                rolledTitleEditor
            }
        }
    }

    private func beginTitleEdit() {
        // Seed the draft with what the user currently sees on the scroll —
        // that's the rolledTitle when present, or the body-derived fallback.
        // Starting from displayTitle lets them tweak the auto-derived text
        // without retyping it.
        rolledTitleDraft = note?.displayTitle ?? ""
        isEditingRolledTitle = true
    }

    private func commitTitleEdit() {
        guard isEditingRolledTitle else { return }
        let trimmed = rolledTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        NoteManager.shared.updateRolledTitle(
            id: noteID,
            title: trimmed.isEmpty ? nil : trimmed
        )
        // Defer state reset so NSTextField's end-editing cycle completes
        // before SwiftUI removes the view.
        DispatchQueue.main.async { isEditingRolledTitle = false }
    }

    private var rolledTitleEditor: some View {
        let flatStripHeight: CGFloat = 7
        return VStack(spacing: 0) {
            Color.clear.frame(height: flatStripHeight)
            HStack {
                Spacer(minLength: 4)
                AutoFocusTextField(
                    text: $rolledTitleDraft,
                    onCommit: commitTitleEdit,
                    onFocusLost: commitTitleEdit,
                    onCancel: { isEditingRolledTitle = false }
                )
                .frame(height: 19)
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Expanded

    private var expandedView: some View {
        VStack(spacing: 0) {
            // Top bar: copy + organize + roll-up + close
            topBar

            // Text area (formatting is handled by AI Organize)
            ZStack(alignment: .bottom) {
                RichTextEditor(
                    noteID: noteID,
                    pendingCommand: .constant(nil),
                    textState: editorState,
                    reloadTrigger: reloadTrigger,
                    fontFamily: FontPreference.shared.current
                )

                if editorState.hasContentBelow {
                    LinearGradient(
                        colors: [background.opacity(0), background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 24)
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 6)

            // Error banner (only shown when there's an error). Allow up to 2
            // lines so the detailed cause message (C6) is visible without
            // truncating the action hint ("Settings > AI Organize" etc.).
            if showErrorOverlay, let errorMsg = organizeError {
                Text(errorMsg)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.red.opacity(0.8))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .background(background)
    }

    // MARK: - Top bar (minimal: roll-up + close)

    private var topBar: some View {
        VStack(spacing: 2) {
            // Row 1: 4 buttons evenly spaced across the panel width.
            // Spacers between each button distribute the remaining space
            // equally so the cluster doesn't feel crammed at the right.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button(action: copyNoteText) {
                    Image(systemName: showCopiedToast ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.22, green: 0.18, blue: 0.14).opacity(showCopiedToast ? 0.8 : 0.4))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showCopiedToast ? "Copied!" : "Copy text")

                Spacer(minLength: 0)

                // AI auto-sort: uses Claude to pick (or propose) the best
                // group for this note. Falls back to Inbox on error.
                Button(action: runAISort) {
                    Group {
                        if isSorting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.35)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundColor(Color(red: 0.22, green: 0.18, blue: 0.14).opacity(isSorting ? 0.7 : 0.45))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSorting || (note?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
                .help("AI sort: let Claude pick the best group")

                Spacer(minLength: 0)

                Button(action: hideToGroup) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.22, green: 0.18, blue: 0.14).opacity(0.4))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Archive — close panel, note stays in Groups")

                Spacer(minLength: 0)

                Button(action: {
                    // Roll-up is safe during Organize / AI Sort — see the
                    // rolledUpView onTapGesture comment for why. Guard
                    // removed so the user isn't blocked mid-Organize.
                    PanelManager.shared.toggleStow(noteID: noteID)
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.22, green: 0.18, blue: 0.14).opacity(0.4))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Roll up")

                Spacer(minLength: 0)
            }
            .frame(height: 22)
            .padding(.horizontal, 4)

            // Row 2: Organize button, right-aligned under the roll-up/close cluster
            HStack(spacing: 0) {
                Spacer()
                Button(action: organizeNote) {
                    HStack(spacing: 4) {
                        ZStack {
                            if isOrganizing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 10, weight: .medium))
                            }
                        }
                        .frame(width: 12, height: 12)
                        Text(isOrganizing ? "Organizing" : "Organize")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .frame(minWidth: 78, alignment: .center)
                    .foregroundColor(Color(red: 0.22, green: 0.18, blue: 0.14).opacity(isHoveringOrganize ? 0.9 : 0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(toolbarColor.opacity(isHoveringOrganize ? 0.9 : 0.55))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isOrganizing || (note?.text.isEmpty ?? true))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) { isHoveringOrganize = hovering }
                }
                .padding(.trailing, 6)
            }
        }
    }

    private func copyNoteText() {
        guard let note = note else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Include both rich and plain representations so either format works.
        // If richTextData exists but fails to unarchive (corrupted from a
        // partial save), we log and fall through to plain-text only.
        if let data = note.richTextData {
            if let attr = RichTextStorage.unarchive(data),
               let rtfData = try? attr.data(
                   from: NSRange(location: 0, length: attr.length),
                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
               ) {
                pasteboard.setData(rtfData, forType: .rtf)
            } else {
                print("[Flote] Rich text unarchive failed; using plain text only")
            }
        }
        pasteboard.setString(note.text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            showCopiedToast = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCopiedToast = false
                }
            }
        }
    }

    // MARK: - Bottom bar removed — Organize moved to top bar

    // MARK: - Actions

    /// Close the floating panel without removing the note. The note keeps its
    /// group membership; the user can bring it back from the Groups tab.
    /// Empty scratch notes (never Organized, no content) are simply dropped
    /// rather than polluting any group.
    private func hideToGroup() {
        // Block while Organize/AI sort is in flight. If we remove the note
        // now, the pending Task would try to update a ghost when it returns.
        guard !isOrganizing, !isSorting else { return }
        NoteManager.shared.archiveNote(id: noteID)
        PanelManager.shared.removePanel(for: noteID)
    }

    /// AI auto-sort: ask the model to pick (or create) the best group for
    /// this note given the existing group list. Falls back to Inbox on error.
    private func runAISort() {
        // Hard lock: never overlap with Organize (API contention + state race).
        guard !isSorting, !isOrganizing else { return }
        guard let note = note,
              !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        isSorting = true
        let groups = GroupManager.shared.groups
        Task {
            let result: OrganizeService.ClassifyResult
            do {
                result = try await OrganizeService.shared.classify(
                    text: note.text,
                    existingGroups: groups
                )
            } catch {
                print("[Flote] AI sort failed, falling back to Inbox: \(error)")
                await MainActor.run {
                    isSorting = false
                    parkInInbox()
                }
                return
            }
            await MainActor.run {
                isSorting = false
                applyClassifyResult(result)
            }
        }
    }

    /// Put this note in Inbox and close its panel (used as a fallback).
    private func parkInInbox() {
        GroupManager.shared.ensureInboxExists()
        guard let inboxID = GroupManager.shared.inboxID else { return }
        NoteManager.shared.moveNote(id: noteID, toGroup: inboxID)
        NoteManager.shared.closePanel(noteID: noteID)
        PanelManager.shared.removePanel(for: noteID)
    }

    private func applyClassifyResult(_ result: OrganizeService.ClassifyResult) {
        GroupManager.shared.ensureInboxExists()
        let targetID: UUID
        switch result {
        case .existing(let id):
            if GroupManager.shared.group(byID: id) != nil {
                targetID = id
            } else {
                targetID = GroupManager.shared.inboxID ?? id
            }
        case .newGroup(let name):
            let icon = GroupManager.iconForGroupName(name)
            let color = GroupManager.colorHexForGroupName(name)
            let group = GroupManager.shared.createGroup(name: name, icon: icon, colorHex: color)
            targetID = group.id
        case .inbox:
            targetID = GroupManager.shared.inboxID ?? UUID()
        }
        // AI sort = "put this away": move into the chosen group AND close the
        // panel. The note is always retrievable from the Groups tab.
        NoteManager.shared.moveNote(id: noteID, toGroup: targetID)
        NoteManager.shared.closePanel(noteID: noteID)
        PanelManager.shared.removePanel(for: noteID)
    }

    private func organizeNote() {
        guard !isOrganizing, !isSorting else { return }
        guard let note = note, !note.text.isEmpty else { return }
        // Snapshot pre-organize state for undo.
        let prevRichData = note.richTextData
        let prevPlain = note.text
        let prevTitle = note.rolledTitle
        isOrganizing = true
        organizeError = nil
        showErrorOverlay = false
        Task {
            do {
                let result = try await OrganizeService.shared.organize(text: note.text)
                let font = await MainActor.run {
                    FontPreference.shared.current.nsFont(size: 11, weight: .regular)
                }
                let paraStyle = NSMutableParagraphStyle()
                paraStyle.lineSpacing = 2.5
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor(red: 0.22, green: 0.18, blue: 0.14, alpha: 1.0),
                    .paragraphStyle: paraStyle
                ]
                let attrStr = NSAttributedString(string: result, attributes: attrs)
                let data = RichTextStorage.archive(attrStr)

                await MainActor.run {
                    guard NoteManager.shared.note(byID: noteID) != nil else {
                        // M1-1: log cancellation so Organize race conditions are
                        // visible in the console without crashing.
                        print("[Flote] Organize cancelled: note \(noteID) removed")
                        return
                    }

                    // Prefer the explicit `## タイトル` section. If the model
                    // omitted it (happens with short notes or non-compliant
                    // output), fall back to the first non-empty, non-header
                    // line so the scroll never ends up blank. Only overwrite
                    // the stored title when we actually have something — a nil
                    // extraction must not wipe a previously-set rolled title.
                    if let title = Self.extractTitle(from: result)
                        ?? Self.firstContentLine(of: result) {
                        NoteManager.shared.updateRolledTitle(id: noteID, title: title)
                    }
                    NoteManager.shared.updateRichText(id: noteID, data: data, plainText: result)

                    if NoteManager.shared.note(byID: noteID)?.groupID == nil {
                        GroupManager.shared.ensureInboxExists()
                        if let inboxID = GroupManager.shared.inboxID {
                            NoteManager.shared.moveNote(id: noteID, toGroup: inboxID)
                        }
                    }

                    NoteManager.shared.cancelPendingSave()
                    NoteManager.shared.save()
                    reloadTrigger += 1

                    // Defer undo registration to the next run-loop tick so that
                    // updateNSView's reloadTrigger-driven undo-manager clear
                    // completes first. Use NoteManager directly to avoid the
                    // weak-reference silent failure when the panel is closed.
                    // Prefer the undoManager of the note's own panel so ⌘Z
                    // works even if Settings or another note is currently key.
                    // Falls back to key/main only when the panel was closed
                    // before the async dispatch fires.
                    let um = PanelManager.shared.undoManager(for: noteID)
                        ?? NSApp.keyWindow?.undoManager
                        ?? NSApp.mainWindow?.undoManager
                    let capturedPrevRichData = prevRichData
                    let capturedPrevPlain = prevPlain
                    let capturedPrevTitle = prevTitle
                    let capturedNoteID = noteID
                    DispatchQueue.main.async {
                        NoteManager.shared.registerOrganizeUndo(
                            id: capturedNoteID,
                            prevData: capturedPrevRichData,
                            prevPlain: capturedPrevPlain,
                            prevTitle: capturedPrevTitle,
                            undoManager: um
                        )
                    }
                }
            } catch {
                let msg = error.localizedDescription
                print("[Flote] Organize failed: \(msg)")
                await MainActor.run {
                    organizeError = msg
                    withAnimation { showErrorOverlay = true }
                    // Cancel any previous dismiss timer before starting a new one
                    // so rapid consecutive failures don't cause premature dismissal.
                    errorDismissTask?.cancel()
                    errorDismissTask = Task { @MainActor in
                        do {
                            try await Task.sleep(for: .seconds(5))
                            withAnimation { showErrorOverlay = false }
                        } catch {
                            // Task was cancelled (e.g. new error arrived or view disappeared).
                        }
                    }
                }
            }
            await MainActor.run { isOrganizing = false }
        }
    }

    /// Fallback when the Organize output lacks a `## タイトル` section.
    /// Picks the first non-blank, non-header, non-list line and clips to 12
    /// glyphs so the rolled scroll doesn't try to render a paragraph. Also
    /// skips pure date/time lines so fallbacks don't inherit the same
    /// "4月17日 10:30-"-as-title problem the LLM prompt now forbids.
    private static func firstContentLine(of result: String) -> String? {
        for raw in result.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty,
                  !t.hasPrefix("#"),
                  !t.hasPrefix("-"),
                  !t.hasPrefix("*"),
                  !t.hasPrefix("[ ]"),
                  !t.hasPrefix("[x]"),
                  !t.hasPrefix("[\u{2713}]"),
                  !StickyNote.looksLikeDateTimeOnly(t) else { continue }
            let cleaned = t.trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
            return cleaned.count > 12 ? String(cleaned.prefix(12)) : cleaned
        }
        return nil
    }

    /// Parses the `## タイトル` section from the Organize result.
    /// Returns the first non-empty line following that header, trimmed.
    private static func extractTitle(from result: String) -> String? {
        let lines = result.components(separatedBy: "\n")
        var seenHeader = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if seenHeader {
                // Skip blank lines between header and content.
                if trimmed.isEmpty { continue }
                // Stop if we hit the next section.
                if trimmed.hasPrefix("##") { return nil }
                // Strip any leading markdown emphasis.
                return trimmed
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*_`"))
            }
            // Accept ## タイトル or # タイトル
            if trimmed.hasPrefix("## タイトル") || trimmed.hasPrefix("# タイトル") {
                seenHeader = true
            }
        }
        return nil
    }
}

/// NSTextField wrapper that auto-focuses on appear, commits on Enter,
/// and commits on focus lost (clicking elsewhere). Suppresses the
/// system context menu (Look Up, Translate, etc.).
struct AutoFocusTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onFocusLost: () -> Void
    /// Called when the user presses Esc. Distinct from onCommit so callers
    /// can discard the draft instead of persisting it.
    var onCancel: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NoMenuTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        tf.alignment = .center
        tf.focusRingType = .none
        tf.textColor = .black
        tf.delegate = context.coordinator
        tf.stringValue = text
        DispatchQueue.main.async {
            // A .nonactivatingPanel won't auto-key on right-click, so
            // make it key here — otherwise makeFirstResponder silently
            // fails and the caret never lands.
            tf.window?.makeKey()
            tf.window?.makeFirstResponder(tf)
            // NSTextField selects all of its content on becoming first
            // responder. Collapse that selection and place the caret at
            // the end so the user types append-style — not replace-all.
            if let editor = tf.currentEditor() {
                let end = (tf.stringValue as NSString).length
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text {
            tf.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: AutoFocusTextField
        init(_ parent: AutoFocusTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocusLost()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                // Esc discards the draft — don't persist it.
                if let cancel = parent.onCancel {
                    cancel()
                } else {
                    parent.onFocusLost()
                }
                return true
            }
            return false
        }
    }

    final class NoMenuTextField: NSTextField {
        override func rightMouseDown(with event: NSEvent) {}
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}

/// Transparent NSView overlay that detects right-click (two-finger click)
/// and fires an action immediately — no context menu, no delay.
struct RightClickDetector: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickView {
        let v = RightClickView()
        v.onRightClick = action
        return v
    }

    func updateNSView(_ nsView: RightClickView, context: Context) {
        nsView.onRightClick = action
    }

    final class RightClickView: NSView {
        var onRightClick: (() -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }

        // Let left clicks pass through to SwiftUI's onTapGesture.
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim the hit for right-click events.
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }
    }
}
