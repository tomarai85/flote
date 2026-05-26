// Settings General セクション (Phase 2 視覚移植版、Sprint 5 Feature 5.4 継続)。
//
// アプリ名 / バージョン / フォント選択 / 起動時最前面トグル / 再起動ボタン。
// Phase 2 で SwiftUI `AppFont.swift` 相当のフォント選択 UI を追加。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_settings.dart';
import '../../../theme/tokens.dart';
import '../settings_components.dart';

class GeneralSection extends ConsumerWidget {
  const GeneralSection({super.key, this.onRestart});

  /// "アプリを再起動" ボタン押下時のコールバック。null なら disable。
  final VoidCallback? onRestart;

  // TODO: PackageInfo 連携。現状は pubspec.yaml と同期手動。
  static const String _appName = 'Flote';
  static const String _appVersion = '1.0.0+1';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSettings = ref.watch(appSettingsProvider);
    return asyncSettings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text(
          '設定の読み込みに失敗しました: $error',
          style: TypographyTokens.body.copyWith(color: ColorTokens.error),
        ),
      ),
      data: (settings) {
        return SettingsSection(
          heading: 'General',
          description: 'アプリ全体の基本設定',
          children: [
            SettingsRow(
              label: 'アプリ',
              child: Text(
                _appName,
                style: TypographyTokens.body.copyWith(
                  color: ColorTokens.onSurface,
                ),
              ),
            ),
            SettingsRow(
              label: 'バージョン',
              child: Text(
                _appVersion,
                style: TypographyTokens.body.copyWith(
                  color: ColorTokens.onSurfaceMuted,
                ),
              ),
            ),
            SettingsRow(
              label: 'フォント',
              description: '本文と巻物バーのタイトルに使うフォント (SwiftUI 版と共通)',
              child: DropdownButton<AppFontFamily>(
                value: settings.fontFamily,
                isExpanded: true,
                items: AppFontFamily.values
                    .map(
                      (family) => DropdownMenuItem<AppFontFamily>(
                        value: family,
                        child: Text(
                          family.displayName,
                          style: TextStyle(
                            fontFamily: family.macosFontName,
                            fontFamilyFallback: <String>[family.fallbackFontName],
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (next) async {
                  if (next == null) return;
                  await ref
                      .read(appSettingsProvider.notifier)
                      .updateFontFamilyNow(next);
                },
              ),
            ),
            SettingsRow(
              label: '起動時に最前面',
              description: '起動直後にメインウィンドウを前面に出す',
              child: Switch(
                value: settings.alwaysOnTopOnLaunch,
                onChanged: (next) async {
                  await ref
                      .read(appSettingsProvider.notifier)
                      .updateAlwaysOnTopOnLaunch(next);
                },
              ),
            ),
            SettingsRow(
              label: 'アプリ操作',
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: onRestart,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('アプリを再起動'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
