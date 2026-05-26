// Sprint 5: プロンプトプリセットのユーティリティテスト。

import 'package:flote_desktop/data/prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PromptPreset', () {
    test('displayName は各 preset に対して日本語ラベル', () {
      expect(PromptPreset.concise.displayName, '簡潔');
      expect(PromptPreset.standard.displayName, '標準');
      expect(PromptPreset.custom.displayName, 'カスタム');
    });

    test('parsePromptPreset: enum.name から復元', () {
      expect(parsePromptPreset('concise'), PromptPreset.concise);
      expect(parsePromptPreset('standard'), PromptPreset.standard);
      expect(parsePromptPreset('custom'), PromptPreset.custom);
      expect(parsePromptPreset('xxx'), PromptPreset.standard);
    });

    test('parseDisplayNameToPreset: 表示名から name を返す', () {
      expect(parseDisplayNameToPreset('簡潔'), 'concise');
      expect(parseDisplayNameToPreset('xxx'), 'standard');
    });

    test('buildPromptForPreset は preset に応じて本文を返す', () {
      expect(buildPromptForPreset(PromptPreset.concise, 'ignored'),
          promptConcise);
      expect(buildPromptForPreset(PromptPreset.standard, 'ignored'),
          promptStandard);
      expect(buildPromptForPreset(PromptPreset.custom, 'my custom'),
          'my custom');
    });

    test('定数しきい値は spec に従う', () {
      expect(kOrganizeInputMaxLength, 10000);
      expect(kClaudeRouteCharThreshold, 200);
      expect(kClaudeRouteLineThreshold, 5);
    });
  });
}
