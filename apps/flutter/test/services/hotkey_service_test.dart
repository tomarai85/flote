// Sprint 3 Feature 3.7 HotkeyService の非プラットフォーム部分のテスト。
// Sprint 5 Round 2: HotkeyCombo parse / toComboString / HotkeySlot 拡張。
//
// 実際の hotkey_manager 登録はネイティブ plugin が必要なため、ここでは:
// - hotkeyDescription の platform 判定
// - registerNewNote が MissingPluginException を捕捉して例外を投げないこと
// - HotkeyCombo の parse/serialize 往復
// - HotkeySlot の default combo 形式
// を検証する。

import 'package:flote_desktop/services/hotkey_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HotkeyService', () {
    test('hotkeyDescription は macOS / Windows で値を返す', () {
      final service = HotkeyService();
      expect(service.hotkeyDescription, isNotEmpty);
    });

    test('初期状態の isRegistered は false', () {
      final service = HotkeyService();
      expect(service.isRegistered, isFalse);
    });

    test('plugin 不在下での registerNewNote は例外を投げず isRegistered=false', () async {
      final service = HotkeyService();
      // テスト環境に hotkey_manager ネイティブは無いので、register は失敗するが
      // 内部で catch されて例外は外に出ない想定。
      await service.registerNewNote(onTrigger: () {});
      // macOS の unit test 環境では plugin 不在のため false になる (catch 経由)。
      expect(service.isRegistered, isFalse);
    });

    test('unregisterAll は例外を投げない', () async {
      final service = HotkeyService();
      await service.unregisterAll();
      expect(service.isRegistered, isFalse);
    });
  });

  group('HotkeyCombo', () {
    test('tryParse: alt+space で modifiers=alt / key=space', () {
      final combo = HotkeyCombo.tryParse('alt+space');
      expect(combo, isNotNull);
      expect(combo!.modifiers, equals({HotKeyModifier.alt}));
      expect(combo.logicalKey, LogicalKeyboardKey.space);
    });

    test('tryParse: ctrl+alt+g で 2 修飾子 + a-z キー', () {
      final combo = HotkeyCombo.tryParse('ctrl+alt+g');
      expect(combo, isNotNull);
      expect(
        combo!.modifiers,
        containsAll([HotKeyModifier.control, HotKeyModifier.alt]),
      );
      expect(combo.logicalKey.keyLabel.toLowerCase(), 'g');
    });

    test('tryParse: meta+w (Command+W 相当)', () {
      final combo = HotkeyCombo.tryParse('meta+w');
      expect(combo, isNotNull);
      expect(combo!.modifiers, equals({HotKeyModifier.meta}));
      expect(combo.logicalKey.keyLabel.toLowerCase(), 'w');
    });

    test('tryParse: 不正な入力は null', () {
      expect(HotkeyCombo.tryParse(''), isNull);
      expect(HotkeyCombo.tryParse('alt'), isNull); // 修飾子のみ
      expect(HotkeyCombo.tryParse('xyz'), isNull); // 未対応キー
    });

    test('toComboString: modifiers は shift,ctrl,alt,meta 順に正規化', () {
      final combo = HotkeyCombo(
        modifiers: const {
          HotKeyModifier.meta,
          HotKeyModifier.shift,
          HotKeyModifier.alt,
        },
        logicalKey: LogicalKeyboardKey.keyN,
      );
      expect(combo.toComboString(), 'shift+alt+meta+n');
    });

    test('toHumanLabel: macOS では記号化、他 OS は ASCII', () {
      final combo = HotkeyCombo(
        modifiers: const {HotKeyModifier.alt},
        logicalKey: LogicalKeyboardKey.space,
      );
      final label = combo.toHumanLabel();
      // macOS: "⌥Space" / Win/Linux: "Alt+Space" のいずれか
      expect(label, anyOf('⌥Space', 'Alt+Space'));
    });

    test('round-trip: parse -> toComboString で元に戻る', () {
      const inputs = [
        'alt+space',
        'ctrl+alt+g',
        'meta+w',
        'shift+ctrl+n',
      ];
      for (final raw in inputs) {
        final combo = HotkeyCombo.tryParse(raw);
        expect(combo, isNotNull, reason: 'parse failed for $raw');
        expect(combo!.toComboString(), raw);
      }
    });
  });

  group('HotkeySlot', () {
    test('slotKey と displayName が 3 スロット分定義されている', () {
      expect(HotkeySlot.newNote.slotKey, 'newNote');
      expect(HotkeySlot.openGroups.slotKey, 'openGroups');
      expect(HotkeySlot.archive.slotKey, 'archive');
      expect(HotkeySlot.newNote.displayName, isNotEmpty);
      expect(HotkeySlot.openGroups.displayName, isNotEmpty);
      expect(HotkeySlot.archive.displayName, isNotEmpty);
    });

    test('defaultCombo は tryParse 可能な形式を返す', () {
      for (final slot in HotkeySlot.values) {
        final raw = slot.defaultCombo();
        final combo = HotkeyCombo.tryParse(raw);
        expect(combo, isNotNull,
            reason: '${slot.slotKey} defaultCombo "$raw" failed to parse');
      }
    });
  });

  group('defaultConflictCombos', () {
    test('OS に応じたセット (重複しない文字列)', () {
      final set = defaultConflictCombos();
      // macOS/Windows/Linux で空または非空の Set が返る
      expect(set, isA<Set<String>>());
      for (final c in set) {
        expect(c.contains('+'), isTrue);
      }
    });
  });
}
