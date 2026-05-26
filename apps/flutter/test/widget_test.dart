// Sprint 2 更新: AppShell が PersistenceService を介してノートを読み、
// ListView に「ノートがまだありません」プレースホルダを表示することを検証する。
//
// AsyncNotifier ベースになった NoteManager は build() で loadNotes() を await するので、
// 一時ディレクトリを baseOverride に渡した PersistenceService を Provider 上書きし、
// Widget tree を pump する前に provider を pre-warm して data 状態にしてから検証する。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flote_desktop/providers/note_manager.dart';
import 'package:flote_desktop/services/persistence_service.dart';
import 'package:flote_desktop/ui/app_shell.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flote_widget_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('AppShell はタイトルと空状態プレースホルダを描画する', (WidgetTester tester) async {
    // runAsync 内で provider pre-warm し、I/O を完了させてから pumpWidget する。
    late final ProviderContainer container;
    await tester.runAsync(() async {
      container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(
            PersistenceService(baseOverride: tempDir),
          ),
        ],
      );
      // pre-warm: build() の Future を await して data 状態にする。
      await container.read(noteManagerProvider.future);
    });
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pump();

    expect(find.text('Flote'), findsOneWidget);
    expect(find.text('ノートがまだありません'), findsOneWidget);
  });
}
