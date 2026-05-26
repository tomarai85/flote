// Sprint 5 + Phase 2: AppSettings の round-trip と defaults テスト。
// Phase 2 視覚移植で fontFamily フィールドを追加した。

import 'package:flote_desktop/data/prompts.dart';
import 'package:flote_desktop/models/app_settings.dart';
import 'package:flote_desktop/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppSettings', () {
    test('defaults は期待通りの初期値を返す', () {
      final d = AppSettings.defaults();
      expect(d.ollamaUrl, 'http://localhost:11434/api/generate');
      expect(d.ollamaModel, 'gemma3:12b');
      expect(d.alwaysOnTopOnLaunch, isFalse);
      expect(d.promptPreset, PromptPreset.standard);
      expect(d.promptCustomText, promptCustomDefault);
    });

    test('toJson / fromJson で round-trip する', () {
      final s = AppSettings(
        ollamaUrl: 'https://ollama.example.com/api',
        ollamaModel: 'llama3.2',
        alwaysOnTopOnLaunch: true,
        promptPreset: PromptPreset.concise,
        promptCustomText: 'カスタム',
      );
      final restored = AppSettings.fromJson(s.toJson());
      expect(restored, equals(s));
    });

    test('fromJson で欠損フィールドは defaults で補完', () {
      final restored = AppSettings.fromJson(const {});
      expect(restored.ollamaUrl, AppSettings.defaults().ollamaUrl);
      expect(restored.ollamaModel, AppSettings.defaults().ollamaModel);
      expect(restored.alwaysOnTopOnLaunch, false);
      expect(restored.promptPreset, PromptPreset.standard);
    });

    test('copyWith は指定フィールドのみ差替える', () {
      final a = AppSettings.defaults();
      final b = a.copyWith(alwaysOnTopOnLaunch: true);
      expect(b.alwaysOnTopOnLaunch, isTrue);
      expect(b.ollamaUrl, a.ollamaUrl);
      expect(b.promptCustomText, a.promptCustomText);
    });

    test('不明な promptPreset 文字列は standard にフォールバック', () {
      final json = AppSettings.defaults().toJson()..['promptPreset'] = 'xxx';
      final restored = AppSettings.fromJson(json);
      expect(restored.promptPreset, PromptPreset.standard);
    });

    test('customShortcuts: defaults は空 Map', () {
      expect(AppSettings.defaults().customShortcuts, isEmpty);
    });

    test('customShortcuts: round-trip する', () {
      final s = AppSettings.defaults().copyWith(
        customShortcuts: const {
          'newNote': 'alt+space',
          'archive': 'meta+w',
        },
      );
      final restored = AppSettings.fromJson(s.toJson());
      expect(restored.customShortcuts['newNote'], 'alt+space');
      expect(restored.customShortcuts['archive'], 'meta+w');
    });

    test('customShortcuts の空 Value は無視される', () {
      final restored = AppSettings.fromJson({
        ...AppSettings.defaults().toJson(),
        'customShortcuts': {'newNote': '', 'openGroups': 'ctrl+alt+g'},
      });
      expect(restored.customShortcuts.containsKey('newNote'), isFalse);
      expect(restored.customShortcuts['openGroups'], 'ctrl+alt+g');
    });

    test('等価性: customShortcuts も比較対象に含まれる', () {
      final a = AppSettings.defaults()
          .copyWith(customShortcuts: const {'newNote': 'alt+space'});
      final b = AppSettings.defaults()
          .copyWith(customShortcuts: const {'newNote': 'alt+space'});
      final c = AppSettings.defaults()
          .copyWith(customShortcuts: const {'newNote': 'ctrl+space'});
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    // ---------- Phase 2: fontFamily フィールド ----------

    test('Phase 2: defaults は hiraginoSans', () {
      expect(AppSettings.defaults().fontFamily, AppFontFamily.hiraginoSans);
    });

    test('Phase 2: toJson / fromJson で fontFamily が round-trip する', () {
      final s = AppSettings.defaults().copyWith(
        fontFamily: AppFontFamily.menlo,
      );
      final restored = AppSettings.fromJson(s.toJson());
      expect(restored.fontFamily, AppFontFamily.menlo);
      expect(restored, equals(s));
    });

    test('Phase 2: 旧 SwiftUI 側の floteFontFamily キーも読む (互換性)', () {
      final restored = AppSettings.fromJson({
        ...AppSettings.defaults().toJson()..remove('fontFamily'),
        'floteFontFamily': 'newYork',
      });
      expect(restored.fontFamily, AppFontFamily.newYork);
    });

    test('Phase 2: 不明な fontFamily は hiraginoSans にフォールバック', () {
      final restored = AppSettings.fromJson({
        ...AppSettings.defaults().toJson(),
        'fontFamily': 'comic-sans',
      });
      expect(restored.fontFamily, AppFontFamily.hiraginoSans);
    });

    test('Phase 2: 等価性に fontFamily が含まれる', () {
      final a = AppSettings.defaults().copyWith(
        fontFamily: AppFontFamily.monaco,
      );
      final b = AppSettings.defaults().copyWith(
        fontFamily: AppFontFamily.monaco,
      );
      final c = AppSettings.defaults().copyWith(
        fontFamily: AppFontFamily.sfPro,
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });
}
