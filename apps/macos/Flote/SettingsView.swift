import SwiftUI
import AppKit
import KeyboardShortcuts

@Observable
final class SettingsState {
    @MainActor static let shared = SettingsState()
    var selectedSection: SettingsSection = .general
    private init() {}
}

/// Warm sticky-note accent color applied across the settings window.
/// Matches the sticky-note pink tones used by the floating panels.
let floteAccent = Color(red: 0.95, green: 0.55, blue: 0.48)

/// Warm paper background for the main pane (the big area that used to be black).
private let paperBackground = Color(red: 0.993, green: 0.965, blue: 0.915)

/// Sidebar surface: slightly deeper warm tone so the two panes separate visually.
private let sidebarSurface = Color(red: 0.985, green: 0.905, blue: 0.830)

/// Card background for grouped settings blocks (slightly lighter than the pane).
private let paperCard = Color.white.opacity(0.72)

/// Text input / read-only code blocks: a touch more yellow to feel like paper.
private let paperInput = Color(red: 0.998, green: 0.985, blue: 0.945)

/// Aqua-Voice-inspired settings window with sidebar navigation.
struct SettingsView: View {
    @Bindable private var state = SettingsState.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 178)
                .background(sidebarSurface)

            Divider()

            Group {
                if state.selectedSection == .groups {
                    // Groups tab is a full-height 2-pane layout and handles its
                    // own padding internally.
                    GroupsSection()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(paperBackground)
                } else {
                    ScrollView {
                        sectionContent
                            .padding(.horizontal, 24)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(paperBackground)
                }
            }
        }
        .tint(floteAccent)
        .foregroundStyle(Color.black.opacity(0.82))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(floteAccent)
                Text("FLOTE")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.5)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 16)

            ForEach(SettingsSection.allCases, id: \.self) { section in
                sidebarButton(section)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(floteAccent)
                    .frame(width: 6, height: 6)
                Text("FREE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        let isActive = state.selectedSection == section
        return HStack(spacing: 10) {
            Image(systemName: section.icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
                .foregroundColor(isActive ? floteAccent : .secondary)
            Text(section.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .foregroundColor(isActive ? .primary : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? floteAccent.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectedSection = section
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Sections

    @ViewBuilder
    private var sectionContent: some View {
        switch state.selectedSection {
        case .groups:       EmptyView() // rendered by special-case above
        case .general:      GeneralSettingsSection()
        case .appearance:   AppearanceSettingsSection()
        case .ai:           AISettingsSection()
        case .prompt:       PromptSettingsSection()
        case .notes:        NotesSettingsSection()
        case .history:      HistorySettingsSection()
        case .shortcuts:    ShortcutsSettingsSection()
        case .about:        AboutSection()
        }
    }
}

// MARK: - Groups (2-pane: tree + note cards)

private struct GroupsSection: View {
    @Bindable private var gm = GroupManager.shared
    @Bindable private var nm = NoteManager.shared
    @Bindable private var selection = GroupsSelectionState.shared
    @State private var newGroupSheetParent: UUID?? = nil
    @State private var newGroupName: String = ""
    @State private var renameTarget: NoteGroup?
    @State private var renameDraft: String = ""

    var body: some View {
        HStack(spacing: 0) {
            GroupTreePane(
                onRequestNewGroup: { parent in
                    newGroupSheetParent = .some(parent)
                    newGroupName = ""
                },
                onRequestRename: { group in
                    renameTarget = group
                    renameDraft = group.name
                }
            )
            .frame(width: 240)
            .background(paperCard.opacity(0.5))

            Divider()

            GroupNoteCardsPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: Binding(
            get: { newGroupSheetParent != nil },
            set: { if !$0 { newGroupSheetParent = nil } }
        )) {
            newGroupSheet
        }
        .sheet(item: $renameTarget) { group in
            renameSheet(for: group)
        }
        .onAppear {
            // Default to Inbox if nothing is selected.
            if selection.selectedGroupID == nil {
                selection.selectedGroupID = gm.inboxID
            }
        }
    }

    private var newGroupSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(newGroupSheetParent.flatMap { $0 } == nil
                 ? "New Group"
                 : "New Subgroup")
                .font(.system(size: 15, weight: .semibold))

            TextField("Group name", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { confirmNewGroup() }

            HStack {
                Spacer()
                Button("Cancel") { newGroupSheetParent = nil }
                Button("Create") { confirmNewGroup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func confirmNewGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let parentID = newGroupSheetParent.flatMap { $0 }
        let newGroup = gm.createGroup(name: name, parent: parentID)
        selection.selectedGroupID = newGroup.id
        newGroupSheetParent = nil
    }

    private func renameSheet(for group: NoteGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Group")
                .font(.system(size: 15, weight: .semibold))
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { confirmRename(group: group) }
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                Button("Rename") { confirmRename(group: group) }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func confirmRename(group: NoteGroup) {
        gm.renameGroup(id: group.id, to: renameDraft)
        renameTarget = nil
    }
}

// MARK: Group tree pane (left)

private struct GroupTreePane: View {
    @Bindable private var gm = GroupManager.shared
    @Bindable private var selection = GroupsSelectionState.shared
    let onRequestNewGroup: (UUID?) -> Void
    let onRequestRename: (NoteGroup) -> Void

    var body: some View {
        // Observe _reloadTick to refresh after batch moves even when `groups`
        // array didn't change (only NoteManager.notes did).
        let _ = gm._reloadTick
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("グループ")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.black.opacity(0.55))
                Spacer()
                Button {
                    onRequestNewGroup(nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(floteAccent)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(floteAccent.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
                .help("New root group")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(gm.rootGroups) { root in
                        GroupTreeRow(
                            group: root,
                            depth: 0,
                            onRequestNewGroup: onRequestNewGroup,
                            onRequestRename: onRequestRename
                        )
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

// Recursive row. Keeps its own @State for expand/collapse since that's purely
// visual and doesn't need to persist across launches.
private struct GroupTreeRow: View {
    let group: NoteGroup
    let depth: Int
    let onRequestNewGroup: (UUID?) -> Void
    let onRequestRename: (NoteGroup) -> Void

    @Bindable private var gm = GroupManager.shared
    @Bindable private var nm = NoteManager.shared
    @Bindable private var selection = GroupsSelectionState.shared
    @State private var expanded = true
    @State private var isDropTarget = false
    @State private var showDeleteConfirmation = false

    // Read gm.groups directly so @Observable tracking picks this up whenever
    // children are created / deleted / re-parented.
    private var children: [NoteGroup] {
        gm.groups.filter { $0.parentGroupID == group.id }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
    private var noteCount: Int { nm.notes(inGroup: group.id).count }
    private var isActive: Bool { selection.selectedGroupID == group.id }
    private var isInbox: Bool { group.id == gm.inboxID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
            if expanded {
                ForEach(children) { child in
                    GroupTreeRow(
                        group: child,
                        depth: depth + 1,
                        onRequestNewGroup: onRequestNewGroup,
                        onRequestRename: onRequestRename
                    )
                }
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                gm.deleteGroup(id: group.id)
                if selection.selectedGroupID == group.id {
                    selection.selectedGroupID = gm.inboxID
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
    }

    private var deleteDialogTitle: String {
        "「\(group.name)」を削除しますか？"
    }

    private var deleteDialogMessage: String {
        let subCount = gm.descendantSubgroupCount(of: group.id)
        let noteCount = gm.totalNoteCount(of: group.id)
        var parts: [String] = []
        if subCount > 0 { parts.append("サブグループ \(subCount) 個") }
        if noteCount > 0 { parts.append("ノート \(noteCount) 件") }
        let content = parts.isEmpty ? "" : "（\(parts.joined(separator: "、"))）"
        // GroupManager.deleteGroup re-parents children to the deleted group's
        // parent (not to root) — only notes whose group lands at root without
        // a parent go to Inbox. Reflect that precisely to avoid misleading
        // the user into thinking sub-groups will be flattened to top level.
        return "このグループ\(content)を削除します。サブグループとノートは親グループ（root の場合のみ Inbox）へ移動します。"
    }

    private var rowContent: some View {
        HStack(spacing: 4) {
            // Finder-style disclosure caret. Always reserves the same width so
            // siblings with and without children stay aligned.
            Group {
                if !children.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.65))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }
            }

            Image(systemName: group.iconName)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? floteAccent : Color(red: 0.55, green: 0.50, blue: 0.42))
                .frame(width: 18)

            Text(group.name)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.black.opacity(0.85))

            Spacer(minLength: 4)

            if noteCount > 0 {
                Text("\(noteCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.08)))
            }
        }
        // N7: cap indent so ultra-deep groups (depth > 8) don't push content
        // off-screen.  Groups deeper than 8 share the same indent as depth 8.
        // repairCycles() already blocks infinite nesting; this is a visual guard.
        .padding(.leading, CGFloat(min(depth, 8)) * 20 + 10)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackgroundColor)
                .padding(.horizontal, 4)
        )
        .overlay(alignment: .leading) {
            // A subtle vertical guide line for non-root rows so the parent/child
            // relationship reads at a glance (Finder column / VS Code style).
            if depth > 0 {
                Rectangle()
                    .fill(Color.black.opacity(0.10))
                    .frame(width: 1)
                    .padding(.leading, CGFloat(depth - 1) * 20 + 17)
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selection.selectedGroupID = group.id
        }
        .contextMenu {
            Button("New subgroup") { onRequestNewGroup(group.id) }
            if !isInbox {
                Button("Rename") { onRequestRename(group) }
                Divider()
                Button("Delete", role: .destructive) {
                    // D1: show confirmation only when the group has children.
                    // Empty groups are deleted immediately to reduce clicks.
                    if gm.groupHasChildren(id: group.id) {
                        showDeleteConfirmation = true
                    } else {
                        gm.deleteGroup(id: group.id)
                        if selection.selectedGroupID == group.id {
                            selection.selectedGroupID = gm.inboxID
                        }
                    }
                }
            }
        }
        // Drop target for notes dragged from the card pane. We pass the note's
        // UUID as a plain string so it works across SwiftUI / AppKit drag types.
        .dropDestination(for: String.self) { items, _ in
            guard let idStr = items.first,
                  let noteID = UUID(uuidString: idStr) else { return false }
            nm.moveNote(id: noteID, toGroup: group.id)
            // Auto-expand so the user sees their note land inside.
            withAnimation(.easeInOut(duration: 0.15)) { expanded = true }
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }

    private var rowBackgroundColor: Color {
        if isDropTarget {
            return floteAccent.opacity(0.28)
        }
        if isActive {
            return floteAccent.opacity(0.16)
        }
        return .clear
    }
}

// MARK: Right pane — note cards

private struct GroupNoteCardsPane: View {
    @Bindable private var gm = GroupManager.shared
    @Bindable private var nm = NoteManager.shared
    @Bindable private var selection = GroupsSelectionState.shared
    @State private var isBatchClassifying = false
    @State private var batchProgress: NoteManager.BatchClassifyProgress?
    @State private var showBatchConfirm = false
    @State private var showBatchResult = false

    private var selectedGroup: NoteGroup? {
        guard let id = selection.selectedGroupID else { return nil }
        return gm.group(byID: id)
    }

    private var notesInGroup: [StickyNote] {
        guard let id = selection.selectedGroupID else { return [] }
        return nm.notes(inGroup: id)
    }

    private var isInbox: Bool {
        guard let id = selection.selectedGroupID else { return false }
        return id == gm.inboxID
    }

    var body: some View {
        // Observe GroupManager._reloadTick so batchClassifyInbox and other
        // bulk operations that don't mutate `groups` still re-render this
        // pane. Without this, the sidebar count stays stale after batch move.
        let _ = gm._reloadTick
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedGroup?.name ?? "No Group Selected")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Text("\(notesInGroup.count) note\(notesInGroup.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.55))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if isInbox && !notesInGroup.isEmpty {
                inboxBatchBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            Divider()

            if notesInGroup.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.black.opacity(0.30))
                    Text("No notes here yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.55))
                    Text("Click the しまう (archivebox) button on any note to move it here.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.black.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 210), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(notesInGroup) { note in
                            ArchivedNoteCard(note: note)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .alert(
            "Auto-classify Inbox?",
            isPresented: $showBatchConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Run") { runBatchClassify() }
        } message: {
            Text("Classify \(notesInGroup.count) notes via AI and sort them into matching groups. Claude API costs apply per note.")
        }
        .alert(
            "Classification Complete",
            isPresented: $showBatchResult
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let p = batchProgress {
                if p.failed == 0 {
                    Text("\(p.processed) 件処理、\(p.moved) 件移動しました。")
                } else {
                    let breakdown = p.errorSummary.isEmpty ? "" : "（\(p.errorSummary)）"
                    Text("\(p.processed) 件処理、\(p.moved) 件移動、\(p.failed) 件失敗\(breakdown)。\nSettings > AI Organize > Diagnostics で詳細を確認してください。")
                }
            }
        }
    }

    @ViewBuilder
    private var inboxBatchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(floteAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI Auto-classify")
                    .font(.system(size: 12, weight: .semibold))
                if let p = batchProgress, isBatchClassifying {
                    Text("Processing \(p.processed) / \(p.total)...")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sort all Inbox notes into matching groups")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isBatchClassifying {
                ProgressView().controlSize(.small)
            } else {
                Button("Run (\(notesInGroup.count))") {
                    showBatchConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(notesInGroup.isEmpty)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(floteAccent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(floteAccent.opacity(0.25), lineWidth: 1)
        )
    }

    private func runBatchClassify() {
        guard !isBatchClassifying else { return }
        isBatchClassifying = true
        batchProgress = .init(total: notesInGroup.count, processed: 0, moved: 0, failed: 0)
        Task {
            let result = await nm.batchClassifyInbox { progress in
                batchProgress = progress
            }
            await MainActor.run {
                batchProgress = result
                isBatchClassifying = false
                showBatchResult = true
            }
        }
    }
}

private struct ArchivedNoteCard: View {
    let note: StickyNote
    @Bindable private var nm = NoteManager.shared
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(note.colorTheme.backgroundColor)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(Color.black.opacity(0.85))
                Spacer()
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.red.opacity(0.70))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Delete permanently (moves to History)")
            }

            Text(preview)
                .font(.system(size: 11))
                .foregroundStyle(Color.black.opacity(0.70))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text(archivedRelative)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.black.opacity(0.40))
                Spacer()
                Text("Click to restore →")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(floteAccent)
            }
        }
        .padding(12)
        // N8: allow the card to grow beyond 140pt for emoji / CJK-heavy content.
        // fixedSize(horizontal:false, vertical:true) lets the VStack dictate the
        // height while still filling the column width.  lineLimit(4) on the
        // preview Text is preserved so content doesn't grow unbounded.
        .frame(minHeight: 140)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(paperCard)
                .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        // Make the card draggable: its UUID string is carried as the payload
        // and consumed by GroupTreeRow.dropDestination.
        .draggable(note.id.uuidString) {
            // Drag preview shown while moving.
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(note.colorTheme.backgroundColor)
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(paperCard)
                    .shadow(color: Color.black.opacity(0.20), radius: 4)
            )
        }
        .onTapGesture {
            // Card tap = bring this note onto the screen as a floating panel.
            // The note stays in its group; opening it is purely a UI action.
            if PanelManager.shared.hasPanel(noteID: note.id) {
                PanelManager.shared.focusPanel(noteID: note.id)
            } else {
                nm.openPanel(noteID: note.id)
                if let updated = nm.note(byID: note.id) {
                    PanelManager.shared.createPanel(for: updated)
                }
            }
        }
        .confirmationDialog(
            "Delete this note permanently?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                // Groups-tab trash: real, explicit delete. Content goes to
                // History so the user can still recover if they change their mind.
                PanelManager.shared.removePanel(for: note.id)
                nm.deleteNote(id: note.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The note will be moved to History. You can restore it from the History tab.")
        }
    }

    private var title: String {
        let t = note.rolledTitle
        if let t = t, !t.isEmpty { return t }
        let firstLine = note.text
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private var preview: String {
        let t = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 160 { return t }
        return String(t.prefix(160)) + "…"
    }

    private var archivedRelative: String {
        guard let at = note.sortedAt else { return "" }
        let seconds = Int(Date().timeIntervalSince(at))
        switch seconds {
        case ..<60:        return "just now"
        case 60..<3600:    return "\(seconds / 60)m ago"
        case 3600..<86400: return "\(seconds / 3600)h ago"
        default:           return "\(seconds / 86400)d ago"
        }
    }
}

// MARK: - Prompt

private struct PromptSettingsSection: View {
    @Bindable private var pref = PromptPreference.shared
    @State private var draftCustom: String = PromptPreference.shared.customPrompt
    @State private var statusMessage: String?
    // N4: track whether the draft has been explicitly saved so onDisappear can
    // revert unsaved edits instead of silently losing them.
    @State private var draftSaved = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("プロンプト")
                .font(.system(size: 18, weight: .bold))

            Text("AIにノートをどう整理させるかを選びます。行全体がクリック可能。")
                .font(.system(size: 12))
                .foregroundStyle(Color.black.opacity(0.60))

            settingsGroup(title: "プリセット") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PromptPreset.allCases) { preset in
                        presetRow(preset)
                    }
                }
            }

            if pref.current == .custom {
                settingsGroup(title: "CUSTOM PROMPT (EDITABLE)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The placeholder `\\(text)` will be replaced with your note content.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.black.opacity(0.50))

                        TextEditor(text: $draftCustom)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(paperInput)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                                    )
                            )
                            // N4: mark draft dirty on any change.
                            .onChange(of: draftCustom) { _, _ in
                                draftSaved = (draftCustom == pref.customPrompt)
                            }

                        HStack {
                            Button("保存") {
                                pref.customPrompt = draftCustom
                                draftSaved = true
                                statusMessage = "保存しました"
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(draftCustom == pref.customPrompt)

                            // N4: Cancel reverts draft to last saved value.
                            if !draftSaved {
                                Button("キャンセル") {
                                    draftCustom = pref.customPrompt
                                    draftSaved = true
                                    statusMessage = nil
                                }
                                .controlSize(.small)
                            }

                            Button("空テンプレートにリセット") {
                                draftCustom = PromptPreference.defaultCustomTemplate
                                pref.customPrompt = draftCustom
                                draftSaved = true
                                statusMessage = "リセット"
                            }
                            .controlSize(.small)

                            Button("標準から読み込む") {
                                let seed = OrganizeService.previewPrompt(for: .standard)
                                    .replacingOccurrences(of: "{{ あなたのノート本文がここに入ります }}", with: "\\(text)")
                                draftCustom = seed
                                pref.customPrompt = seed
                                draftSaved = true
                                statusMessage = "標準プロンプトを読み込みました"
                            }
                            .controlSize(.small)

                            Spacer()

                            if let msg = statusMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.black.opacity(0.55))
                            }
                        }
                    }
                }
                // N4: if the user navigates away without saving, revert the draft
                // so the stored prompt is what actually gets used.
                .onDisappear {
                    if !draftSaved {
                        draftCustom = pref.customPrompt
                        draftSaved = true
                    }
                }
            } else {
                settingsGroup(title: "ACTUAL PROMPT (READ-ONLY)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The actual prompt sent to AI for the selected preset. Scroll down to see full text.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.black.opacity(0.50))

                        ScrollView {
                            Text(OrganizeService.previewPrompt(for: pref.current))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.black.opacity(0.78))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(height: 260)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(paperInput)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                                )
                        )
                    }
                }
            }
        }
    }

    private func presetRow(_ preset: PromptPreset) -> some View {
        let isActive = pref.current == preset
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundColor(isActive ? floteAccent : Color.black.opacity(0.35))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(preset.displayName)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(Color.black.opacity(0.85))
                Text(preset.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? floteAccent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let wasBlank = pref.customPrompt == PromptPreference.defaultCustomTemplate
            pref.current = preset
            if preset == .custom {
                // 初めてカスタム化するときは標準プロンプトを種として注入する。
                // 既に編集済みならそのまま保持。
                if wasBlank {
                    let seed = OrganizeService.previewPrompt(for: .standard)
                        .replacingOccurrences(of: "{{ あなたのノート本文がここに入ります }}", with: "\\(text)")
                    pref.customPrompt = seed
                }
                draftCustom = pref.customPrompt
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsSection: View {
    @State private var selected: AppFont = FontPreference.shared.current

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("外観")
                .font(.system(size: 18, weight: .bold))

            settingsGroup(title: "フォント") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Used for note body text and the rolled-up scroll title.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("Font family", selection: $selected) {
                        ForEach(AppFont.allCases) { font in
                            Text(font.displayName).tag(font)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: selected) { _, new in
                        FontPreference.shared.current = new
                    }

                    Text("Preview")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    Text("あのイーハトーヴォのすきとおった風 — The quick brown fox")
                        .font(Font(selected.nsFont(size: 11) as CTFont))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                }
            }
        }
    }
}

