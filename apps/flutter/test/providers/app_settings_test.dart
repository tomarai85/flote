// Sprint 5: AppSettingsNotifier のテスト。

import 'dart:io';

import 'package:flote_desktop/data/prompts.dart';
import 'package:flote_desktop/providers/app_settings.dart';
import 'package:flote_desktop/providers/note_manager.dart';
import 'package:flote_desktop/services/persistence_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Directory> _makeTempDir() async {
  return Directory.systemTemp.createTemp('flote_appsettings_test_');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettingsNotifier', () {
    test('初期状態: defaults が返る', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(persistence),
        ],
      );
      addTearDown(container.dispose);

      final s = await container.read(appSettingsProvider.future);
      expect(s.ollamaUrl, 'http://localhost:11434/api/generate');
      expect(s.ollamaModel, 'gemma3:12b');
      expect(s.alwaysOnTopOnLaunch, isFalse);
      expect(s.promptPreset, PromptPreset.standard);
    });

    test('update 系メソッドが state を変え、flushSaveNow で書き出される', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(persistence),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.updateOllamaUrl('https://new.example.com/api');
      await notifier.updateAlwaysOnTopOnLaunch(true);
      await notifier.flushSaveNow();

      final reloaded = await persistence.loadSettings();
      expect(reloaded.ollamaUrl, 'https://new.example.com/api');
      expect(reloaded.alwaysOnTopOnLaunch, isTrue);
    });

    test('saveAiEndpointNow: URL と model を一括更新して即永続化', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(persistence),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.saveAiEndpointNow(
        ollamaUrl: 'http://localhost:11434/api/generate',
        ollamaModel: 'llama3',
      );

      final reloaded = await persistence.loadSettings();
      expect(reloaded.ollamaModel, 'llama3');
    });

    test('savePromptNow: preset と custom を一括更新', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(persistence),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.savePromptNow(
        preset: PromptPreset.concise,
        customText: 'my custom',
      );

      final reloaded = await persistence.loadSettings();
      expect(reloaded.promptPreset, PromptPreset.concise);
      expect(reloaded.promptCustomText, 'my custom');
    });

    test('resetCustomPrompt: customText が promptCustomDefault に戻る', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(persistence),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.updatePromptCustomText('edited');
      await notifier.resetCustomPrompt();

      final reloaded = await persistence.loadSettings();
      expect(reloaded.promptCustomText, promptCustomDefault);
    });

    test('saveCustomShortcutsNow: Map を書き込み、ロードで復元できる', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(persistence),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.saveCustomShortcutsNow(const {
        'newNote': 'ctrl+shift+n',
        'archive': 'meta+w',
      });

      final reloaded = await persistence.loadSettings();
      expect(reloaded.customShortcuts['newNote'], 'ctrl+shift+n');
      expect(reloaded.customShortcuts['archive'], 'meta+w');
    });

    test('saveCustomShortcutsNow: 空 Map でユーザー設定をクリアできる', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(persistence),
        ],
      );
      addTearDown(container.dispose);

      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.saveCustomShortcutsNow(const {'newNote': 'alt+space'});
      await notifier.saveCustomShortcutsNow(const {});

      final reloaded = await persistence.loadSettings();
      expect(reloaded.customShortcuts, isEmpty);
    });
  });
}
