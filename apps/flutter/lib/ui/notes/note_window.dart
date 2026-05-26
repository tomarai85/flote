// 個別の付箋サブウィンドウ (Sprint 3 Feature 3.1-3.5 で本実装)。
//
// desktop_multi_window で独立 OS ウィンドウとして開き、3 状態 (expanded/rolledUp/mini)
// のいずれかを描画する。Sprint 1 では空のプレースホルダのみ。

import 'package:flutter/material.dart';

/// 付箋サブウィンドウの root widget。
class NoteWindow extends StatelessWidget {
  const NoteWindow({super.key, required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context) {
    // Sprint 3 で NoteManager から note を引き、stowState に応じた View を返す。
    return const Scaffold(
      body: Center(
        child: Text('Sprint 3 Feature 3.1-3.5 で実装'),
      ),
    );
  }
}
