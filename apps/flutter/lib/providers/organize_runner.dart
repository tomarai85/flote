// OrganizeRunner (Sprint 5 Feature 5.1)。
//
// ノートウィンドウ側 (サブ engine) で、「整理ボタン」が押された時の
// 非同期処理・ローディング表示・Undo stack を管理する。
//
// 責務:
// - AppSettings + KeychainService を読み込んで OrganizeService に渡す
// - 実行中 state (isRunning, lastError) を UI に公開
// - 実行前の richText / plainText を undo stack に積む
// - ⌘Z/Ctrl+Z (あるいは UI の元に戻すボタン) で最新の undo エントリを復元
// - Organize 中にノートが削除された場合: 結果を破棄 (削除済みノートに書き戻さない)

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/prompts.dart';
import '../models/app_settings.dart';
import '../services/keychain_service.dart';
import '../services/organize_service.dart';

/// UI から呼び出す Organize Runner の状態。
class OrganizeRunState {
  const OrganizeRunState({
    this.isRunning = false,
    this.route,
    this.lastError,
    this.lastSuccessAt,
  });

  final bool isRunning;
  final OrganizeRoute? route;
  final OrganizeRunError? lastError;
  final DateTime? lastSuccessAt;

  OrganizeRunState copyWith({
    bool? isRunning,
    OrganizeRoute? route,
    OrganizeRunError? lastError,
    DateTime? lastSuccessAt,
    bool clearError = false,
  }) {
    return OrganizeRunState(
      isRunning: isRunning ?? this.isRunning,
      route: route ?? this.route,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    );
  }
}

class OrganizeRunError {
  const OrganizeRunError({required this.kind, required this.message});
  final OrganizeErrorKind kind;
  final String message;
}

/// undo stack の 1 エントリ。Organize 前の richText + plainText を保持する。
class OrganizeUndoEntry {
  const OrganizeUndoEntry({
    required this.noteId,
    required this.savedAt,
    required this.richTextBefore,
    required this.plainTextBefore,
  });
  final String noteId;
  final DateTime savedAt;
  final String richTextBefore;
  final String plainTextBefore;
}

/// Organize 結果を UI 側 (NoteWindowNotifier) に反映するための callback。
typedef OrganizeApplyCallback = Future<void> Function(
  String richText,
  String plainText,
);

/// KeychainService provider (settings_window でも使う)。
final keychainServiceProvider = Provider<KeychainService>((ref) {
  return KeychainService();
});

/// OrganizeService provider。keychain を依存に取る。
final organizeServiceProvider = Provider<OrganizeService>((ref) {
  final keychain = ref.read(keychainServiceProvider);
  return OrganizeService(keychain: keychain);
});

/// OrganizeRunner の state provider。1 サブウィンドウにつき 1 つ。
///
/// サブ engine 側から `ref.read(organizeRunnerProvider.notifier).run(...)` で
/// 起動する。メイン engine では使わない (メイン側では batchClassify 用に別 runner)。
final organizeRunnerProvider =
    NotifierProvider<OrganizeRunner, OrganizeRunState>(
  OrganizeRunner.new,
);

class OrganizeRunner extends Notifier<OrganizeRunState> {
  final List<OrganizeUndoEntry> _undoStack = <OrganizeUndoEntry>[];

  /// undo stack の最大長。付箋アプリのシンプルな UX のため 20 件で十分。
  static const int _maxUndoEntries = 20;

  @override
  OrganizeRunState build() {
    ref.onDispose(() {
      _undoStack.clear();
    });
    return const OrganizeRunState();
  }

  /// undo stack のコピー (テスト用)。
  List<OrganizeUndoEntry> get undoStackSnapshot =>
      List.unmodifiable(_undoStack);

  /// 指定ノートの Organize 前 richText を復元可能なら true。
  bool canUndoFor(String noteId) =>
      _undoStack.any((e) => e.noteId == noteId);

