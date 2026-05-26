// AI 整理用のプロンプトテンプレートを集約する定数ファイル。
//
// プリセット選択 UI と OrganizeService から共通利用し、
// ルーティングしきい値もここで一元管理する。

/// プロンプトプリセット。
enum PromptPreset { concise, standard, custom }

extension PromptPresetX on PromptPreset {
  /// UI 表示用の日本語ラベル。
  String get displayName {
    switch (this) {
      case PromptPreset.concise:
        return '簡潔';
      case PromptPreset.standard:
        return '標準';
      case PromptPreset.custom:
        return 'カスタム';
    }
  }
}

/// 表示名から enum.name 文字列へ逆変換する。
String parseDisplayNameToPreset(String displayName) {
  for (final preset in PromptPreset.values) {
    if (preset.displayName == displayName) {
      return preset.name;
    }
  }
  return PromptPreset.standard.name;
}

/// enum.name からプリセットを復元する。
PromptPreset parsePromptPreset(String name) {
  for (final preset in PromptPreset.values) {
    if (preset.name == name) {
      return preset;
    }
  }
  return PromptPreset.standard;
}

/// Organize 入力の最大文字数。
const int kOrganizeInputMaxLength = 10000;

/// Claude へ切り替える文字数しきい値。
const int kClaudeRouteCharThreshold = 200;

/// Claude へ切り替える行数しきい値。
const int kClaudeRouteLineThreshold = 5;

/// 短文メモ向けの簡潔プリセット。
const String promptConcise = '''
以下のメモを簡潔に整えてください。要点を1〜3行に圧縮し、冗長表現を削除。箇条書きは維持。
意味が重複する文はまとめる。
固有名詞、日時、数値は残す。
結論や依頼事項があれば先頭に置く。
推測や補足は加えない。
元の言語とトーンは保つ。
''';

/// 通常メモ向けの標準プリセット。
const String promptStandard = '''
以下のメモを読みやすく整えてください。段落と箇条書きを適切に使い、主題を保ったまま構造化する。原文の意図は変えない。
冒頭に短い要約が必要なら1文だけ追加する。
話題ごとに段落を整理し、論点が混ざっている箇所は分離する。
列挙できる内容は箇条書きにする。
重複表現や言い直しは削除する。
曖昧な主語は、原文から判断できる範囲で明確にする。
日時、数値、タスク、決定事項は落とさない。
原文にない事実、推測、感想は追加しない。
読みやすさを上げても、ニュアンスはできるだけ保持する。
出力はそのままノートに貼れる自然な日本語にする。
''';

/// カスタム編集用の初期値。
const String promptCustomDefault =
    '$promptStandard\n[ここを編集して独自の指示を追加できます]';

/// プリセットに応じたプロンプト本文を返す。
String buildPromptForPreset(PromptPreset preset, String customText) {
  switch (preset) {
    case PromptPreset.concise:
      return promptConcise;
    case PromptPreset.standard:
      return promptStandard;
    case PromptPreset.custom:
      return customText;
  }
}
