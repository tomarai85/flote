// Sprint 5: OrganizeRunner のテスト (undo stack, 結果適用, 削除スキップ)。

import 'dart:convert';

import 'package:flote_desktop/data/prompts.dart';
import 'package:flote_desktop/models/app_settings.dart';
import 'package:flote_desktop/providers/organize_runner.dart';
import 'package:flote_desktop/services/keychain_service.dart';
import 'package:flote_desktop/services/organize_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeKeychain extends KeychainService {
  _FakeKeychain();
  String? claudeKey;

  @override
  Future<String?> loadClaudeApiKey() async => claudeKey;
  @override
  Future<bool> hasClaudeApiKey() async =>
      claudeKey != null && claudeKey!.isNotEmpty;
  @override
  Future<void> saveClaudeApiKey(String key) async => claudeKey = key;
  @override
  Future<void> deleteClaudeApiKey() async => claudeKey = null;
}

ProviderContainer _makeContainer(OrganizeService service) {
  return ProviderContainer(
    overrides: [
      organizeServiceProvider.overrideWithValue(service),
      keychainServiceProvider.overrideWithValue(_FakeKeychain()),
    ],
  );
}

void main() {
  group('OrganizeRunner', () {
    test('初期 state は isRunning=false かつ error なし', () {
      final dummy = OrganizeService(
        keychain: _FakeKeychain(),
        httpClient: MockClient((req) async => http.Response('', 200)),
      );
      final container = _makeContainer(dummy);
      addTearDown(container.dispose);

      final state = container.read(organizeRunnerProvider);
      expect(state.isRunning, isFalse);
      expect(state.lastError, isNull);
    });

    test('成功時: apply が呼ばれ、undo stack に 1 件積まれる', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({'response': '整えた結果'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = OrganizeService(keychain: keychain, httpClient: client);
      final container = ProviderContainer(
        overrides: [
          organizeServiceProvider.overrideWithValue(service),
          keychainServiceProvider.overrideWithValue(keychain),
        ],
      );
      addTearDown(container.dispose);

      final runner = container.read(organizeRunnerProvider.notifier);
      String? appliedRich;
      String? appliedPlain;
      final result = await runner.run(
        noteId: 'n1',
        richTextBefore: '[]',
        plainTextBefore: '元の文',
        settings: AppSettings.defaults(),
        apply: (rich, plain) async {
          appliedRich = rich;
          appliedPlain = plain;
        },
        isNoteAlive: () async => true,
      );
      expect(result, isA<OrganizeSuccess>());
      expect(appliedPlain, '整えた結果');
      expect(appliedRich, isNotNull);
      expect(runner.canUndoFor('n1'), isTrue);
      expect(runner.undoStackSnapshot.length, 1);
    });

    test('削除後 (isNoteAlive=false) は apply が呼ばれない', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode({'response': 'ignored'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = OrganizeService(keychain: keychain, httpClient: client);
      final container = ProviderContainer(
        overrides: [
          organizeServiceProvider.overrideWithValue(service),
          keychainServiceProvider.overrideWithValue(keychain),
        ],
      );
      addTearDown(container.dispose);

      var applyCount = 0;
      final runner = container.read(organizeRunnerProvider.notifier);
      await runner.run(
        noteId: 'n2',
        richTextBefore: '[]',
        plainTextBefore: 'hello',
        settings: AppSettings.defaults(),
        apply: (_, _) async => applyCount++,
        isNoteAlive: () async => false,
      );
      expect(applyCount, 0);
    });

    test('popUndo: 最新のエントリを返してスタックから除去', () async {
      final keychain = _FakeKeychain();
      final client = MockClient((req) async => http.Response(
            jsonEncode({'response': 'ok'}),
            200,
            headers: {'content-type': 'application/json'},
          ));
      final service = OrganizeService(keychain: keychain, httpClient: client);
      final container = ProviderContainer(
        overrides: [
          organizeServiceProvider.overrideWithValue(service),
          keychainServiceProvider.overrideWithValue(keychain),
        ],
      );
      addTearDown(container.dispose);

      final runner = container.read(organizeRunnerProvider.notifier);
      await runner.run(
        noteId: 'n1',
        richTextBefore: '[1]',
        plainTextBefore: 'a',
        settings: AppSettings.defaults(),
        apply: (_, _) async {},
        isNoteAlive: () async => true,
      );
      await runner.run(
        noteId: 'n1',
        richTextBefore: '[2]',
        plainTextBefore: 'b',
        settings: AppSettings.defaults(),
        apply: (_, _) async {},
        isNoteAlive: () async => true,
      );
      final popped = runner.popUndo('n1');
      expect(popped, isNotNull);
      // 最新の run で積まれた entry (richTextBefore='[2]') が返る
      expect(popped!.richTextBefore, '[2]');
      // 1 件残る
      expect(runner.undoStackSnapshot.length, 1);
      final popped2 = runner.popUndo('n1');
      expect(popped2!.richTextBefore, '[1]');
      expect(runner.popUndo('n1'), isNull);
    });

    test('空テキスト -> parse エラー、apply 呼ばれない', () async {
      final keychain = _FakeKeychain();
      final service = OrganizeService(
        keychain: keychain,
        httpClient: MockClient((req) async => http.Response('', 200)),
      );
      final container = ProviderContainer(
        overrides: [
          organizeServiceProvider.overrideWithValue(service),
          keychainServiceProvider.overrideWithValue(keychain),
        ],
      );
      addTearDown(container.dispose);

      var applyCount = 0;
      final runner = container.read(organizeRunnerProvider.notifier);
      final result = await runner.run(
        noteId: 'n1',
        richTextBefore: '[]',
        plainTextBefore: '   ',
        settings: AppSettings.defaults(),
        apply: (_, _) async => applyCount++,
        isNoteAlive: () async => true,
      );
      expect(result, isA<OrganizeFailure>());
      expect((result as OrganizeFailure).kind, OrganizeErrorKind.parse);
      expect(applyCount, 0);
      final state = container.read(organizeRunnerProvider);
      expect(state.lastError, isNotNull);
    });

    test('prompt defaults 定数を依存として解決できる', () {
      expect(kOrganizeInputMaxLength, 10000);
    });
  });
}