enum SettingsSection: String, CaseIterable {
    case groups, general, appearance, ai, prompt, notes, history, shortcuts, about

    // N9: section titles in Japanese. Technical/brand terms (AI, FLOTE, Prompt,
    // API key etc.) remain in English per spec.
    var title: String {
        switch self {
        case .groups:     return "グループ"
        case .general:    return "一般"
        case .appearance: return "外観"
        case .ai:         return "AI 整理"
        case .prompt:     return "プロンプト"
        case .notes:      return "ノート"
        case .history:    return "履歴"
        case .shortcuts:  return "ショートカット"
        case .about:      return "このアプリについて"
        }
    }

    var icon: String {
        switch self {
        case .groups:     return "folder"
        case .general:    return "gearshape"
        case .appearance: return "paintbrush"
        case .ai:         return "wand.and.stars"
        case .prompt:     return "text.bubble"
        case .notes:      return "note.text"
        case .history:    return "clock.arrow.circlepath"
        case .shortcuts:  return "command"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - General

private struct GeneralSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("一般")
                .font(.system(size: 18, weight: .bold))

            settingsGroup(title: "起動時") {
                Text("Notes start in expanded state on each launch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            settingsGroup(title: "履歴") {
                Text("直近 20 件の削除済みノートをメニューバーから復元できます。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - AI

private struct AISettingsSection: View {
    @State private var apiKey: String = ""
    @State private var ollamaURL: String = UserDefaults.standard.string(forKey: "floteOrganizeURL")
        ?? "http://localhost:11434/api/generate"
    @State private var statusMessage: String?
    @State private var hasSavedKey = false
    // N5: flag set when the SecureField text changes but Save hasn't been pressed.
    @State private var apiKeyDirty = false
    // N5: show alert when dismissing with unsaved key.
    @State private var showUnsavedKeyAlert = false
    // M8-1 / N6: Ollama reachability state.
    @State private var ollamaStatus: String? = nil
    @State private var ollamaStatusIsError = false

    // Track-3 2026-05-12: confirmation dialog state for non-loopback Ollama URL.
    // The user must explicitly OK each switch FROM loopback TO a remote host;
    // re-saving a remote URL that's already opted-in is a silent no-op confirm.
    @State private var showRemoteOllamaConfirm = false
    @State private var pendingRemoteOllamaURL: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("AI Organize")
                .font(.system(size: 18, weight: .bold))

            Text("短いノートをローカル LLM へ、長いノートを Claude Sonnet へ振り分けます。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            settingsGroup(title: "CLAUDE API KEY") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        // N5: track changes to detect unsaved state.
                        .onChange(of: apiKey) { _, _ in
                            apiKeyDirty = !apiKey.isEmpty
                        }

                    HStack {
                        Button("Keychain に保存") {
                            saveAPIKey()
                        }
                        .disabled(apiKey.isEmpty)

                        if hasSavedKey {
                            // N6: re-check hasSavedKey on button actions.
                            Button("削除") { removeAPIKey() }
                                .foregroundColor(.red)
                        }

                        Spacer()

                        if let msg = statusMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("console.anthropic.com でキーを取得。macOS Keychain に安全に保存されます。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("ペースト後はクリップボードを別の内容で上書きすることをおすすめします。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange.opacity(0.7))
                }
            }

            settingsGroup(title: "LOCAL LLM (OLLAMA)") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("http://localhost:11434/api/generate", text: $ollamaURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    HStack {
                        Button("URL を保存") {
                            saveOllamaURL()
                        }

                        // M8-1: Ollama 接続テストボタン。
                        Button("接続テスト") {
                            checkOllamaReachability()
                        }

                        if let st = ollamaStatus {
                            Text(st)
                                .font(.system(size: 11))
                                .foregroundStyle(ollamaStatusIsError ? Color.red : Color.green)
                        }
                    }

                    Text("200文字未満のノートに使用。Ollama がローカルで動作している場合はデフォルトのままでOKです。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    // Track-3 2026-05-12: warn the user when a non-loopback host is in the field.
                    if OrganizeService.requiresRemoteOptIn(urlString: ollamaURL) {
                        Text("注意: ローカル以外の Ollama サーバーに接続するとノート本文がネットワーク経由で送信されます。保存時に確認が表示されます。")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                }
            }

            DiagnosticLogSection()
        }
        .onAppear {
            // N6: re-check Keychain presence every time the section appears.
            hasSavedKey = KeychainHelper.readAPIKey() != nil
        }
        // N6: also re-check when the Settings window regains key status, so
        // external Keychain removals (e.g. Keychain Access app) are reflected.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in
            hasSavedKey = KeychainHelper.readAPIKey() != nil
        }
        // N5: prompt before navigating away with an unsaved API key. The
        // alert binding was wired but nobody triggered it — flip the flag
        // here so the user can choose Save vs Discard instead of losing the
        // paste silently.
        .onDisappear {
            if apiKeyDirty, !apiKey.isEmpty {
                showUnsavedKeyAlert = true
            } else if apiKeyDirty {
                apiKeyDirty = false
            }
        }
        .alert("APIキーが保存されていません", isPresented: $showUnsavedKeyAlert) {
            Button("保存") { saveAPIKey() }
            Button("破棄", role: .destructive) {
                apiKey = ""
                apiKeyDirty = false
            }
        } message: {
            Text("入力されたAPIキーはまだ Keychain に保存されていません。保存しますか？")
        }
        // Track-3 2026-05-12: opt-in confirmation for non-loopback Ollama URL.
        .alert("リモートの Ollama サーバーに接続しますか？", isPresented: $showRemoteOllamaConfirm) {
            Button("キャンセル", role: .cancel) {
                pendingRemoteOllamaURL = ""
            }
            Button("接続する", role: .destructive) {
                // Persist opt-in flag + the URL. Opt-in is sticky until the
                // user explicitly clears it (by switching back to a loopback
                // URL and saving), so we don't re-prompt on every change.
                UserDefaults.standard.set(true, forKey: OrganizeService.remoteOllamaOptInKey)
                UserDefaults.standard.set(pendingRemoteOllamaURL, forKey: OrganizeService.ollamaURLKey)
                ollamaURL = pendingRemoteOllamaURL
                statusMessage = "リモート Ollama URL を保存しました (要再起動の可能性あり)"
                pendingRemoteOllamaURL = ""
            }
        } message: {
            Text("入力された URL は端末外のサーバーです (\(pendingRemoteOllamaURL))。Organize 実行時にノート本文がそのサーバーへ送信されます。続行しますか？")
        }
    }

    // Track-3 2026-05-12: gated Ollama URL save.
    //
    // - Loopback URLs (localhost / 127.0.0.1 / ::1): save immediately, and
    //   also clear the opt-in flag so a future switch back to remote requires
    //   re-confirmation.
    // - Non-loopback URLs: stage as pending and trigger the confirmation
    //   alert. The actual persist happens in the alert's "接続する" button.
    // - Malformed URLs: persist the string but show a parse-error message
    //   (preserves the pre-2026-05-12 lenient behavior — the network call
    //   will fail later with a clearer error).
    private func saveOllamaURL() {
        if OrganizeService.requiresRemoteOptIn(urlString: ollamaURL) {
            pendingRemoteOllamaURL = ollamaURL
            showRemoteOllamaConfirm = true
            return
        }
        // Loopback / https — clear any prior opt-in flag and save.
        UserDefaults.standard.set(false, forKey: OrganizeService.remoteOllamaOptInKey)
        UserDefaults.standard.set(ollamaURL, forKey: OrganizeService.ollamaURLKey)
        statusMessage = "URL を保存しました"
    }

    // M8-1: Ollama /api/tags への接続テスト。
    private func checkOllamaReachability() {
        // Derive base URL from the generate endpoint (strip /api/generate suffix).
        var base = ollamaURL
        if let range = base.range(of: "/api/generate") {
            base = String(base[..<range.lowerBound])
        }
        guard let url = URL(string: "\(base)/api/tags") else {
            ollamaStatus = "URL が無効です"
            ollamaStatusIsError = true
            return
        }
        ollamaStatus = "確認中..."
        ollamaStatusIsError = false
        Task {
            do {
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "GET"
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    if (200..<300).contains(code) {
                        ollamaStatus = "接続成功 (HTTP \(code))"
                        ollamaStatusIsError = false
                    } else {
                        ollamaStatus = "エラー (HTTP \(code))"
                        ollamaStatusIsError = true
                    }
                }
            } catch {
                await MainActor.run {
                    ollamaStatus = "接続失敗: \(error.localizedDescription)"
                    ollamaStatusIsError = true
                }
            }
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Format validation: sk-ant- prefix check (M8 — basic sanity before Keychain write).
        let looksValid = trimmed.hasPrefix("sk-ant-") && trimmed.count > 20
        if !looksValid {
            statusMessage = "警告: キーの形式が正しくない可能性があります (sk-ant- が必要)"
            // Still attempt to save so the user can correct it via Settings later.
        }

        if KeychainHelper.saveAPIKey(trimmed) {
            // Read-back verification: confirm the saved value can be retrieved.
            // This catches Keychain ACL errors or service-name mismatches that
            // silently succeed on write but fail on read at Organize time (M8).
            if let readBack = KeychainHelper.readAPIKey(), readBack == trimmed {
                if looksValid {
                    statusMessage = "保存完了"
                }
                // (if !looksValid, statusMessage already shows warning above)
                hasSavedKey = true
                apiKey = ""
                apiKeyDirty = false   // N5: clear dirty flag after successful save.
            } else {
                statusMessage = "Keychain 検証失敗 — アクセス権限を確認してください"
                hasSavedKey = false
            }
        } else {
            statusMessage = "保存失敗"
        }
    }

    private func removeAPIKey() {
        if KeychainHelper.deleteAPIKey() {
            statusMessage = "Removed"
            hasSavedKey = false
        }
    }
}

// MARK: - Diagnostic Log

private struct DiagnosticLogSection: View {
    @Bindable private var service = OrganizeService.shared

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        settingsGroup(title: "DIAGNOSTICS") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("直近のエラー履歴（最大 20 件）")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("クリア") {
                        service.clearRecentErrors()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                if service.recentErrors.isEmpty {
                    Text("エラーなし")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(service.recentErrors.reversed().enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(Self.dateFormatter.string(from: entry.date))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .leading)
                                Text(entry.message)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.red.opacity(0.75))
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.red.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Notes (active notes list)

private struct NotesSettingsSection: View {
    @Bindable private var manager = NoteManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("ノート")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    let note = manager.createNote()
                    PanelManager.shared.createPanel(for: note)
                } label: {
                    Label("New Note", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if manager.notes.isEmpty {
                emptyState(
                    icon: "note.text",
                    message: "No active notes. Press Option+Space or click New Note above."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(manager.notes.enumerated()), id: \.element.id) { index, note in
                        noteRow(note)
                        if index < manager.notes.count - 1 {
                            Divider().padding(.horizontal, 4)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private func noteRow(_ note: StickyNote) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(note.colorTheme.backgroundColor)
                .frame(width: 26, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .overlay(
                    Image(systemName: stowIcon(for: note.stowState))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.45))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(noteTitle(note))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(relativeTimestamp(note.modifiedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                PanelManager.shared.toggleStow(noteID: note.id)
            } label: {
                Image(systemName: note.stowState == .expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help(note.stowState == .expanded ? "Roll up" : "Expand")

            Button {
                PanelManager.shared.removePanel(for: note.id)
                manager.deleteNote(id: note.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.red.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .help("Delete (moves to History)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            PanelManager.shared.focusPanel(noteID: note.id)
        }
    }

    private func stowIcon(for state: StowState) -> String {
        switch state {
        case .expanded:  return "doc.text"
        case .rolledUp:  return "scroll"
        case .mini:      return "circle.fill"
        }
    }
}

// MARK: - History

private struct HistorySettingsSection: View {
    @Bindable private var manager = NoteManager.shared
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("履歴")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                if !manager.history.isEmpty {
                    Button("すべてクリア", role: .destructive) {
                        showClearConfirm = true
                    }
                    .controlSize(.small)
                }
            }

            Text("The last 20 deleted notes. Click restore to bring one back as an active note.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if manager.history.isEmpty {
                emptyState(
                    icon: "clock.arrow.circlepath",
                    message: "No deleted notes yet."
                )
            } else {
                VStack(spacing: 0) {
                    let reversedHistory = Array(manager.history.reversed().enumerated())
                    ForEach(reversedHistory, id: \.element.id) { index, entry in
                        historyRow(entry)
                        if index < manager.history.count - 1 {
                            Divider().padding(.horizontal, 4)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
        .confirmationDialog("Clear all history?",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                manager.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all \(manager.history.count) history entries.")
        }
    }

    private func historyRow(_ entry: StickyNote) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(entry.colorTheme.backgroundColor.opacity(0.6))
                .frame(width: 26, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(noteTitle(entry))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary.opacity(0.75))
                Text(relativeTimestamp(entry.modifiedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if let restored = NoteManager.shared.restoreFromHistory(id: entry.id) {
                    PanelManager.shared.createPanel(for: restored)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Restore")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("ショートカット")
                .font(.system(size: 18, weight: .bold))

            Text("行をクリックして新しいキーを記録します。Delete でクリア、Esc でキャンセル。システムや他のアプリとのコンフリクトは自動的に警告されます。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            settingsGroup(title: "グローバル") {
                KeyRecorderRow(
                    label: "New note",
                    description: "Create a new sticky note from any app",
                    name: .newNote
                )
                KeyRecorderRow(
                    label: "View Groups",
                    description: "Open Settings and jump to the Groups tab",
                    name: .viewGroups
                )
                KeyRecorderRow(
                    label: "Archive (global)",
                    description: "Archive the last focused Flote panel, even when another app is active",
                    name: .archiveNote
                )
            }

            settingsGroup(title: "IN APP") {
                staticShortcutRow(
                    "Archive (close panel)",
                    keys: "⌘ W",
                    note: "Only when a Flote panel is focused. The note stays in Groups."
                )
            }

            settingsGroup(title: "IN SETTINGS") {
                staticShortcutRow("Open Settings", keys: "⌘ ,")
                staticShortcutRow("Quit Flote", keys: "⌘ Q")
            }
        }
    }

    @ViewBuilder
    private func staticShortcutRow(
        _ label: String,
        keys: String,
        note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Text(keys)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One row = label + KeyboardShortcuts.Recorder. UserDefaults persistence is
/// handled by the library; rebinding takes effect immediately at the next
/// keystroke thanks to HotkeyService's onKeyUp listeners.
private struct KeyRecorderRow: View {
    let label: String
    let description: String
    let name: KeyboardShortcuts.Name

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 12))
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KeyboardShortcuts.Recorder(for: name)
            }
        }
    }
}

// MARK: - About

private struct AboutSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("このアプリについて")
                .font(.system(size: 18, weight: .bold))

            HStack(spacing: 14) {
                Image(systemName: "note.text")
                    .font(.system(size: 44))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flote")
                        .font(.system(size: 20, weight: .bold))
                    Text("Version \(appVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("A sticky-note app with AI-powered organization.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}

// MARK: - Shared helpers

@ViewBuilder
private func settingsGroup<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.black.opacity(0.45))
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(paperCard)
                    .shadow(color: Color.black.opacity(0.04),
                            radius: 3, x: 0, y: 1)
            )
    }
}

@ViewBuilder
private func emptyState(icon: String, message: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(Color.black.opacity(0.30))
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Color.black.opacity(0.55))
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(32)
    .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(paperCard.opacity(0.6))
    )
}

private func noteTitle(_ note: StickyNote) -> String {
    let firstLine = note.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "Untitled note" : trimmed
}

private func relativeTimestamp(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    switch seconds {
    case ..<60:        return "just now"
    case 60..<3600:    return "\(seconds / 60)m ago"
    case 3600..<86400: return "\(seconds / 3600)h ago"
    default:           return "\(seconds / 86400)d ago"
    }
}
