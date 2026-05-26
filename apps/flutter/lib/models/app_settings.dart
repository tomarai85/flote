// アプリケーション設定値 (Settings ウィンドウで編集される内容)。
//
// Sprint 5 Feature 5.4: Settings 6 セクションから参照される正式なモデル。
// 保存先は PersistenceService.saveSettings / loadSettings で settings.json に書き出す。

import '../data/prompts.dart';
import '../theme/tokens.dart';

/// Flote の永続化されたアプリ設定。
///
/// 機微情報 (Claude API キー) はここには含めない (keychain に別管理)。
class AppSettings {
  const AppSettings({
    required this.ollamaUrl,
    required this.ollamaModel,
    required this.alwaysOnTopOnLaunch,
    required this.promptPreset,
    required this.promptCustomText,
    this.customShortcuts = const <String, String>{},
    this.fontFamily = AppFontFamily.hiraginoSans,
  });

  /// Ollama HTTP 推論エンドポイント (既定 `http://localhost:11434/api/generate`)。
  final String ollamaUrl;

  /// Ollama モデル名 (既定 `gemma3:12b`)。
  final String ollamaModel;

  /// 起動時にメインウィンドウを最前面に出すかどうか。
  final bool alwaysOnTopOnLaunch;

  /// 使用中のプロンプト preset。
  final PromptPreset promptPreset;

  /// custom preset 選択時に使うユーザー編集プロンプト本文。
  final String promptCustomText;

  /// ユーザーがリバインドしたグローバルホットキー (Sprint 5 Round 2 Feature 5.4)。
  ///
  /// - キー: `ShortcutSlot.name` (newNote / openGroups / archive)
  /// - 値:   `modifiers+key` 形式の文字列。例 `alt+space`, `ctrl+alt+g`, `meta+w`
  /// - modifiers は `["shift","ctrl","alt","meta"]` の順序非依存
  /// - key は LogicalKeyboardKey の keyLabel を小文字化したもの
  ///
  /// 空の entry はデフォルト使用を意味する。AppSettings には値だけ持ち、
  /// HotKey への変換は HotkeyCombo.tryParse が行う。
  final Map<String, String> customShortcuts;

  /// Phase 2 視覚移植: 本文フォントファミリ選択 (SwiftUI `AppFont` 対応)。
  ///
  /// 既定は hiraginoSans (SwiftUI 側も同じ)。UserDefaults / settings.json の
  /// 旧キー `floteFontFamily` の値と互換。
  final AppFontFamily fontFamily;

  /// 既定値。初回起動時など settings.json が無いときに使う。
  static AppSettings defaults() {
    return const AppSettings(
      ollamaUrl: 'http://localhost:11434/api/generate',
      ollamaModel: 'gemma3:12b',
      alwaysOnTopOnLaunch: false,
      promptPreset: PromptPreset.standard,
      promptCustomText: promptCustomDefault,
      customShortcuts: <String, String>{},
      fontFamily: AppFontFamily.hiraginoSans,
    );
  }

  AppSettings copyWith({
    String? ollamaUrl,
    String? ollamaModel,
    bool? alwaysOnTopOnLaunch,
    PromptPreset? promptPreset,
    String? promptCustomText,
    Map<String, String>? customShortcuts,
    AppFontFamily? fontFamily,
  }) {
    return AppSettings(
      ollamaUrl: ollamaUrl ?? this.ollamaUrl,
      ollamaModel: ollamaModel ?? this.ollamaModel,
      alwaysOnTopOnLaunch: alwaysOnTopOnLaunch ?? this.alwaysOnTopOnLaunch,
      promptPreset: promptPreset ?? this.promptPreset,
      promptCustomText: promptCustomText ?? this.promptCustomText,
      customShortcuts: customShortcuts ?? this.customShortcuts,
      fontFamily: fontFamily ?? this.fontFamily,
    );
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final defaults = AppSettings.defaults();
    final shortcutsRaw = json['customShortcuts'];
    final shortcuts = <String, String>{};
    if (shortcutsRaw is Map) {
      shortcutsRaw.forEach((k, v) {
        if (k is String && v is String && v.trim().isNotEmpty) {
          shortcuts[k] = v.trim();
        }
      });
    }
    // Phase 2: 旧 SwiftUI 側の UserDefaults key 'floteFontFamily' とも互換に。
    // 新キー fontFamily を優先、なければ旧キーを見る。不明値は既定。
    final rawFontFamily = json['fontFamily'] as String? ??
        json['floteFontFamily'] as String?;
    return AppSettings(
      ollamaUrl: _nonEmptyString(json['ollamaUrl']) ?? defaults.ollamaUrl,
      ollamaModel: _nonEmptyString(json['ollamaModel']) ?? defaults.ollamaModel,
      alwaysOnTopOnLaunch: json['alwaysOnTopOnLaunch'] is bool
          ? json['alwaysOnTopOnLaunch'] as bool
          : defaults.alwaysOnTopOnLaunch,
      promptPreset: parsePromptPreset(
        json['promptPreset'] as String? ?? '',
      ),
      promptCustomText: _nonEmptyString(json['promptCustomText']) ??
          defaults.promptCustomText,
      customShortcuts: shortcuts,
      fontFamily: AppFontFamily.fromName(rawFontFamily),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ollamaUrl': ollamaUrl,
      'ollamaModel': ollamaModel,
      'alwaysOnTopOnLaunch': alwaysOnTopOnLaunch,
      'promptPreset': promptPreset.name,
      'promptCustomText': promptCustomText,
      'customShortcuts': customShortcuts,
      'fontFamily': fontFamily.persistenceKey,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! AppSettings) {
      return false;
    }
    if (other.ollamaUrl != ollamaUrl ||
        other.ollamaModel != ollamaModel ||
        other.alwaysOnTopOnLaunch != alwaysOnTopOnLaunch ||
        other.promptPreset != promptPreset ||
        other.promptCustomText != promptCustomText ||
        other.fontFamily != fontFamily) {
      return false;
    }
    if (other.customShortcuts.length != customShortcuts.length) {
      return false;
    }
    for (final entry in customShortcuts.entries) {
      if (other.customShortcuts[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        ollamaUrl,
        ollamaModel,
        alwaysOnTopOnLaunch,
        promptPreset,
        promptCustomText,
        fontFamily,
        Object.hashAllUnordered(
          customShortcuts.entries.map((e) => '${e.key}=${e.value}'),
        ),
      );
}

String? _nonEmptyString(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}
