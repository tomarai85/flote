// Sprint 5 Round 2: ShortcutsSection widget test + SettingsWindow rebind 統合。
//
// - ShortcutsSection が現在 combo を表示すること
// - 「変更...」ボタン押下で onRebind が呼ばれること
// - 「標準に戻す」ボタンで onReset が呼ばれること

import 'package:flote_desktop/models/app_settings.dart';
import 'package:flote_desktop/providers/note_manager.dart';
import 'package:flote_desktop/services/persistence_service.dart';
import 'package:flote_desktop/ui/settings/sections/shortcuts_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _InMemoryPersistence extends PersistenceService {
  AppSettings _settings = AppSettings.defaults();

  @override
  Future<AppSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AppSettings settings) async {
    _settings = settings;
  }
}

void main() {
  testWidgets('ShortcutsSection: currentComboFor の戻り値が表示される', (tester) async {
    ShortcutSlot? tapped;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          persistenceServiceProvider.overrideWithValue(_InMemoryPersistence()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ShortcutsSection(
              onRebind: (s) async => tapped = s,
              onReset: () async {},
              currentComboFor: (slot) => 'FAKE+${slot.name}',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('FAKE+newNote'), findsOneWidget);
    expect(find.text('FAKE+openGroups'), findsOneWidget);
    expect(find.text('FAKE+archive'), findsOneWidget);

    // 最初の「変更...」ボタン (newNote) を押すと onRebind が newNote で呼ばれる。
    await tester.tap(find.text('変更...').first);
    await tester.pumpAndSettle();
    expect(tapped, ShortcutSlot.newNote);
  });

  testWidgets('ShortcutsSection: currentComboFor が null ならプレースホルダ', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          persistenceServiceProvider.overrideWithValue(_InMemoryPersistence()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ShortcutsSection(
              currentComboFor: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('—'), findsNWidgets(3));
  });

  testWidgets('ShortcutsSection: 標準に戻すボタン押下で onReset 呼び出し', (tester) async {
    var resetCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          persistenceServiceProvider.overrideWithValue(_InMemoryPersistence()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ShortcutsSection(
              onReset: () async {
                resetCount++;
              },
              currentComboFor: (_) => 'x',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('標準に戻す'));
    await tester.pumpAndSettle();
    expect(resetCount, 1);
  });
}
