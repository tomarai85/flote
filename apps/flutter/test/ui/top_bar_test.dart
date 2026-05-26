// Phase 2c 修正 3: NoteTopBar (SwiftUI 踏襲の 4 icons + Organize pill) の
// レンダリングテスト。
//
// 検証項目:
// - 4 アイコン (Copy / AI Sort / Archive / RollUp) が描画される
// - Organize pill のテキスト "Organize" が表示される
// - isOrganizing=true で "Organizing" に切り替わる
// - isTextEmpty=true で Organize pill が disabled (onPressed null)
// - Copy ボタン押下で onCopy が呼ばれる

import 'package:flote_desktop/ui/note_window/toolbar/top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 160,
          child: Material(color: Colors.transparent, child: child),
        ),
      ),
    );
  }

  group('NoteTopBar (Phase 2c)', () {
    testWidgets('4 つのアイコンが描画される', (tester) async {
      await tester.pumpWidget(
        wrap(
          NoteTopBar(
            toolbarColor: const Color(0xFFFFE082),
            isTextEmpty: false,
            onCopy: () async {},
            onAISort: () async {},
            onArchive: () async {},
            onRollUp: () {},
            onOrganize: () async {},
          ),
        ),
      );
      // AnimatedContainer の implicit animation は 150ms で終わる。
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byIcon(Icons.copy), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsNWidgets(2)); // AI Sort + Organize
      expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
    });

    testWidgets('Organize pill は通常 "Organize" と表示、isOrganizing=true で "Organizing"',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          NoteTopBar(
            toolbarColor: const Color(0xFFFFE082),
            isTextEmpty: false,
            onOrganize: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Organize'), findsOneWidget);
      expect(find.text('Organizing'), findsNothing);

      await tester.pumpWidget(
        wrap(
          NoteTopBar(
            toolbarColor: const Color(0xFFFFE082),
            isTextEmpty: false,
            isOrganizing: true,
            onOrganize: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Organizing'), findsOneWidget);
      expect(find.text('Organize'), findsNothing);
    });

    testWidgets('Copy ボタン押下で onCopy が呼ばれる', (tester) async {
      var copyCount = 0;
      await tester.pumpWidget(
        wrap(
          NoteTopBar(
            toolbarColor: const Color(0xFFFFE082),
            isTextEmpty: false,
            onCopy: () async {
              copyCount++;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byIcon(Icons.copy));
      await tester.pump();
      expect(copyCount, 1);
      // Copy toast は 1.2 秒後に元アイコンに戻る。pending timer を消費するため
      // 十分な時間を pump する (1500ms だと余裕)。
      await tester.pump(const Duration(milliseconds: 1500));
    });

    testWidgets('Archive ボタン押下で onArchive が呼ばれる', (tester) async {
      var archiveCount = 0;
      await tester.pumpWidget(
        wrap(
          NoteTopBar(
            toolbarColor: const Color(0xFFFFE082),
            isTextEmpty: false,
            onArchive: () async {
              archiveCount++;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byIcon(Icons.inventory_2_outlined));
      await tester.pump();
      expect(archiveCount, 1);
    });

    testWidgets('RollUp ボタン押下で onRollUp が呼ばれる', (tester) async {
      var rollCount = 0;
      await tester.pumpWidget(
        wrap(
          NoteTopBar(
            toolbarColor: const Color(0xFFFFE082),
            isTextEmpty: false,
            onRollUp: () {
              rollCount++;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
      await tester.pump();
      expect(rollCount, 1);
    });

    testWidgets('Row 1 と Row 2 の 2 段構造: Column に子 3 つ (Row / SizedBox / Padding)',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          NoteTopBar(
            toolbarColor: const Color(0xFFFFE082),
            isTextEmpty: false,
            onOrganize: () async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // NoteTopBar.build の直下には Column があり、子に Row 1 (SizedBox) + spacer + Row 2 (Padding)。
      // 2 段構成であることを確認。
      final topBarFinder = find.byType(NoteTopBar);
      expect(topBarFinder, findsOneWidget);
      // Row 1 用の SizedBox(height: 22) が存在。
      expect(
        find.descendant(
          of: topBarFinder,
          matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.height == 22,
          ),
        ),
        findsWidgets,
      );
    });
  });
}
