// Settings Shortcuts セクション (Sprint 5 Feature 5.4 + Round 2 リバインド UI)。
//
// 3 スロット (新規ノート / Groups 表示 / archive) に対し、現在のキー組み合わせ
// を表示し、「変更...」ボタンでキャプチャダイアログ経由のリバインドを提供する。
//
// 実際のキャプチャダイアログと AppSettings への保存は呼び出し側 (SettingsWindow)
// が `onRebind` で処理する。ここは表示と操作入口に徹する。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_settings.dart';
import '../../../theme/tokens.dart';
import '../settings_components.dart';

/// キーバインドスロット識別子 (UI 側の enum)。
/// 内部的には services/hotkey_service.dart の HotkeySlot に 1:1 で対応する。
enum ShortcutSlot { newNote, openGroups, archive }

class ShortcutsSection extends ConsumerWidget {
  const ShortcutsSection({
    super.key,
    this.onRebind,
    this.onReset,
    this.currentComboFor,
  });

  final Future<void> Function(ShortcutSlot slot)? onRebind;
  final Future<void> Function()? onReset;

  /// スロット毎の現在の組み合わせ表示文字列を返すコールバック。
  /// 未指定の場合はプレースホルダ表記になる。
  final String Function(ShortcutSlot slot)? currentComboFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // AppSettings の変更を監視し、変更があれば自動で再描画する。
    ref.watch(appSettingsProvider);

    return SettingsSection(
      heading: 'Shortcuts',
      description: 'グローバルホットキーの表示・変更',
      headerTrailing: TextButton(
        onPressed: onReset == null ? null : () async => onReset!(),
        child: const Text('標準に戻す'),
      ),
      children: [
        _buildRow(
          slot: ShortcutSlot.newNote,
          label: '新規ノート',
        ),
        const SettingsDivider(),
        _buildRow(
          slot: ShortcutSlot.openGroups,
          label: 'Groups 表示',
        ),
        const SettingsDivider(),
        _buildRow(
          slot: ShortcutSlot.archive,
          label: 'Archive',
        ),
      ],
    );
  }

  Widget _buildRow({
    required ShortcutSlot slot,
    required String label,
  }) {
    final keysLabel = currentComboFor?.call(slot) ?? '—';
    return SettingsRow(
      label: label,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SpacingTokens.sm,
              vertical: SpacingTokens.xs,
            ),
            decoration: BoxDecoration(
              color: ColorTokens.onSurfaceMuted.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(RadiusTokens.small),
            ),
            child: Text(
              keysLabel,
              style: TypographyTokens.caption.copyWith(
                color: ColorTokens.onSurface,
                fontFamily: 'Menlo',
              ),
            ),
          ),
          const SizedBox(width: SpacingTokens.sm),
          OutlinedButton(
            onPressed: onRebind == null
                ? null
                : () async => onRebind!(slot),
            child: const Text('変更...'),
          ),
        ],
      ),
    );
  }
}
