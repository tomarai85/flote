// Settings Groups セクション (Sprint 5 Feature 5.2 / 5.4)。
//
// - 左: グループツリー (Inbox 固定先頭 + ユーザーグループ)
// - 右: 選択中グループの詳細 (ノート数、所属ノート一覧の要約)
// - 操作: 新規グループ / リネーム / 削除 / Inbox を整理 (AI Sort)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/note_group.dart';
import '../../../providers/group_manager.dart';
import '../../../providers/note_manager.dart';
import '../../../theme/tokens.dart';
import '../settings_components.dart';

class GroupsSection extends ConsumerStatefulWidget {
  const GroupsSection({
    super.key,
    this.onCreateGroup,
    this.onRenameGroup,
    this.onDeleteGroup,
    this.onBatchClassify,
  });

  final Future<void> Function()? onCreateGroup;
  final Future<void> Function(NoteGroup group)? onRenameGroup;
  final Future<void> Function(NoteGroup group)? onDeleteGroup;
  final Future<void> Function()? onBatchClassify;

  @override
  ConsumerState<GroupsSection> createState() => _GroupsSectionState();
}

class _GroupsSectionState extends ConsumerState<GroupsSection> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final asyncGroups = ref.watch(groupManagerProvider);
    final asyncNotes = ref.watch(noteManagerProvider);

    return asyncGroups.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(child: Text('グループ読込失敗: $error')),
      data: (groups) {
        // Inbox を先頭に持ってくる。
        final sorted = _sortWithInboxFirst(groups);
        final notes = asyncNotes.value ?? const [];
        final inboxCount =
            notes.where((n) => n.groupID == NoteGroup.inboxId).length;

        _selectedId ??= sorted.isNotEmpty ? sorted.first.id : null;
        final selected = sorted.where((g) => g.id == _selectedId).toList();
        final selectedGroup = selected.isNotEmpty ? selected.first : null;

        return SettingsSection(
          heading: 'Groups',
          description: 'ノートを分類するグループの管理',
          headerTrailing: _HeaderActions(
            onCreate: widget.onCreateGroup,
            onBatchClassify: inboxCount >= 2 ? widget.onBatchClassify : null,
            inboxCount: inboxCount,
          ),
          children: [
            SizedBox(
              height: 320,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildGroupList(sorted, notes),
                  ),
                  const SizedBox(width: SpacingTokens.md),
                  Expanded(
                    flex: 4,
                    child: _buildDetail(selectedGroup, notes),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  List<NoteGroup> _sortWithInboxFirst(List<NoteGroup> groups) {
    final inbox = groups.where((g) => g.id == NoteGroup.inboxId).toList();
    final others = groups.where((g) => g.id != NoteGroup.inboxId).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return [...inbox, ...others];
  }

  Widget _buildGroupList(List<NoteGroup> groups, List<dynamic> notes) {
    return Container(
      decoration: BoxDecoration(
        color: ColorTokens.surface,
        borderRadius: BorderRadius.circular(RadiusTokens.medium),
        border: Border.all(
          color: ColorTokens.onSurfaceMuted.withValues(alpha: 0.14),
        ),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(SpacingTokens.sm),
        itemCount: groups.length,
        separatorBuilder: (_, _) => const SizedBox(height: SpacingTokens.xs),
        itemBuilder: (context, index) {
          final g = groups[index];
          final count =
              notes.where((n) => (n as dynamic).groupID == g.id).length;
          return SettingsTile(
            title: g.name,
            subtitle: '$count 件',
            isSelected: _selectedId == g.id,
            leading: Icon(_iconFor(g), size: 18),
            onTap: () {
              setState(() => _selectedId = g.id);
            },
          );
        },
      ),
    );
  }

  Widget _buildDetail(NoteGroup? group, List<dynamic> notes) {
    if (group == null) {
      return Center(
        child: Text(
          'グループを選択してください',
          style: TypographyTokens.body.copyWith(
            color: ColorTokens.onSurfaceMuted,
          ),
        ),
      );
    }
    final isInbox = group.id == NoteGroup.inboxId;
    final countInGroup =
        notes.where((n) => (n as dynamic).groupID == group.id).length;
    return Container(
      padding: const EdgeInsets.all(SpacingTokens.md),
      decoration: BoxDecoration(
        color: ColorTokens.surface,
        borderRadius: BorderRadius.circular(RadiusTokens.medium),
        border: Border.all(
          color: ColorTokens.onSurfaceMuted.withValues(alpha: 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(group), size: 18),
              const SizedBox(width: SpacingTokens.sm),
              Expanded(
                child: Text(
                  group.name,
                  style: TypographyTokens.bodyBold.copyWith(
                    color: ColorTokens.onSurface,
                  ),
                ),
              ),
              if (!isInbox)
                IconButton(
                  tooltip: 'リネーム',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: widget.onRenameGroup == null
                      ? null
                      : () async => widget.onRenameGroup!(group),
                ),
              if (!isInbox)
                IconButton(
                  tooltip: '削除',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: widget.onDeleteGroup == null
                      ? null
                      : () async => widget.onDeleteGroup!(group),
                ),
            ],
          ),
          const SizedBox(height: SpacingTokens.sm),
          Text(
            '所属ノート: $countInGroup 件',
            style: TypographyTokens.caption.copyWith(
              color: ColorTokens.onSurfaceMuted,
            ),
          ),
          if (isInbox) ...[
            const SizedBox(height: SpacingTokens.sm),
            Text(
              'Inbox はシステムグループです。削除できません。',
              style: TypographyTokens.caption.copyWith(
                color: ColorTokens.onSurfaceMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(NoteGroup g) {
    switch (g.iconName) {
      case 'tray':
        return Icons.inbox_outlined;
      case 'folder':
        return Icons.folder_outlined;
      default:
        return Icons.label_outline;
    }
  }
}

class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.onCreate,
    required this.onBatchClassify,
    required this.inboxCount,
  });

  final Future<void> Function()? onCreate;
  final Future<void> Function()? onBatchClassify;
  final int inboxCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed: onBatchClassify,
          icon: const Icon(Icons.auto_awesome, size: 16),
          label: Text('Inbox を整理 ($inboxCount)'),
        ),
        const SizedBox(width: SpacingTokens.sm),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.create_new_folder_outlined, size: 16),
          label: const Text('新規'),
        ),
      ],
    );
  }
}