  /// Organize を実行する。
  ///
  /// - `richTextBefore` / `plainTextBefore` は呼び出し元 (NoteWindowShell) が
  ///   現在の state から取得して渡す。`run` 内で undo stack に積む
  /// - `apply` は成功時にのみ呼ぶ (richText, plainText を NoteWindowNotifier に反映)
  /// - `isNoteAlive` は結果適用前に呼び、false なら apply をスキップ (削除対策)
  Future<OrganizeResult> run({
    required String noteId,
    required String richTextBefore,
    required String plainTextBefore,
    required AppSettings settings,
    required OrganizeApplyCallback apply,
    required FutureOr<bool> Function() isNoteAlive,
  }) async {
    if (state.isRunning) {
      // 既に走っている: 多重実行抑止。
      return const OrganizeFailure(
        OrganizeErrorKind.network,
        '整理処理が既に実行中です。',
      );
    }
    // 空入力は即失敗。
    if (plainTextBefore.trim().isEmpty) {
      final failure = const OrganizeFailure(
        OrganizeErrorKind.parse,
        '整理するテキストがありません。',
      );
      state = state.copyWith(
        isRunning: false,
        lastError: OrganizeRunError(
          kind: failure.kind,
          message: failure.message,
        ),
      );
      return failure;
    }

    state = state.copyWith(isRunning: true, clearError: true);

    final service = ref.read(organizeServiceProvider);
    final keychain = ref.read(keychainServiceProvider);
    bool hasKey = false;
    try {
      hasKey = await keychain.hasClaudeApiKey();
    } catch (_) {
      hasKey = false;
    }
    final route = decideRoute(
      plainText: plainTextBefore.length > kOrganizeInputMaxLength
          ? plainTextBefore.substring(0, kOrganizeInputMaxLength)
          : plainTextBefore,
      hasClaudeKey: hasKey,
    );

    state = state.copyWith(isRunning: true, route: route);

    // 実行前の状態を undo stack に積む (失敗時も積んでおくと、誤タップで消えても戻せる)。
    _pushUndo(
      OrganizeUndoEntry(
        noteId: noteId,
        savedAt: DateTime.now(),
        richTextBefore: richTextBefore,
        plainTextBefore: plainTextBefore,
      ),
    );

    OrganizeResult result;
    try {
      result = await service.organize(
        plainText: plainTextBefore,
        settings: settings,
      );
    } catch (error, stackTrace) {
      stderr.writeln('OrganizeRunner.run service threw: $error\n$stackTrace');
      result = OrganizeFailure(
        OrganizeErrorKind.network,
        '不明なエラーが発生しました: $error',
      );
    }

    // Organize 中にノートが削除されていたら結果を破棄する。
    // M0 audit fix: isNoteAlive 自体が dispose 済 provider を参照して
    // StateError を投げる可能性があるので catch して dead 扱い。
    bool alive = false;
    try {
      alive = await isNoteAlive();
    } catch (error, stackTrace) {
      stderr.writeln(
        'OrganizeRunner.isNoteAlive threw (treating as dead): $error\n$stackTrace',
      );
      alive = false;
    }
    if (!alive) {
      state = state.copyWith(
        isRunning: false,
        clearError: true,
      );
      return const OrganizeFailure(
        OrganizeErrorKind.parse,
        'ノートが削除されたため結果を適用しません。',
      );
    }

    switch (result) {
      case OrganizeSuccess():
        try {
          await apply(result.richText, result.plainText);
        } catch (error) {
          stderr.writeln('OrganizeRunner.apply failed: $error');
        }
        state = state.copyWith(
          isRunning: false,
          lastSuccessAt: DateTime.now(),
          clearError: true,
        );
      case OrganizeFailure():
        state = state.copyWith(
          isRunning: false,
          lastError: OrganizeRunError(
            kind: result.kind,
            message: result.message,
          ),
        );
    }
    return result;
  }

  /// `noteId` の最新 undo エントリを pop して返す。なければ null。
  /// UI 側は返り値の richText/plainText を NoteWindowNotifier.updateRichText に流し込む。
  OrganizeUndoEntry? popUndo(String noteId) {
    for (var i = _undoStack.length - 1; i >= 0; i--) {
      if (_undoStack[i].noteId == noteId) {
        final entry = _undoStack.removeAt(i);
        return entry;
      }
    }
    return null;
  }

  void _pushUndo(OrganizeUndoEntry entry) {
    _undoStack.add(entry);
    if (_undoStack.length > _maxUndoEntries) {
      _undoStack.removeAt(0);
    }
  }

  /// エラー表示をクリア (バナー閉じる時に UI から呼ぶ)。
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  /// M0 audit Wave 4 (138s UX): UI cancel button から呼ぶ。
  /// 進行中の retry を次 attempt 前に断ち切り、`OrganizeFailure(cancelled, ...)`
  /// が返って state.isRunning=false になる。
  /// state が isRunning でなければ no-op (idempotent)。
  void cancel() {
    if (!state.isRunning) return;
    ref.read(organizeServiceProvider).cancelCurrent();
  }
}
