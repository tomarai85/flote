// Settings History セクション (Sprint 5 Feature 5.5)。
//
// 削除されたノートの履歴を表示し、復元・永久削除・全削除を操作する。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/history_entry.dart';
import '../../../models/note_color_theme.dart';
import '../../../providers/history_manager.dart';
import '../../../theme/tokens.dart';
import '../settings_components.dart';

/// 相対時刻表示 helper。
String formatRelative(DateTime target, {DateTime? nowOverride}) {
  final now = nowOverride ?? DateTime.now();
  final diff = now.difference(target);
  if (diff.inMinutes < 1) {
    return '今';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes}分前';
  }
  if (diff.inDays < 1) {
    return '${diff.inHours}時間前';
  }
  if (diff.inDays < 30) {
    return '${diff.inDays}日前';
  }
  final months = (diff.inDays / 30).floor();
  return '$monthsヶ月前';
}

class HistorySection extends ConsumerWidget {
  const HistorySection({
    super.key,
    this.onRestore,
    this.onPermanentDelete,
    this.onClearAll,
  });

  final Future<void> Function(HistoryEntry entry)? onRestore;
  final Future<void> Function(HistoryEntry entry)? onPermanentDelete;
  final Future<void> Function()? onClearAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncHistory = ref.watch(historyManagerProvider);
    return asyncHistory.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text(
          '履歴読込失敗: $error',
          style: TypographyTokens.body.copyWith(color: ColorTokens.error),
        ),
      ),
      data: (entries) {
        final count = entries.length;
        return SettingsSection(
          heading: 'History',
          description: '削除したノートの履歴 (最大 $kHistoryMaxEntries 件)',
          headerTrailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$count 件',
                style: TypographyTokens.caption.copyWith(
                  color: ColorTokens.onSurfaceMuted,
                ),
              ),
              const SizedBox(width: SpacingTokens.sm),
              TextButton.icon(
                onPressed: count == 0 ? null : onClearAll,
                icon: const Icon(Icons.delete_forever_outlined, size: 16),
                label: const Text('全て削除'),
              ),
            ],
          ),
          children: [
            SizedBox(
              height: 380,
              child: count == 0
                  ? _buildEmpty()
                  : _buildList(context, entries),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Text(
        '履歴にノートはありません',
        style: TypographyTokens.body.copyWith(
          color: ColorTokens.onSurfaceMuted,
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, List<HistoryEntry> entries) {
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SettingsDivider(),
      itemBuilder: (context, index) {
        final e = entries[index];
        final preview = _preview(e.text);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: SpacingTokens.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 6, right: SpacingTokens.sm),
                decoration: BoxDecoration(
                  color: e.colorTheme.background,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ColorTokens.onSurfaceMuted.withValues(alpha: 0.3),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TypographyTokens.body.copyWith(
                        color: ColorTokens.onSurface,
                      ),
                    ),
                    const SizedBox(height: SpacingTokens.xs),
                    Text(
                      formatRelative(e.deletedAt),
                      style: TypographyTokens.caption.copyWith(
                        color: ColorTokens.onSurfaceMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SpacingTokens.sm),
              TextButton.icon(
                onPressed: onRestore == null ? null : () async => onRestore!(e),
                icon: const Icon(Icons.restore, size: 16),
                label: const Text('復元'),
              ),
              IconButton(
                tooltip: '永久削除',
                icon: const Icon(Icons.delete_forever_outlined, size: 16),
                onPressed: onPermanentDelete == null
                    ? null
                    : () async => onPermanentDelete!(e),
              ),
            ],
          ),
        );
      },
    );
  }

  String _preview(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return '(空のノート)';
    }
    if (trimmed.length <= 60) {
      return trimmed;
    }
    return '${trimmed.substring(0, 60)}...';
  }
}
