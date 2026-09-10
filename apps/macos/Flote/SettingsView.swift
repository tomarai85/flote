import SwiftUI
import AppKit
import KeyboardShortcuts
import UniformTypeIdentifiers

@Observable
final class SettingsState {
    @MainActor static let shared = SettingsState()
    var selectedSection: SettingsSection = .general
    private init() {}
}

/// Warm sticky-note accent color applied across the settings window.
/// Matches the sticky-note pink tones used by the floating panels.
let floteAccent = Color(red: 0.85, green: 0.62, blue: 0.13)

/// Warm paper background for the main pane (the big area that used to be black).
private let paperBackground = Color(red: 0.995, green: 0.978, blue: 0.930)

/// Sidebar surface: slightly deeper warm tone so the two panes separate visually.
private let sidebarSurface = Color(red: 0.988, green: 0.955, blue: 0.845)

/// Card background for grouped settings blocks (slightly lighter than the pane).
private let paperCard = Color.white.opacity(0.72)

/// Text input / read-only code blocks: a touch more yellow to feel like paper.
private let paperInput = Color(red: 0.999, green: 0.99, blue: 0.955)

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
        case .backup:       BackupSettingsSection()
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
                 ? L("新しいグループ", "New Group")
                 : L("新しいサブグループ", "New Subgroup"))
                .font(.system(size: 15, weight: .semibold))

            TextField(L("グループ名", "Group name"), text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { confirmNewGroup() }

            HStack {
                Spacer()
                Button(L("キャンセル", "Cancel")) { newGroupSheetParent = nil }
                Button(L("作成", "Create")) { confirmNewGroup() }
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
            Text(L("グループ名を変更", "Rename Group"))
                .font(.system(size: 15, weight: .semibold))
            TextField(L("名前", "Name"), text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { confirmRename(group: group) }
            HStack {
                Spacer()
                Button(L("キャンセル", "Cancel")) { renameTarget = nil }
                Button(L("変更", "Rename")) { confirmRename(group: group) }
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
                Text(L("グループ", "Groups"))
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
            Button(L("削除", "Delete"), role: .destructive) {
                gm.deleteGroup(id: group.id)
                if selection.selectedGroupID == group.id {
                    selection.selectedGroupID = gm.inboxID
                }
            }
            Button(L("キャンセル", "Cancel"), role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
    }

    private var deleteDialogTitle: String {
        L("「\(group.name)」を削除しますか？", "Delete “\(group.name)”?")
    }

    private var deleteDialogMessage: String {
        let subCount = gm.descendantSubgroupCount(of: group.id)
        let noteCount = gm.totalNoteCount(of: group.id)
        var parts: [String] = []
        if subCount > 0 { parts.append(L("サブグループ \(subCount) 個", "\(subCount) subgroups")) }
        if noteCount > 0 { parts.append(L("ノート \(noteCount) 件", "\(noteCount) notes")) }
        let content = parts.isEmpty ? "" : "（\(parts.joined(separator: "、"))）"
        // GroupManager.deleteGroup re-parents children to the deleted group's
        // parent (not to root) — only notes whose group lands at root without
        // a parent go to Inbox. Reflect that precisely to avoid misleading
        // the user into thinking sub-groups will be flattened to top level.
        return L("このグループ\(content)を削除します。サブグループとノートは親グループ（root の場合のみ Inbox）へ移動します。", "Deletes this group\(content). Subgroups and notes move to the parent group (or Inbox at root).")
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
            Button(L("サブグループを作成", "New subgroup")) { onRequestNewGroup(group.id) }
            if !isInbox {
                Button(L("名前を変更", "Rename")) { onRequestRename(group) }
                Divider()
                Button(L("削除", "Delete"), role: .destructive) {
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
                    Text(L("まだノートがありません。", "No notes here yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.55))
                    Text(L("ノートの「しまう」(archivebox) ボタンでここに移動します。", "Click the archivebox button on any note to move it here."))
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
            L("Inbox を自動分類しますか？", "Auto-classify Inbox?"),
            isPresented: $showBatchConfirm
        ) {
            Button(L("キャンセル", "Cancel"), role: .cancel) {}
            Button(L("実行", "Run")) { runBatchClassify() }
        } message: {
            Text(L("\(notesInGroup.count) 件のノートを AI で分類して、合うグループへ振り分けます。ノートごとに Claude API 費用がかかります。", "Classify \(notesInGroup.count) notes via AI and sort them into matching groups. Claude API costs apply per note."))
        }
        .alert(
            L("分類が完了しました", "Classification Complete"),
            isPresented: $showBatchResult
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            if let p = batchProgress {
                if p.failed == 0 {
                    Text(L("\(p.processed) 件処理、\(p.moved) 件移動しました。", "Processed \(p.processed), moved \(p.moved)."))
                } else {
                    let breakdown = p.errorSummary.isEmpty ? "" : "（\(p.errorSummary)）"
                    Text(L("\(p.processed) 件処理、\(p.moved) 件移動、\(p.failed) 件失敗\(breakdown)。\nSettings > AI Organize > Diagnostics で詳細を確認してください。", "Processed \(p.processed), moved \(p.moved), \(p.failed) failed\(breakdown).\nSee Settings > AI Organize > Diagnostics."))
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
                Text(L("AI 自動振り分け", "AI Auto-classify"))
                    .font(.system(size: 12, weight: .semibold))
                if let p = batchProgress, isBatchClassifying {
                    Text(L("処理中 \(p.processed) / \(p.total)…", "Processing \(p.processed) / \(p.total)…"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Inbox の全ノートを合うグループへ振り分け", "Sort all Inbox notes into matching groups"))
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
                Text(L("クリックで復元 →", "Click to restore →"))
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
            Text(L("ノートは履歴へ移動します。履歴タブから復元できます。", "The note will be moved to History. You can restore it from the History tab."))
        }
    }

    private var title: String {
        let t = note.rolledTitle
        if let t = t, !t.isEmpty { return t }
        // Sealed accessor (r3b NEW-1 + NEW-2 whitespace gate).
        if note.isLocked { return note.lockedSafeTitle ?? L("ロック中のノート", "Locked note") }
        let firstLine = note.text
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private var preview: String {
        // S6 lock: card previews must not leak a locked note's body.
        if note.isLocked { return L("ロック中（Touch ID で開きます）", "Locked (opens with Touch ID)") }
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
            Text(L("プロンプト", "Prompt"))
                .font(.system(size: 18, weight: .bold))

            Text(L("AIにノートをどう整理させるかを選びます。行全体がクリック可能。", "Choose how the AI organizes notes. Whole row is clickable."))
                .font(.system(size: 12))
                .foregroundStyle(Color.black.opacity(0.60))

            settingsGroup(title: L("プリセット", "Presets")) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PromptPreset.allCases) { preset in
                        presetRow(preset)
                    }
                }
            }

            if pref.current == .custom {
                settingsGroup(title: L("カスタムプロンプト（編集可）", "Custom prompt (editable)")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("`\\(text)` の部分がノート本文に置き換わります。", "The placeholder `\\(text)` is replaced with your note content."))
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
                            Button(L("保存", "Save")) {
                                pref.customPrompt = draftCustom
                                draftSaved = true
                                statusMessage = L("保存しました", "Saved")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(draftCustom == pref.customPrompt)

                            // N4: Cancel reverts draft to last saved value.
                            if !draftSaved {
                                Button(L("キャンセル", "Cancel")) {
                                    draftCustom = pref.customPrompt
                                    draftSaved = true
                                    statusMessage = nil
                                }
                                .controlSize(.small)
                            }

                            Button(L("空テンプレートにリセット", "Reset to empty template")) {
                                draftCustom = PromptPreference.defaultCustomTemplate
                                pref.customPrompt = draftCustom
                                draftSaved = true
                                statusMessage = L("リセット", "Reset")
                            }
                            .controlSize(.small)

                            Button(L("標準から読み込む", "Load the default")) {
                                let seed = OrganizeService.previewPrompt(for: .standard)
                                    .replacingOccurrences(of: "{{ あなたのノート本文がここに入ります }}", with: "\\(text)")
                                draftCustom = seed
                                pref.customPrompt = seed
                                draftSaved = true
                                statusMessage = L("標準プロンプトを読み込みました", "Loaded the default prompt")
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
                        Text(L("選択中のプリセットで AI に実際に送られるプロンプトです。下にスクロールすると全文を確認できます。", "The actual prompt sent to AI for the selected preset. Scroll down to see full text."))
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
    @State private var backgroundImportError: String?
    @State private var makerDraft: ThemeMakerDraft?
    @Bindable private var appearance = AppearanceSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("外観", "Appearance"))
                .font(.system(size: 18, weight: .bold))

            // S3: テーマ gallery — leading「ノートごと（自動）」= appTheme nil
            // (each note keeps its own hue), then the curated specs.
            // S14: grouped light / dark (isDarkTheme) so the grid scales.
            // S16: the editor FAMILY gets its own labeled group — the
            // syntax-preview swatches sell what these themes are (the
            // slots are the identity), instead of hiding them among the
            // dark pastels.
            settingsGroup(title: L("テーマ", "Theme")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("全ノート共通のテーマ。「ノートごと」を選ぶと付箋ごとに色が変わります。", "One theme for every note. ノートごと gives each sticky its own hue."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    let paperSpecs = FloteThemeRegistry.allSpecs.filter { $0.family == .paper }
                    let editorSpecs = FloteThemeRegistry.allSpecs.filter { $0.family == .editor }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        themeCard(spec: nil)
                        ForEach(paperSpecs.filter { !$0.isDarkTheme }) { spec in
                            themeCard(spec: spec)
                        }
                    }
                    Text(L("ダーク", "Dark"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(paperSpecs.filter { $0.isDarkTheme }) { spec in
                            themeCard(spec: spec)
                        }
                    }
                    Text(L("エディタ", "Editor"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(L("構文の色が主役のテーマ。キーワード・変数・答えが自動で色分けされ、等幅フォントで表示されます。",
                           "Themes where the syntax colors are the star — keywords, variables and answers color themselves, in a monospaced face."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(editorSpecs) { spec in
                            themeCard(spec: spec)
                        }
                    }

                    // S15: user-created themes (Theme Maker). Same card and
                    // selection behavior as built-ins — the data lives in
                    // FloteCustomThemeStore, not in code.
                    let customs = FloteCustomThemeStore.shared.themes
                    if !customs.isEmpty {
                        Text(L("カスタム", "Custom"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                            ForEach(customs) { custom in
                                themeCard(spec: custom.spec)
                                    .contextMenu {
                                        Button(L("編集…", "Edit…")) {
                                            makerDraft = ThemeMakerDraft(theme: custom, isNew: false)
                                        }
                                        Button(L("削除", "Delete"), role: .destructive) {
                                            FloteCustomThemeStore.shared.delete(id: custom.id)
                                        }
                                    }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            makerDraft = ThemeMakerDraft(theme: Self.newDraftTheme(), isNew: true)
                        } label: {
                            Label(L("テーマを作る", "Make a theme"), systemImage: "paintpalette")
                                .font(.system(size: 11))
                        }
                        if !customs.isEmpty {
                            Text(L("カスタムテーマは右クリックで編集・削除できます",
                                   "Right-click a custom theme to edit or delete it"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            settingsGroup(title: L("質感", "Texture")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("すりガラス効果（背景が透ける）", "Frosted glass (desktop shows through)"), isOn: $appearance.useVibrancy)
                        .font(.system(size: 12))
                    // S16: slider spans the DESIGNED range constant
                    // (0.3–1.0; was a hardcoded 0.7 floor that made the
                    // control barely matter). 30% is the legibility
                    // floor — see AppearanceSettings.panelOpacityRange.
                    HStack(spacing: 10) {
                        Text(L("透明度", "Opacity"))
                            .font(.system(size: 12))
                        Slider(value: $appearance.panelOpacity,
                               in: AppearanceSettings.panelOpacityRange)
                        Text("\(Int(appearance.panelOpacity * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Text(L("紙", "Paper"))
                            .font(.system(size: 12))
                        ForEach(PaperType.allCases, id: \.self) { paper in
                            paperCard(paper)
                        }
                    }
                    HStack(spacing: 10) {
                        Text(L("線の濃さ", "Line strength"))
                            .font(.system(size: 12))
                        Slider(value: $appearance.paperStrength,
                               in: AppearanceSettings.paperStrengthRange)
                            .disabled(appearance.paperType == .blank)
                        Text(String(format: "%.1fx", appearance.paperStrength))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    // S7-3 角丸: app-level, applied outside animations only.
                    HStack(spacing: 10) {
                        Text(L("角丸", "Corners"))
                            .font(.system(size: 12))
                        Slider(value: $appearance.cornerRadius,
                               in: AppearanceSettings.cornerRadiusRange)
                        Text("\(Int(appearance.cornerRadius))pt")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                        RoundedRectangle(cornerRadius: appearance.cornerRadius * 0.66,
                                         style: .continuous)
                            .fill(Color(red: 0.998, green: 0.985, blue: 0.945))
                            .overlay(RoundedRectangle(
                                cornerRadius: appearance.cornerRadius * 0.66,
                                style: .continuous)
                                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                            .frame(width: 44, height: 28)
                    }
                    // S3c: surface material axis (standard / washi / metal / glass).
                    HStack(spacing: 8) {
                        Text(L("素材", "Material"))
                            .font(.system(size: 12))
                        ForEach(SurfaceMaterial.allCases) { material in
                            materialCard(material)
                        }
                    }
                    // S3c: custom photo background.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(L("背景写真", "Background photo"))
                                .font(.system(size: 12))
                            if let photo = appearance.customBackgroundImage {
                                Image(nsImage: photo)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 52, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                                    )
                            }
                            Button(L("選ぶ…", "Choose…")) { pickBackgroundPhoto() }
                                .font(.system(size: 11))
                            if appearance.customBackgroundFileName != nil {
                                Button(L("削除", "Remove")) {
                                    appearance.removeCustomBackground()
                                }
                                .font(.system(size: 11))
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 10) {
                            Text(L("減光", "Dimming"))
                                .font(.system(size: 12))
                            Slider(value: $appearance.customBackgroundDimming,
                                   in: AppearanceSettings.customBackgroundDimmingRange)
                                .disabled(appearance.customBackgroundFileName == nil)
                            Text("\(Int(appearance.customBackgroundDimming * 100))%")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        if let error = backgroundImportError {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            settingsGroup(title: L("フォント", "Font")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("ノート本文と、巻き上げた付箋のタイトルに使われます。", "Used for note body text and the rolled-up scroll title."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker(L("フォント", "Font family"), selection: $selected) {
                        ForEach(AppFont.allCases) { font in
                            Text(font.displayName).tag(font)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: selected) { _, new in
                        FontPreference.shared.current = new
                    }

                    // Text size (font-controls contract): global body size,
                    // same store the ⌘+/⌘− shortcuts drive. Range mirrors
                    // FloteTextSize (9-18, 11 default).
                    HStack(spacing: 10) {
                        Text(L("文字サイズ", "Text size"))
                            .font(.system(size: 12))
                        Stepper(
                            value: Binding(
                                get: { FontPreference.shared.bodySize },
                                set: { FontPreference.shared.bodySize = $0 }
                            ),
                            in: FloteTextSize.minSize...FloteTextSize.maxSize,
                            step: 1
                        ) {
                            Text("\(Int(FontPreference.shared.bodySize)) pt")
                                .font(.system(size: 12).monospacedDigit())
                        }
                        Text(L("⌘+ / ⌘− でも変更できます", "Also ⌘+ / ⌘−"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Text(L("プレビュー", "Preview"))
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
        // S15 Theme Maker editor. `.sheet(item:)` drives both create (fresh
        // draft id) and edit (existing id) with one code path.
        .sheet(item: $makerDraft) { draft in
            ThemeMakerSheet(
                draft: draft,
                onSave: { theme in
                    if FloteCustomThemeStore.shared.upsert(theme), draft.isNew {
                        // A freshly MADE theme applies immediately — the
                        // payoff is visible on the notes the moment the
                        // sheet closes. Editing never steals the selection.
                        appearance.appTheme = theme.id
                    }
                },
                onDelete: draft.isNew ? nil : {
                    FloteCustomThemeStore.shared.delete(id: draft.theme.id)
                })
        }
    }

    /// Fresh Theme Maker draft — starts from the porcelain family, a clean
    /// slate that already clears every contrast floor, so the first thing a
    /// user sees is a PASSING readout (the gate teaches by example, it
    /// never greets with red marks).
    private static func newDraftTheme() -> FloteCustomTheme {
        FloteCustomTheme(
            name: "",
            background: .rgb(0.972, 0.970, 0.962),
            toolbar:    .rgb(0.928, 0.926, 0.916),
            text:       .rgb(0.168, 0.176, 0.190),
            accent:     .rgb(0.290, 0.400, 0.680))
    }

    // MARK: - S3 theme / paper cards

    /// One tappable theme swatch. `spec == nil` = ノートごと（自動）.
    @ViewBuilder
    private func themeCard(spec: FloteThemeSpec?) -> some View {
        let isSelected = appearance.appTheme == spec?.id
        let palette = spec?.palette(dark: false)
        Button {
            appearance.appTheme = spec?.id
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette?.background.color ?? Color(nsColor: .windowBackgroundColor))
                    // S14: preview the theme's recommended paper (advisory
                    // data — selecting the theme never changes the user's
                    // paper setting). Blank draws nothing.
                    if let spec, let palette, spec.recommendedPaper != .blank {
                        PaperPatternView(type: spec.recommendedPaper,
                                         ink: palette.text.color,
                                         patternOpacity: 0.22,
                                         spacingOverride: 11)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if let spec, let palette, spec.family == .editor {
                        // S16: editor-family swatch = a mini syntax
                        // preview (keyword line / variable line / answer
                        // line), monospaced — the slots ARE the theme's
                        // identity, so the swatch shows them doing their
                        // real jobs, Antinote-LP style.
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(verbatim: "math")
                                .foregroundColor(palette.resolvedKeyword.color)
                            (Text(verbatim: "x").foregroundColor(palette.resolvedVariableDef.color)
                             + Text(verbatim: ": 8×12").foregroundColor(palette.text.color))
                            (Text(verbatim: "x").foregroundColor(palette.resolvedVariableUse.color)
                             + Text(verbatim: " = ").foregroundColor(palette.text.color.opacity(0.65))
                             + Text(verbatim: "96").foregroundColor(palette.resolvedCalcAnswer.color))
                        }
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if let palette {
                        VStack(spacing: 3) {
                            Capsule().fill(palette.toolbar.color).frame(height: 6)
                            HStack(spacing: 3) {
                                Circle().fill(palette.accent.color).frame(width: 7, height: 7)
                                Capsule().fill(palette.text.color.opacity(0.55)).frame(height: 4)
                            }
                        }
                        .padding(8)
                    } else {
                        // ノートごと: a mini rainbow of the classic pastels.
                        HStack(spacing: 2) {
                            ForEach(["yellow", "pink", "blue", "green"], id: \.self) { raw in
                                Circle()
                                    .fill(FloteThemeRegistry.specForLegacy(raw).palette(dark: false).background.color)
                                    .frame(width: 9, height: 9)
                            }
                        }
                    }
                }
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? floteAccent : Color.black.opacity(0.08),
                                      lineWidth: isSelected ? 2 : 1)
                )
                Text(spec.map { FloteL10n.shared.language == "ja" ? $0.nameJP : $0.nameEN } ?? L("ノートごと（自動）", "Per note (auto)"))
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// One tappable surface-material swatch. The preview renders the real
    /// `MaterialOverlayView` at boosted intensity (a 52x36 swatch cannot
    /// communicate a 3%-opacity texture at true strength) over the classic
    /// yellow pastel, so what you pick is what the note gets.
    @ViewBuilder
    private func materialCard(_ material: SurfaceMaterial) -> some View {
        let isSelected = appearance.surfaceMaterial == material
        Button {
            appearance.surfaceMaterial = material
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(FloteThemeRegistry.fallbackSpec
                            .palette(dark: false).background.color)
                    MaterialOverlayView(material: material, intensity: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(width: 52, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? floteAccent : Color.black.opacity(0.08),
                                      lineWidth: isSelected ? 2 : 1)
                )
                Text(FloteL10n.shared.language == "ja"
                     ? material.displayNameJP : material.displayNameEN)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    /// NSOpenPanel → copy into Application Support during the grant.
    /// Import failures surface inline under the 背景写真 row; note data is
    /// never touched by any path in here.
    private func pickBackgroundPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("ノートの背景に使う写真を選択", "Choose a photo for the note background")
        panel.prompt = L("設定", "Set")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try AppearanceSettings.shared.setCustomBackground(from: url)
            backgroundImportError = nil
        } catch {
            backgroundImportError =
                L("写真を読み込めませんでした", "Could not load the photo") + "（\(error.localizedDescription)）"
        }
    }

    /// One tappable paper-pattern swatch.
    @ViewBuilder
    private func paperCard(_ paper: PaperType) -> some View {
        let isSelected = appearance.paperType == paper
        Button {
            appearance.paperType = paper
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.998, green: 0.985, blue: 0.945))
                    PaperPatternView(type: paper,
                                     ink: Color(red: 0.22, green: 0.18, blue: 0.14),
                                     patternOpacity: 0.35)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(width: 52, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? floteAccent : Color.black.opacity(0.08),
                                      lineWidth: isSelected ? 2 : 1)
                )
                Text(FloteL10n.shared.language == "ja"
                     ? paper.displayNameJP : paper.displayNameEN)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Theme Maker (S15)

/// Editable working copy for the Theme Maker sheet. Identifiable so
/// `.sheet(item:)` drives create (fresh id) and edit (existing id) alike.
private struct ThemeMakerDraft: Identifiable {
    var theme: FloteCustomTheme
    var isNew: Bool
    var id: String { theme.id }
}

/// The Theme Maker editor: name, the FOUR core colors, a live note mock,
/// and a live contrast readout against the S14 floors. SAVE stays disabled
/// while any floor fails — the machine gate IS the design assistant, so an
/// unreadable theme can never leave this sheet.
private struct ThemeMakerSheet: View {
    @State private var theme: FloteCustomTheme
    private let isNew: Bool
    private let onSave: (FloteCustomTheme) -> Void
    private let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(draft: ThemeMakerDraft,
         onSave: @escaping (FloteCustomTheme) -> Void,
         onDelete: (() -> Void)?) {
        _theme = State(initialValue: draft.theme)
        self.isNew = draft.isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    // Live floor readouts — the same pure functions the store re-checks at
    // save time (and the s15 harness audits), so UI and gate cannot drift.
    private var textOnBackground: Double {
        FloteCustomThemeGate.textOnBackground(text: theme.text, background: theme.background)
    }
    private var textOnToolbar: Double {
        FloteCustomThemeGate.textOnToolbar(text: theme.text, toolbar: theme.toolbar)
    }
    private var accentOnBackground: Double {
        FloteCustomThemeGate.accentOnBackground(accent: theme.accent, background: theme.background)
    }
    private var gatePasses: Bool { FloteCustomThemeGate.passes(theme) }
    private var nameOK: Bool {
        !theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? L("テーマを作る", "Make a Theme") : L("テーマを編集", "Edit Theme"))
                .font(.system(size: 15, weight: .semibold))

            TextField(L("テーマ名", "Theme name"), text: $theme.name)
                .textFieldStyle(.roundedBorder)

            preview

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ColorPicker(L("背景", "Background"),
                                selection: colorBinding(\.background), supportsOpacity: false)
                    ColorPicker(L("文字", "Text"),
                                selection: colorBinding(\.text), supportsOpacity: false)
                }
                GridRow {
                    ColorPicker(L("ツールバー", "Toolbar"),
                                selection: colorBinding(\.toolbar), supportsOpacity: false)
                    ColorPicker(L("アクセント", "Accent"),
                                selection: colorBinding(\.accent), supportsOpacity: false)
                }
            }
            .font(.system(size: 12))

            HStack(spacing: 10) {
                Text(L("紙（推奨）", "Paper"))
                    .font(.system(size: 12))
                Picker("", selection: $theme.recommendedPaper) {
                    ForEach(PaperType.allCases) { paper in
                        Text(FloteL10n.shared.language == "ja"
                             ? paper.displayNameJP : paper.displayNameEN).tag(paper)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Live contrast readout — the S14 floors, judged in real time.
            VStack(alignment: .leading, spacing: 6) {
                contrastRow(L("文字 × 背景", "Text × Background"),
                            value: textOnBackground,
                            floor: FloteCustomThemeGate.textFloor)
                contrastRow(L("文字 × ツールバー", "Text × Toolbar"),
                            value: textOnToolbar,
                            floor: FloteCustomThemeGate.textFloor)
                contrastRow(L("アクセント × 背景", "Accent × Background"),
                            value: accentOnBackground,
                            floor: FloteCustomThemeGate.accentFloor)
                if !gatePasses {
                    Text(L("コントラスト基準（WCAG）を満たすと保存できます。読めないテーマは作れない設計です。",
                           "Save unlocks once every contrast floor (WCAG) passes — the gate keeps every theme readable."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.04))
            )

            HStack {
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Text(L("削除", "Delete"))
                    }
                }
                Spacer()
                Button(L("キャンセル", "Cancel")) { dismiss() }
                Button(L("保存", "Save")) {
                    var saved = theme
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!gatePasses || !nameOK)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// Live mini note mock: toolbar strip, body ink over the background
    /// (with the recommended paper), a checkbox line, and a calc line whose
    /// answer renders in accent — the four slots doing their real jobs.
    private var preview: some View {
        let palette = theme.spec.palette(dark: false)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(palette.text.color.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(nameOK ? theme.name : L("マイテーマ", "My Theme"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.text.color.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(palette.toolbar.color)

            ZStack(alignment: .topLeading) {
                palette.background.color
                if theme.recommendedPaper != .blank {
                    PaperPatternView(type: theme.recommendedPaper,
                                     ink: palette.text.color,
                                     patternOpacity: 0.16,
                                     spacingOverride: 15)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("あのイーハトーヴォのすきとおった風", "The quick brown fox jumps over"))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.text.color)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(palette.accent.color)
                            .frame(width: 10, height: 10)
                        Text(L("牛乳を買う", "Buy milk"))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.text.color)
                    }
                    (Text("120 + 80 ").foregroundColor(palette.text.color)
                     + Text("= 200").foregroundColor(palette.accent.color))
                        .font(.system(size: 11).monospacedDigit())
                }
                .padding(10)
            }
            .frame(height: 88)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
        )
    }

    private func contrastRow(_ label: String, value: Double, floor: Double) -> some View {
        let pass = value >= floor
        return HStack(spacing: 8) {
            Image(systemName: pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(pass ? Color.green : Color.red)
            Text(label)
                .font(.system(size: 11))
            Spacer()
            Text(String(format: "%.1f:1", value))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(pass ? Color.primary : Color.red)
            Text(String(format: "≥ %.1f", floor))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// Two-way bridge: SwiftUI `ColorPicker` ↔ the theme's portable
    /// `FloteColorValue` slots, converting through explicit sRGB. A color
    /// the picker hands back that cannot convert (never for concrete picks)
    /// is dropped — the slot keeps its last valid value.
    private func colorBinding(
        _ keyPath: WritableKeyPath<FloteCustomTheme, FloteColorValue>
    ) -> Binding<Color> {
        Binding(
            get: { theme[keyPath: keyPath].color },
            set: { newColor in
                guard let srgb = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                theme[keyPath: keyPath] = FloteColorValue(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent))
            })
    }
}

enum SettingsSection: String, CaseIterable {
    case groups, general, appearance, ai, prompt, notes, history, backup, shortcuts, about

    // N9: section titles in Japanese. Technical/brand terms (AI, FLOTE, Prompt,
    // API key etc.) remain in English per spec.
    @MainActor
    var title: String {
        switch self {
        case .groups:     return L("グループ", "Groups")
        case .general:    return L("一般", "General")
        case .appearance: return L("外観", "Appearance")
        case .ai:         return L("AI 整理", "AI Organize")
        case .prompt:     return L("プロンプト", "Prompt")
        case .notes:      return L("ノート", "Notes")
        case .history:    return L("最近削除", "Recently Deleted")
        case .backup:     return L("バックアップ", "Backup")
        case .shortcuts:  return L("ショートカット", "Shortcuts")
        case .about:      return L("このアプリについて", "About")
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
        case .backup:     return "externaldrive"
        case .shortcuts:  return "command"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - General

private struct GeneralSettingsSection: View {
    // S6c: default ON — same semantics as NoteManager.sinkCompletedEnabled.
    @State private var sinkCompleted = NoteManager.sinkCompletedEnabled

    // S9 (§12 paste strip): mirrors FlotePastePrefs — state here only so
    // the sub-toggles can visually disable when the master switch is off.
    @State private var pasteStripAttributes = FlotePastePrefs.stripAttributesEnabled
    @State private var pasteStripIndent = FlotePastePrefs.bool(
        FlotePastePrefs.stripIndentKey, defaultOn: true)
    @State private var pasteCollapseBlankLines = FlotePastePrefs.bool(
        FlotePastePrefs.collapseBlankLinesKey, defaultOn: true)
    @State private var pasteStripListMarkers = FlotePastePrefs.bool(
        FlotePastePrefs.stripListMarkersKey, defaultOn: false)
    @State private var pasteStripMarkdown = FlotePastePrefs.bool(
        FlotePastePrefs.stripMarkdownKey, defaultOn: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("一般", "General"))
                .font(.system(size: 18, weight: .bold))

            settingsGroup(title: L("起動時", "At launch")) {
                Text(L("起動時、ノートは常に展開された状態で開きます。", "Notes start in expanded state on each launch."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            settingsGroup(title: L("言語", "Language")) {
                Picker(selection: Binding(
                    get: { FloteL10n.shared.language },
                    set: { FloteL10n.shared.set($0) }
                )) {
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("アプリの表示言語", "App display language"))
                            .font(.system(size: 12))
                        Text(L("メニューやボタンの言語です。ノートの中身には影響しません。", "Menus and buttons only — your note content is untouched."))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260, alignment: .leading)
            }

            settingsGroup(title: L("ノートのサイズ", "Note size")) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(selection: Binding(
                        get: { FloatingPanel.SizePreset.current.rawValue },
                        set: {
                            UserDefaults.standard.set($0, forKey: FloatingPanel.SizePreset.defaultsKey)
                            PanelManager.shared.applySizePreset()
                        }
                    )) {
                        ForEach(FloatingPanel.SizePreset.allCases, id: \.rawValue) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    } label: {
                        Text(L("新しいノートと、手動リサイズしていないノートに適用されます",
                               "Applies to new notes and notes you haven't resized by hand"))
                            .font(.system(size: 12))
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360, alignment: .leading)
                    Text(L("ノートは端をドラッグして自由な大きさにもできます。",
                           "You can also drag any note's edges to any size you like."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            settingsGroup(title: L("呼び出し", "Summoning")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { HotkeyService.dockModeEnabled },
                        set: {
                            UserDefaults.standard.set($0, forKey: HotkeyService.dockModeKey)
                            HotkeyService.applyDockMode()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Dock にアイコンを表示", "Show Dock icon"))
                                .font(.system(size: 12))
                            Text(L("オフのときはメニューバー常駐のみです", "When off, Flote lives only in the menu bar"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Picker(selection: Binding(
                        get: { HotkeyService.hotCorner },
                        set: {
                            UserDefaults.standard.set($0, forKey: HotkeyService.hotCornerKey)
                            HotkeyService.shared.applyHotCorner()
                        }
                    )) {
                        Text(L("なし", "Off")).tag("")
                        Text(L("左上", "Top left")).tag("tl")
                        Text(L("右上", "Top right")).tag("tr")
                        Text(L("左下", "Bottom left")).tag("bl")
                        Text(L("右下", "Bottom right")).tag("br")
                    } label: {
                        Text(L("ホットコーナーで新規ノート", "Hot corner creates a note"))
                            .font(.system(size: 12))
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                }
            }

            settingsGroup(title: L("新規ノート", "New notes")) {
                Toggle(isOn: Binding(
                    get: { NoteManager.newNoteFocusEnabled },
                    set: { UserDefaults.standard.set($0, forKey: NoteManager.newNoteFocusKey) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("すぐ入力できる状態で開く", "Start ready to type"))
                            .font(.system(size: 12))
                        Text(L("⌥Space やメニューバーから作った瞬間にキーボードが移ります", "Creating via ⌥Space or the menu bar moves the keyboard to the new note"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            settingsGroup(title: L("電卓", "Calculator")) {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "floteInlineCalc") == nil
                            || UserDefaults.standard.bool(forKey: "floteInlineCalc") },
                    set: { UserDefaults.standard.set($0, forKey: "floteInlineCalc") }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("= で計算する", "Calculate on ="))
                            .font(.system(size: 12))
                        Text(L("「3*480=」と打つと結果が続きます（⌘Z で取り消し）", "Type 3*480= and the result follows (undo with ⌘Z)"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            settingsGroup(title: L("ペースト", "Paste")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $pasteStripAttributes) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("書式を除去して貼り付け（⌘V）", "Paste as clean text (⌘V)"))
                                .font(.system(size: 12))
                            Text(L("Web や Word の色・フォントを持ち込まず、ノートの文字設定で貼り付けます。⌘⇧V はそのまま貼り付け。",
                                   "Pasted text adopts the note's own type — no alien fonts or colors from the web or Word. ⌘⇧V pastes as-is."))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: pasteStripAttributes) { _, v in
                        UserDefaults.standard.set(v, forKey: FlotePastePrefs.stripAttributesKey)
                    }

                    Group {
                        Toggle(L("行頭のインデントを除去", "Strip leading indentation"),
                               isOn: $pasteStripIndent)
                            .onChange(of: pasteStripIndent) { _, v in
                                UserDefaults.standard.set(v, forKey: FlotePastePrefs.stripIndentKey)
                            }
                        Toggle(L("連続する空行を 1 行に詰める", "Collapse extra blank lines"),
                               isOn: $pasteCollapseBlankLines)
                            .onChange(of: pasteCollapseBlankLines) { _, v in
                                UserDefaults.standard.set(v, forKey: FlotePastePrefs.collapseBlankLinesKey)
                            }
                        Toggle(L("箇条書き記号を除去（- * • ・ 1.）", "Strip list markers (- * • ・ 1.)"),
                               isOn: $pasteStripListMarkers)
                            .onChange(of: pasteStripListMarkers) { _, v in
                                UserDefaults.standard.set(v, forKey: FlotePastePrefs.stripListMarkersKey)
                            }
                        Toggle(L("Markdown 記法を除去（**太字** など）", "Strip Markdown syntax (**bold** etc.)"),
                               isOn: $pasteStripMarkdown)
                            .onChange(of: pasteStripMarkdown) { _, v in
                                UserDefaults.standard.set(v, forKey: FlotePastePrefs.stripMarkdownKey)
                            }
                    }
                    .font(.system(size: 12))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!pasteStripAttributes)

                    Text(L("[テキスト](URL) はテキストだけを残します。リンク先ごと貼りたいときは ⌘⇧V。",
                           "[text](url) keeps the text and drops the URL. Use ⌘⇧V when you want everything verbatim."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            settingsGroup(title: L("チェックリスト", "Checklists")) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L("完了した項目を下に移動", "Sink completed items"), isOn: $sinkCompleted)
                        .font(.system(size: 12))
                        .onChange(of: sinkCompleted) { _, newValue in
                            UserDefaults.standard.set(
                                newValue, forKey: NoteManager.sinkCompletedKey
                            )
                        }
                    Text(L("チェックを付けた項目は、少し置いてからノートの下部へ移動します。", "Checked items settle to the bottom of the note after a beat."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            settingsGroup(title: L("履歴", "History")) {
                Text(L("直近 20 件の削除済みノートをメニューバーから復元できます。", "The last 20 deleted notes can be restored from the menu bar."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - AI

/// S1: status + controls for the zero-setup on-device AI chain
/// (Apple Foundation Models → bundled Qwen). This is the default Organize
/// path; the legacy Claude/Ollama groups below are the optional tail.
private struct OnDeviceAISection: View {
    @Bindable private var modelStore = LocalModelStore.shared
    @State private var appleFMStatus: String = "…"
    @State private var appleFMAvailable = false

    var body: some View {
        settingsGroup(title: L("オンデバイス AI（設定不要）", "On-device AI (zero setup)")) {
            VStack(alignment: .leading, spacing: 10) {
                // Apple Foundation Models row
                HStack(spacing: 8) {
                    Circle()
                        .fill(appleFMAvailable ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(L("Apple Intelligence（macOS 26 内蔵）", "Apple Intelligence (built into macOS 26)"))
                        .font(.system(size: 12))
                    Spacer()
                    Text(appleFMStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Bundled local model row
                HStack(spacing: 8) {
                    Circle()
                        .fill(modelStore.isReady ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(L("内蔵ローカル AI（Qwen 2.5・約 1GB）", "Bundled local AI (Qwen 2.5, ~1 GB)"))
                        .font(.system(size: 12))
                    Spacer()
                    localModelControls
                }

                Text(L("どちらかが有効なら Organize は完全に端末内で動きます。両方使えない場合のみ、下のオプション（Claude キー / Ollama）が使われます。", "With either available, Organize runs entirely on this Mac. The Claude key / Ollama options below are used only when neither works."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Text(L("内蔵ローカル AI: Qwen2.5-1.5B-Instruct（Apache License 2.0, © Alibaba Cloud）", "Bundled local AI: Qwen2.5-1.5B-Instruct (Apache License 2.0, © Alibaba Cloud)"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .task {
            if let fm = FoundationModelsProviderFactory.make() {
                switch await fm.availability() {
                case .available:
                    appleFMAvailable = true
                    appleFMStatus = L("利用可能", "Available")
                case .unavailable(let reason):
                    appleFMStatus = reason.description
                }
            } else {
                appleFMStatus = L("macOS 26 以降で利用できます", "Available on macOS 26+")
            }
        }
    }

    @ViewBuilder
    private var localModelControls: some View {
        #if arch(arm64)
        switch modelStore.state {
        case .notDownloaded:
            Button(L("ダウンロード", "Download")) { modelStore.startDownload() }
                .font(.system(size: 11))
        case .downloading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 90)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("キャンセル", "Cancel")) { modelStore.cancelDownload() }
                    .font(.system(size: 11))
            }
        case .ready:
            HStack(spacing: 8) {
                Text(L("利用可能", "Available"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button(L("削除", "Remove")) { modelStore.deleteModel() }
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Text(L("失敗: ", "Failed: ") + message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Button(L("再試行", "Retry")) { modelStore.startDownload() }
                    .font(.system(size: 11))
            }
        }
        #else
        Text(L("Apple Silicon 専用", "Apple Silicon only"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        #endif
    }
}

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

            Text(L("整理はこの Mac の中の AI が行います（設定不要・ノートは端末から出ません）。下の Claude / Ollama は上級者向けのオプションです。", "Organize runs on this Mac — zero setup, notes never leave the device. Claude / Ollama below are power-user options."))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            OnDeviceAISection()

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
                        Button(L("Keychain に保存", "Save to Keychain")) {
                            saveAPIKey()
                        }
                        .disabled(apiKey.isEmpty)

                        if hasSavedKey {
                            // N6: re-check hasSavedKey on button actions.
                            Button(L("削除", "Remove")) { removeAPIKey() }
                                .foregroundColor(.red)
                        }

                        Spacer()

                        if let msg = statusMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(L("console.anthropic.com でキーを取得。macOS Keychain に安全に保存されます。", "Get a key at console.anthropic.com. Stored securely in the macOS Keychain."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(L("ペースト後はクリップボードを別の内容で上書きすることをおすすめします。", "After pasting, consider overwriting your clipboard."))
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
                        Button(L("URL を保存", "Save URL")) {
                            saveOllamaURL()
                        }

                        // M8-1: Ollama 接続テストボタン。
                        Button(L("接続テスト", "Test connection")) {
                            checkOllamaReachability()
                        }

                        if let st = ollamaStatus {
                            Text(st)
                                .font(.system(size: 11))
                                .foregroundStyle(ollamaStatusIsError ? Color.red : Color.green)
                        }
                    }

                    Text(L("200文字未満のノートに使用。Ollama がローカルで動作している場合はデフォルトのままでOKです。", "Used for notes under 200 chars. Defaults are fine when Ollama runs locally."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    // Track-3 2026-05-12: warn the user when a non-loopback host is in the field.
                    if OrganizeService.requiresRemoteOptIn(urlString: ollamaURL) {
                        Text(L("注意: ローカル以外の Ollama サーバーに接続するとノート本文がネットワーク経由で送信されます。保存時に確認が表示されます。", "Note: a non-local Ollama server receives your note text over the network. You will be asked to confirm."))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                }
            }

            DiagnosticLogSection()
        }
        .onAppear {
            // N6: re-check Keychain presence every time the section appears.
            // hasAPIKey (metadata-only) — a secret read here modal-froze the
            // whole Settings window behind a keychain password dialog.
            hasSavedKey = KeychainHelper.hasAPIKey()
        }
        // N6: also re-check when the Settings window regains key status, so
        // external Keychain removals (e.g. Keychain Access app) are reflected.
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in
            hasSavedKey = KeychainHelper.hasAPIKey()
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
        .alert(L("APIキーが保存されていません", "API key not saved"), isPresented: $showUnsavedKeyAlert) {
            Button(L("保存", "Save")) { saveAPIKey() }
            Button(L("破棄", "Discard"), role: .destructive) {
                apiKey = ""
                apiKeyDirty = false
            }
        } message: {
            Text(L("入力されたAPIキーはまだ Keychain に保存されていません。保存しますか？", "The entered API key is not in the Keychain yet. Save it?"))
        }
        // Track-3 2026-05-12: opt-in confirmation for non-loopback Ollama URL.
        .alert(L("リモートの Ollama サーバーに接続しますか？", "Connect to a remote Ollama server?"), isPresented: $showRemoteOllamaConfirm) {
            Button(L("キャンセル", "Cancel"), role: .cancel) {
                pendingRemoteOllamaURL = ""
            }
            Button(L("接続する", "Connect"), role: .destructive) {
                // Persist opt-in flag + the URL. Opt-in is sticky until the
                // user explicitly clears it (by switching back to a loopback
                // URL and saving), so we don't re-prompt on every change.
                UserDefaults.standard.set(true, forKey: OrganizeService.remoteOllamaOptInKey)
                UserDefaults.standard.set(pendingRemoteOllamaURL, forKey: OrganizeService.ollamaURLKey)
                ollamaURL = pendingRemoteOllamaURL
                statusMessage = L("リモート Ollama URL を保存しました (要再起動の可能性あり)", "Saved remote Ollama URL (may need a relaunch)")
                pendingRemoteOllamaURL = ""
            }
        } message: {
            Text(L("入力された URL は端末外のサーバーです (\(pendingRemoteOllamaURL))。Organize 実行時にノート本文がそのサーバーへ送信されます。続行しますか？", "This URL is outside this Mac (\(pendingRemoteOllamaURL)). Organize will send note text to that server. Continue?"))
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
        statusMessage = L("URL を保存しました", "URL saved")
    }

    // M8-1: Ollama /api/tags への接続テスト。
    private func checkOllamaReachability() {
        // Derive base URL from the generate endpoint (strip /api/generate suffix).
        var base = ollamaURL
        if let range = base.range(of: "/api/generate") {
            base = String(base[..<range.lowerBound])
        }
        guard let url = URL(string: "\(base)/api/tags") else {
            ollamaStatus = L("URL が無効です", "Invalid URL")
            ollamaStatusIsError = true
            return
        }
        ollamaStatus = L("確認中...", "Checking…")
        ollamaStatusIsError = false
        Task {
            do {
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "GET"
                let (_, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    if (200..<300).contains(code) {
                        ollamaStatus = L("接続成功 (HTTP \(code))", "Connected (HTTP \(code))")
                        ollamaStatusIsError = false
                    } else {
                        ollamaStatus = L("エラー (HTTP \(code))", "Error (HTTP \(code))")
                        ollamaStatusIsError = true
                    }
                }
            } catch {
                await MainActor.run {
                    ollamaStatus = L("接続失敗: ", "Connection failed: ") + error.localizedDescription
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
            statusMessage = L("警告: キーの形式が正しくない可能性があります (sk-ant- が必要)", "Warning: the key format looks wrong (sk-ant- expected)")
            // Still attempt to save so the user can correct it via Settings later.
        }

        if KeychainHelper.saveAPIKey(trimmed) {
            // Read-back verification: confirm the saved value can be retrieved.
            // This catches Keychain ACL errors or service-name mismatches that
            // silently succeed on write but fail on read at Organize time (M8).
            if let readBack = KeychainHelper.readAPIKey(), readBack == trimmed {
                if looksValid {
                    statusMessage = L("保存完了", "Saved")
                }
                // (if !looksValid, statusMessage already shows warning above)
                hasSavedKey = true
                apiKey = ""
                apiKeyDirty = false   // N5: clear dirty flag after successful save.
            } else {
                statusMessage = L("Keychain 検証失敗 — アクセス権限を確認してください", "Keychain verification failed — check access permissions")
                hasSavedKey = false
            }
        } else {
            statusMessage = L("保存失敗", "Save failed")
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
                    Text(L("直近のエラー履歴（最大 20 件）", "Recent errors (up to 20)"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button(L("クリア", "Clear")) {
                        service.clearRecentErrors()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                if service.recentErrors.isEmpty {
                    Text(L("エラーなし", "No errors"))
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
                Text(L("ノート", "Notes"))
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    let note = manager.createNote()
                    PanelManager.shared.createPanel(for: note, focus: true)
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
                Text(L("最近削除した項目", "Recently Deleted"))
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                if !manager.history.isEmpty {
                    Button(L("すべてクリア", "Clear all"), role: .destructive) {
                        showClearConfirm = true
                    }
                    .controlSize(.small)
                }
            }

            Text(L("削除したノートは30日間ここに残り、その後自動的に完全削除されます。「Restore」でアクティブなノートとして復元できます。", "Deleted notes stay here for 30 days, then are purged. Restore brings one back as an active note."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if manager.history.isEmpty {
                emptyState(
                    icon: "clock.arrow.circlepath",
                    message: L("最近削除したノートはありません。", "No recently deleted notes.")
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
        .confirmationDialog(L("最近削除した項目をすべて消去しますか？", "Erase all recently deleted items?"),
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button(L("すべて消去", "Erase all"), role: .destructive) {
                manager.clearHistory()
            }
            Button(L("キャンセル", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("\(manager.history.count) 件のノートが完全に削除されます。この操作は取り消せません。", "\(manager.history.count) notes will be permanently deleted. This cannot be undone."))
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
                // S2: show WHEN the note was deleted (deletedAt), not when it
                // was last edited. Legacy-seeded entries fall back to
                // modifiedAt (migration stamped deletedAt = modifiedAt anyway).
                Text(L("削除: ", "Deleted: ") + relativeTimestamp(entry.deletedAt ?? entry.modifiedAt))
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
                    Text(L("復元", "Restore"))
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

// MARK: - Backup (manual export / restore — P1/S stopgap until v2 sync)

private struct BackupSettingsSection: View {
    @State private var exportStatus: String?
    @State private var restoreResult: NoteManager.BackupImportOutcome?
    @State private var showRestoreResult = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("バックアップ", "Backup"))
                .font(.system(size: 18, weight: .bold))

            Text(L("すべてのノート・グループ・最近削除を 1 つのファイルに書き出します。別の Mac や初期化後の環境でも、このファイルだけで復元できます。",
                   "Write every note, group, and recently-deleted entry into a single file. Another Mac — or this one after a clean install — can restore from that file alone."))
                .font(.system(size: 12))
                .foregroundStyle(Color.black.opacity(0.60))

            settingsGroup(title: L("今すぐバックアップ", "Back up now")) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        runExport()
                    } label: {
                        Label(L("今すぐバックアップ…", "Back up now…"),
                              systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    if let msg = exportStatus {
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text(L("バックアップは暗号化されていません。安全な場所に保管してください。",
                           "Backups are not encrypted. Keep the file somewhere safe."))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.orange)
                    Text(L("暗号化キーはこの Mac の Keychain から持ち出せないため、意図的に復号して保存します。暗号化したままでは新しい Mac で復元できません。ロック中のノートも含まれます。",
                           "The encryption key never leaves this Mac's Keychain, so the file is deliberately saved decrypted — an encrypted backup could not be restored on a new machine. Locked notes are included."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            settingsGroup(title: L("バックアップから復元", "Restore from backup")) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        runRestore()
                    } label: {
                        Label(L("バックアップから復元…", "Restore from backup…"),
                              systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .controlSize(.small)

                    Text(L("既存のノートには一切上書きしません。同じノートはスキップされ、新しいノートだけが各グループへ追加されます（無いグループは名前で再作成）。",
                           "Existing notes are never overwritten: matching notes are skipped and only new ones are added to their groups (missing groups are recreated by name)."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(L("復元を書き込む前に、現在のデータのスナップショットを自動保存します。ファイルが壊れている場合は何も変更せず中止します。",
                           "A snapshot of your current data is saved automatically before anything is written. A corrupted file aborts with zero changes."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .alert(L("復元が完了しました", "Restore complete"),
               isPresented: $showRestoreResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreResult.map(restoreSummary) ?? "")
        }
        .alert(L("バックアップエラー", "Backup error"),
               isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func restoreSummary(_ r: NoteManager.BackupImportOutcome) -> String {
        var line = L("\(r.restored) 件を復元、\(r.skipped) 件は既に存在するためスキップしました。",
                     "Restored \(r.restored) notes; skipped \(r.skipped) that already exist.")
        if r.groupsCreated > 0 {
            line += "\n" + L("グループを \(r.groupsCreated) 個作成しました。",
                             "Created \(r.groupsCreated) groups.")
        }
        return line
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private var backupUTTypes: [UTType] {
        var types: [UTType] = []
        if let t = UTType(filenameExtension: "flotebackup") { types.append(t) }
        types.append(.json)  // renamed/inspected backups still open
        return types
    }

    /// Export: encode the LIVE in-memory state (fresher than disk — the
    /// 0.5 s save debounce may still be pending) as plaintext JSON and write
    /// it to the user-chosen destination. Reads only; never mutates the store.
    private func runExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = backupUTTypes
        panel.nameFieldStringValue = FloteBackup.suggestedFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = L("バックアップを保存", "Save backup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let doc = FloteBackup.document(
                notes: NoteManager.shared.notes,
                groups: GroupManager.shared.groups,
                history: NoteManager.shared.history,
                learning: LearningManager.shared.examples,
                appVersion: appVersion
            )
            let data = try FloteBackup.encode(doc)
            try data.write(to: url, options: [.atomic])
            exportStatus = L("保存しました（ノート \(doc.manifest.noteCount) 件 / グループ \(doc.manifest.groupCount) 個 / 最近削除 \(doc.manifest.historyCount) 件）",
                             "Saved — \(doc.manifest.noteCount) notes / \(doc.manifest.groupCount) groups / \(doc.manifest.historyCount) recently deleted.")
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// Restore, fail-closed:
    ///   1. read + ALL-OR-NOTHING parse/validate (zero writes until valid)
    ///   2. snapshot the current store (abort restore if that fails)
    ///   3. merge through NoteManager's normal save paths (skip existing ids)
    private func runRestore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = backupUTTypes
        panel.title = L("バックアップを選択", "Choose a backup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let didScope = url.startAccessingSecurityScopedResource()
            defer { if didScope { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let doc = try FloteBackup.parse(data)
            try PersistenceService.snapshotBeforeRestore()
            let outcome = NoteManager.shared.importBackup(doc)
            restoreResult = outcome
            showRestoreResult = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

private struct ShortcutsSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L("ショートカット", "Shortcuts"))
                .font(.system(size: 18, weight: .bold))

            Text(L("行をクリックして新しいキーを記録します。Delete でクリア、Esc でキャンセル。システムや他のアプリとのコンフリクトは自動的に警告されます。", "Click a row to record a new key. Delete clears, Esc cancels. Conflicts with the system or other apps are flagged automatically."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            settingsGroup(title: L("グローバル", "Global")) {
                KeyRecorderRow(
                    label: "New note",
                    description: "Create a new sticky note from any app",
                    name: .newNote
                )
                KeyRecorderRow(
                    label: "Search notes",
                    description: "Open the search palette from any app",
                    name: .searchNotes
                )
                KeyRecorderRow(
                    label: L("すべてのノートを隠す/表示", "Hide/show all notes"),
                    description: L(
                        "1回押すと全パネルを隠し、もう1回押すと元の位置に戻します",
                        "One press hides every panel, the next brings them back where they were"
                    ),
                    name: .toggleAllNotes
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
            Text(L("このアプリについて", "About"))
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
                    Text(L("AI が整理する浮遊付箋アプリ。", "A sticky-note app with AI-powered organization."))
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

@MainActor
private func noteTitle(_ note: StickyNote) -> String {
    // Sealed accessor only (r3b NEW-1): the old isLocked gate used raw
    // rolledTitle?.isEmpty (whitespace passed) and locked-WITH-title still
    // fell through to the body's first line.
    if let t = note.lockedSafeTitle, !t.isEmpty { return t }
    return note.isLocked
        ? L("ロック中のノート", "Locked note")
        : L("無題のノート", "Untitled note")
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
