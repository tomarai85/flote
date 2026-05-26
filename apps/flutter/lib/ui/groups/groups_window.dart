// Groups ウィンドウ (Sprint 5 Feature 5.4 の Groups タブで本実装)。
//
// 2 ペイン (左: グループツリー、右: ノート一覧) + 作成/リネーム/削除 UI。

import 'package:flutter/material.dart';

/// Groups ウィンドウの root widget。
class GroupsWindow extends StatelessWidget {
  const GroupsWindow({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text('Sprint 5 Feature 5.4 (Groups タブ) で実装'),
      ),
    );
  }
}
