// AppSettings 用 AsyncNotifier (Sprint 5 Feature 5.4)。
//
// PersistenceService.loadSettings / saveSettings を介して settings.json を永続化する。
// NoteManager / GroupManager と同様、500ms debounce save + flushSaveNow を提供する。

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/prompts.dart';
import '../models/app_settings.dart';
import '../theme/tokens.dart';
import 'note_manager.dart';

/// appSettingsProvider: AsyncNotifier 経由でアプリ全体の設定を供給する。
final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);

class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  Timer? _saveDebounce;
  static const Duration _debounce = Duration(milliseconds: 500);

  @override
  Future<AppSettings> build() async {
    final persistence = ref.read(persistenceServiceProvider);
    ref.onDispose(() {
      _saveDebounce?.cancel();
      _saveDebounce = null;
    });
    try {
      return await persistence.loadSettings();
    } catch (error) {
      stderr.writeln('AppSettingsNotifier.loadSettings failed: $error');
      return AppSettings.defaults();
    }
  }

  AppSettings get _current => state.value ?? AppSettings.defaults();

  void _update(AppSettings next) {
    state = AsyncData(next);
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_debounce, () async {
      await _persistNow();
    });
  }

  Future<void> _persistNow() async {
    final snapshot = state.value;
    if (snapshot == null) {
      return;
    }
    try {
      await ref.read(persistenceServiceProvider).saveSettings(snapshot);
    } catch (error, stackTrace) {
      stderr.writeln('AppSettingsNotifier.saveSettings failed: $error\n$stackTrace');
    }
  }

  /// 保留中の保存を即 flush する (アプリ終了前に呼ぶ)。
  Future<void> flushSaveNow() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _persistNow();
  }

  // mutation メソッド群。UI 側は debounce 期待、保存ボタンを押す場合は
  // このメソッド群を連続呼出 + flushSaveNow の流れで呼ぶ。

  Future<void> updateOllamaUrl(String url) async {
    _update(_current.copyWith(ollamaUrl: url));
  }

  Future<void> updateOllamaModel(String model) async {
    _update(_current.copyWith(ollamaModel: model));
  }

  Future<void> updateAlwaysOnTopOnLaunch(bool value) async {
    _update(_current.copyWith(alwaysOnTopOnLaunch: value));
  }

  /// Phase 2 視覚移植: 本文フォント選択を即時更新 + flush。
  /// 設定画面のドロップダウンから呼ぶ。
  Future<void> updateFontFamilyNow(AppFontFamily family) async {
    _update(_current.copyWith(fontFamily: family));
    await flushSaveNow();
  }

  Future<void> updatePromptPreset(PromptPreset preset) async {
    _update(_current.copyWith(promptPreset: preset));
  }

  Future<void> updatePromptCustomText(String text) async {
    _update(_current.copyWith(promptCustomText: text));
  }

  /// AI セクションの保存ボタンから呼ぶ: URL と Model を一括で更新し即 flush。
  Future<void> saveAiEndpointNow({
    required String ollamaUrl,
    required String ollamaModel,
  }) async {
    _update(
      _current.copyWith(ollamaUrl: ollamaUrl, ollamaModel: ollamaModel),
    );
    await flushSaveNow();
  }

  /// Prompt セクションの保存ボタンから呼ぶ: preset と custom を一括更新し即 flush。
  Future<void> savePromptNow({
    required PromptPreset preset,
    required String customText,
  }) async {
    _update(
      _current.copyWith(
        promptPreset: preset,
        promptCustomText: customText,
      ),
    );
    await flushSaveNow();
  }

  /// custom prompt を初期値に戻す。
  Future<void> resetCustomPrompt() async {
    _update(_current.copyWith(promptCustomText: promptCustomDefault));
    await flushSaveNow();
  }

  /// Sprint 5 Round 2: Settings > Shortcuts からリバインド内容を保存する。
  /// 空 Map を渡すとユーザー設定をクリアし、全スロットがデフォルトに戻る。
  Future<void> saveCustomShortcutsNow(Map<String, String> shortcuts) async {
    _update(_current.copyWith(customShortcuts: Map<String, String>.from(shortcuts)));
    await flushSaveNow();
  }
}
