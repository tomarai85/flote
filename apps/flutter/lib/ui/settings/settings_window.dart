// Settings ウィンドウ本体 (Sprint 5 Feature 5.4)。
//
// サイドバー (幅 178px) + メイン領域の 2 ペイン構造。6 セクション切替。
// 呼び出し元: メインウィンドウ から desktop_multi_window 経由でサブウィンドウ起動
//            するか、メインウィンドウ内の overlay として表示。MVP では後者 (Navigator
//            push 相当) で実装し、将来 desktop_multi_window で別ウィンドウ化可能な
//            ように SettingsWindow Widget として独立させる。
//
// 各セクションの callback は SettingsController 経由で差し込み、provider / service
// への依存はここで解決する。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import '../../data/prompts.dart';
import '../../models/app_settings.dart';
import '../../models/history_entry.dart';
import '../../models/note_group.dart';
import '../../providers/app_settings.dart';
import '../../providers/group_manager.dart';
import '../../providers/history_manager.dart';
import '../../providers/note_manager.dart';
import '../../providers/organize_runner.dart';
import '../../services/hotkey_service.dart';
import '../../services/organize_service.dart';
import '../../theme/tokens.dart';
import 'sections/ai_section.dart';
import 'sections/general_section.dart';
import 'sections/groups_section.dart';
import 'sections/history_section.dart';
import 'sections/prompt_section.dart';
import 'sections/shortcuts_section.dart';

/// Settings のサイドバー選択項目。
enum SettingsTab {
  general,
  shortcuts,
  ai,
  groups,
  history,
  prompt,
}

extension SettingsTabX on SettingsTab {
  String get title {
    switch (this) {
      case SettingsTab.general:
        return 'General';
      case SettingsTab.shortcuts:
        return 'Shortcuts';
      case SettingsTab.ai:
        return 'AI Organize';
      case SettingsTab.groups:
        return 'Groups';
      case SettingsTab.history:
        return 'History';
      case SettingsTab.prompt:
        return 'Prompt';
    }
  }

  IconData get icon {
    switch (this) {
      case SettingsTab.general:
        return Icons.tune_outlined;
      case SettingsTab.shortcuts:
        return Icons.keyboard_outlined;
      case SettingsTab.ai:
        return Icons.auto_awesome_outlined;
      case SettingsTab.groups:
        return Icons.folder_outlined;
      case SettingsTab.history:
        return Icons.history_outlined;
      case SettingsTab.prompt:
        return Icons.edit_note_outlined;
    }
  }
}

class SettingsWindow extends ConsumerStatefulWidget {
  const SettingsWindow({
    super.key,
    this.onRequestClose,
    this.onReloadHotkeys,
  });

  /// ウィンドウ全体を閉じたいときに呼ぶ。null なら非表示にしない。
  final VoidCallback? onRequestClose;

  /// ショートカットを保存した後、メイン側に再登録を指示するコールバック。
  /// null の場合は Settings 内でのホットキー登録のみ行う (テスト用)。
  final Future<void> Function()? onReloadHotkeys;

  @override
  ConsumerState<SettingsWindow> createState() => _SettingsWindowState();
}

class _SettingsWindowState extends ConsumerState<SettingsWindow> {
  SettingsTab _active = SettingsTab.general;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ColorTokens.surface,
      body: SafeArea(
        child: Row(
          children: [
            _Sidebar(
              active: _active,
              onSelect: (tab) => setState(() => _active = tab),
              onClose: widget.onRequestClose,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(SpacingTokens.lg),
                child: _buildActive(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActive(BuildContext context) {
    switch (_active) {
      case SettingsTab.general:
        return GeneralSection(onRestart: _handleRestart);
      case SettingsTab.shortcuts:
        return ShortcutsSection(
          onRebind: _handleRebind,
          onReset: _handleResetShortcuts,
          currentComboFor: _currentComboForSlot,
        );
      case SettingsTab.ai:
        return AISection(
          onSave: _handleAISave,
          onDelete: _handleAIDelete,
          onTestOllama: _handleTestOllama,
          onTestClaude: _handleTestClaude,
        );
      case SettingsTab.groups:
        return GroupsSection(
          onCreateGroup: _handleCreateGroup,
          onRenameGroup: _handleRenameGroup,
          onDeleteGroup: _handleDeleteGroup,
          onBatchClassify: _handleBatchClassify,
        );
      case SettingsTab.history:
        return HistorySection(
          onRestore: _handleRestoreHistory,
          onPermanentDelete: _handlePermanentDeleteHistory,
          onClearAll: _handleClearAllHistory,
        );
      case SettingsTab.prompt:
        return PromptSection(onSaved: _handlePromptSaved);
    }
  }

  // ===== General =====
  Future<void> _handleRestart() async {
    // MVP: 実際の再起動は OS 側操作が必要なため、ユーザーに手動操作を促す。
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content:
            Text('アプリを一度終了して再起動してください (Quit -> 再度起動)'),
      ),
    );
  }

  // ===== Shortcuts (Sprint 5 Round 2) =====

  HotkeySlot _toHotkeySlot(ShortcutSlot slot) {
    switch (slot) {
      case ShortcutSlot.newNote:
        return HotkeySlot.newNote;
      case ShortcutSlot.openGroups:
        return HotkeySlot.openGroups;
      case ShortcutSlot.archive:
        return HotkeySlot.archive;
    }
  }

  /// Shortcuts セクションが表示する「現在のキー組み合わせ」を返す。
  /// 保存済みのユーザー設定があればそれ、なければ slot のデフォルトを使う。
  String _currentComboForSlot(ShortcutSlot slot) {
    final hk = _toHotkeySlot(slot);
    final settings = ref.read(appSettingsProvider).value;
    final saved = settings?.customShortcuts[hk.slotKey];
    final raw = (saved != null && saved.isNotEmpty) ? saved : hk.defaultCombo();
    final combo = HotkeyCombo.tryParse(raw);
    if (combo == null) {
      return raw; // fallback: 生 string を表示
    }
    return combo.toHumanLabel();
  }

  Future<void> _handleRebind(ShortcutSlot slot) async {
    final hk = _toHotkeySlot(slot);
    final newCombo = await _showRebindDialog(hk);
    if (newCombo == null) {
      return; // キャンセル
    }
    // AppSettings に保存。AsyncValue.value は nullable だが build 完了後は必ず値あり。
    final currentOrNull = ref.read(appSettingsProvider).value;
    final AppSettings current =
        currentOrNull ?? await ref.read(appSettingsProvider.future);
    final newMap = <String, String>{
      ...current.customShortcuts,
      hk.slotKey: newCombo.toComboString(),
    };
    await ref.read(appSettingsProvider.notifier).saveCustomShortcutsNow(newMap);

    // メイン engine 側で再登録を依頼 (Settings と main は別 engine ではないが、
    // 他 engine から呼び出すケースに備え callback 経由で実行)。
    try {
      if (widget.onReloadHotkeys != null) {
        await widget.onReloadHotkeys!();
      } else {
        // fallback: HotkeyService Provider で直接 registerSlot する。
        final service = ref.read(hotkeyServiceProvider);
        await service.registerSlot(
          slot: hk,
          combo: newCombo,
          onTrigger: () {},
        );
      }
    } catch (error) {
      debugPrint('reloadHotkeys after rebind failed: $error');
    }

    if (!mounted) return;
    final conflicts = defaultConflictCombos();
    final comboText = newCombo.toComboString();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          conflicts.contains(comboText)
              ? '${hk.displayName}: ${newCombo.toHumanLabel()} に保存しました '
                  '(OS 標準と衝突する可能性あり)'
              : '${hk.displayName}: ${newCombo.toHumanLabel()} に保存しました',
        ),
      ),
    );
  }

  Future<void> _handleResetShortcuts() async {
    final currentOrNull = ref.read(appSettingsProvider).value;
    final AppSettings current =
        currentOrNull ?? await ref.read(appSettingsProvider.future);
    final isAlreadyEmpty = current.customShortcuts.isEmpty;
    if (!mounted) return;
    if (isAlreadyEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('ショートカットは既に標準設定です')),
      );
      return;
    }
    await ref
        .read(appSettingsProvider.notifier)
        .saveCustomShortcutsNow(const <String, String>{});
    try {
      if (widget.onReloadHotkeys != null) {
        await widget.onReloadHotkeys!();
      }
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('ショートカットを標準に戻しました')),
    );
  }

  /// 「変更...」ボタン押下時にキーキャプチャダイアログを出し、
  /// ユーザーが修飾子 + キーを押すまで待つ。キャンセル時は null。
  Future<HotkeyCombo?> _showRebindDialog(HotkeySlot slot) async {
    return showDialog<HotkeyCombo>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _RebindDialog(slot: slot),
    );
  }

  // ===== AI =====
  Future<void> _handleAISave(
    String ollamaUrl,
    String ollamaModel,
    String? claudeApiKey,
  ) async {
    // AppSettings 保存。
    await ref.read(appSettingsProvider.notifier).saveAiEndpointNow(
          ollamaUrl: ollamaUrl,
          ollamaModel: ollamaModel,
        );
    // Claude API キー保存 (null なら削除、空文字なら何もしない)。
    final keychain = ref.read(keychainServiceProvider);
    if (claudeApiKey == null) {
      // 明示削除ではなく「今回は更新しない」扱い。現在の値は保持。
      return;
    }
    if (claudeApiKey.isEmpty) {
      // 空 -> 削除する (UI 側で delete ボタンを押した方がクリアだが、両対応)。
      await keychain.deleteClaudeApiKey();
      return;
    }
    await keychain.saveClaudeApiKey(claudeApiKey);
  }

  Future<void> _handleAIDelete() async {
    final keychain = ref.read(keychainServiceProvider);
    await keychain.deleteClaudeApiKey();
  }

  Future<String> _handleTestOllama(String url, String model) async {
    final service = ref.read(organizeServiceProvider);
    final result = await service.testOllama(url: url, model: model);
    switch (result) {
      case OrganizeSuccess():
        return 'Ollama 接続 OK';
      case OrganizeFailure():
        return 'Ollama エラー [${result.kind.name}]: ${result.message}';
    }
  }

  Future<String> _handleTestClaude(String? key) async {
    if (key == null || key.isEmpty) {
      // 保存済みのキーをテストする。
      final keychain = ref.read(keychainServiceProvider);
      final saved = await keychain.loadClaudeApiKey();
      if (saved == null || saved.isEmpty) {
        return 'Claude API キーが設定されていません';
      }
      key = saved;
    }
    final service = ref.read(organizeServiceProvider);
    final result = await service.testClaude(apiKey: key);
    switch (result) {
      case OrganizeSuccess():
        return 'Claude 接続 OK';
      case OrganizeFailure():
        return 'Claude エラー [${result.kind.name}]: ${result.message}';
    }
  }

  // ===== Groups =====
  Future<void> _handleCreateGroup() async {
    // M0 audit fix: TextEditingController を try/finally で必ず dispose
    // (showDialog 後に dispose しないと dialog open 毎の leak)。
    final controller = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('新規グループ'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'グループ名'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('作成'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final name = controller.text.trim();
      if (name.isEmpty) return;
      await ref
          .read(groupManagerProvider.notifier)
          .createGroup(name: name, iconName: 'folder');
    } finally {
      controller.dispose();
    }
  }

  Future<void> _handleRenameGroup(NoteGroup group) async {
    // M0 audit fix: dialog dismissal / exception いずれでも controller を dispose
    final controller = TextEditingController(text: group.name);
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('グループをリネーム'),
          content: TextField(
            controller: controller,
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final newName = controller.text.trim();
      if (newName.isEmpty) return;
      await ref
          .read(groupManagerProvider.notifier)
          .renameGroup(group.id, newName);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _handleDeleteGroup(NoteGroup group) async {
    if (group.id == NoteGroup.inboxId) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${group.name} を削除しますか'),
        content: const Text('子グループは root に昇格し、子ノートは Inbox に移動します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(groupManagerProvider.notifier).deleteGroup(group.id);
  }

  Future<void> _handleBatchClassify() async {
    final notesAsync = ref.read(noteManagerProvider);
    final notes = notesAsync.value ?? const [];
    final inboxNotes =
        notes.where((n) => n.groupID == NoteGroup.inboxId).toList();
    if (inboxNotes.length < 2) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Inbox に 2 件以上のノートが必要です')),
      );
      return;
    }

    // Sprint 5 Round 2: OrganizeService.batchClassify を呼んで AI 分類する。
    // 既存グループ (Inbox を除外) のリストを LLM に提示し、
    // 合致すれば ID 解決、合致しなければ新規グループ名を提案させる。
    final groupsAsync = ref.read(groupManagerProvider);
    final groups = groupsAsync.value ?? const [];
    final existingGroups = groups
        .where((g) => g.id != NoteGroup.inboxId)
        .map((g) => ClassifyGroup(id: g.id, name: g.name))
        .toList(growable: false);

    final requests = inboxNotes
        .map((n) => ClassifyRequest(noteId: n.id, text: n.text))
        .toList(growable: false);

    final settings = ref.read(appSettingsProvider).value;
    if (settings == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('設定の読み込みが完了していません。少し待って再試行してください。')),
      );
      return;
    }

    // 実行中表示。
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Inbox を分類中...'),
        duration: Duration(seconds: 2),
      ),
    );

    final service = ref.read(organizeServiceProvider);
    final result = await service.batchClassify(
      requests: requests,
      existingGroups: existingGroups,
      settings: settings,
    );

    // 新規グループを作成し、placeholder を実 ID に置換する。
    final newGroupIdByName = <String, String>{};
    for (final name in result.newGroupNames) {
      try {
        final created = await ref
            .read(groupManagerProvider.notifier)
            .createGroup(name: name, iconName: 'folder');
        newGroupIdByName[name] = created.id;
      } catch (error) {
        // グループ作成に失敗したら、そのグループに割り当てられる予定の noteId を
        // 全て parse 失敗扱いに昇格させる (これ以上 assign できないため)。
        debugPrint('createGroup failed for "$name": $error');
      }
    }

    final finalMapping = <String, String?>{};
    final unresolved = <String>{};
    for (final entry in result.assignments.entries) {
      final raw = entry.value;
      if (raw.startsWith('__new__:')) {
        final name = raw.substring('__new__:'.length);
        final id = newGroupIdByName[name];
        if (id != null) {
          finalMapping[entry.key] = id;
        } else {
          unresolved.add(entry.key);
        }
      } else {
        finalMapping[entry.key] = raw;
      }
    }

    if (finalMapping.isNotEmpty) {
      await ref
          .read(noteManagerProvider.notifier)
          .assignNotesToGroups(finalMapping);
    }

    // failures + unresolved を統合してサマリを作る。
    final allFailures = <String, OrganizeErrorKind>{
      ...result.failures,
      for (final id in unresolved) id: OrganizeErrorKind.server,
    };
    final successCount = finalMapping.length;
    final failureCount = allFailures.length;
    final failureSummary = allFailures.isEmpty
        ? ''
        : '\n失敗内訳: ${_summarizeFailures(allFailures)}';
    if (!mounted) return;

    // 結果ダイアログ (spec 要件: 失敗件数 + エラー内訳表示)。
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Inbox 整理の結果'),
        content: Text(
          '成功: $successCount 件\n'
          '新規グループ: ${newGroupIdByName.length} 件 '
          '(要求 ${result.newGroupNames.length} 件)\n'
          '失敗: $failureCount 件$failureSummary',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _summarizeFailures(Map<String, OrganizeErrorKind> failures) {
    final counts = <OrganizeErrorKind, int>{};
    for (final kind in failures.values) {
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
    return counts.entries.map((e) => '${e.key.name}=${e.value}').join(' ');
  }

  // ===== History =====
  Future<void> _handleRestoreHistory(HistoryEntry entry) async {
    final ok = await ref
        .read(historyManagerProvider.notifier)
        .restoreToInbox(entry.id);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(ok ? 'Inbox に復元しました' : '復元に失敗しました')),
    );
  }

  Future<void> _handlePermanentDeleteHistory(HistoryEntry entry) async {
    await ref
        .read(historyManagerProvider.notifier)
        .permanentlyDelete(entry.id);
  }

  Future<void> _handleClearAllHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全ての履歴を削除しますか'),
        content: const Text('この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('全て削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(historyManagerProvider.notifier).clearAll();
  }

  // ===== Prompt =====
  Future<void> _handlePromptSaved(
    PromptPreset preset,
    String customText,
  ) async {
    await ref.read(appSettingsProvider.notifier).savePromptNow(
          preset: preset,
          customText: customText,
        );
  }
}

/// Rebind キーキャプチャダイアログ。
///
/// RawKeyboardListener で keyDown を捕捉し、「修飾子 1 つ以上 + 通常キー 1 つ」
/// の組み合わせが揃ったら HotkeyCombo を pop する。Esc 単独はキャンセル扱い。
class _RebindDialog extends StatefulWidget {
  const _RebindDialog({required this.slot});

  final HotkeySlot slot;

  @override
  State<_RebindDialog> createState() => _RebindDialogState();
}

class _RebindDialogState extends State<_RebindDialog> {
  final FocusNode _focusNode = FocusNode();
  HotkeyCombo? _captured;
  String? _hint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    // 修飾子だけの押下 (Shift/Ctrl/Alt/Meta) は capture しない。
    final logical = event.logicalKey;
    if (_isModifierKey(logical)) {
      return KeyEventResult.handled;
    }
    // Escape はキャンセル。
    if (logical == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop<HotkeyCombo?>(null);
      return KeyEventResult.handled;
    }
    // 現在の修飾子状態を HardwareKeyboard から読み取る。
    final hw = HardwareKeyboard.instance;
    final mods = <HotKeyModifier>{};
    if (hw.isShiftPressed) mods.add(HotKeyModifier.shift);
    if (hw.isControlPressed) mods.add(HotKeyModifier.control);
    if (hw.isAltPressed) mods.add(HotKeyModifier.alt);
    if (hw.isMetaPressed) mods.add(HotKeyModifier.meta);

    if (mods.isEmpty) {
      setState(() {
        _hint = '修飾キー (Shift/Ctrl/Alt/Meta) と同時押ししてください';
      });
      return KeyEventResult.handled;
    }

    setState(() {
      _captured = HotkeyCombo(modifiers: mods, logicalKey: logical);
      _hint = null;
    });
    return KeyEventResult.handled;
  }

  bool _isModifierKey(LogicalKeyboardKey k) {
    return k == LogicalKeyboardKey.shiftLeft ||
        k == LogicalKeyboardKey.shiftRight ||
        k == LogicalKeyboardKey.controlLeft ||
        k == LogicalKeyboardKey.controlRight ||
        k == LogicalKeyboardKey.altLeft ||
        k == LogicalKeyboardKey.altRight ||
        k == LogicalKeyboardKey.metaLeft ||
        k == LogicalKeyboardKey.metaRight;
  }

  @override
  Widget build(BuildContext context) {
    final captured = _captured;
    final preview = captured != null ? captured.toHumanLabel() : '—';
    final conflicts = defaultConflictCombos();
    final warn = captured != null &&
        conflicts.contains(captured.toComboString());
    return AlertDialog(
      title: Text('${widget.slot.displayName} のキーを変更'),
      content: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('新しいキーの組み合わせを押してください'),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  preview,
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 16,
                  ),
                ),
              ),
              if (_hint != null) ...[
                const SizedBox(height: 8),
                Text(_hint!, style: const TextStyle(color: Colors.redAccent)),
              ],
              if (warn) ...[
                const SizedBox(height: 8),
                const Text(
                  '注意: この組み合わせは OS 標準のショートカットと衝突する可能性があります。',
                  style: TextStyle(color: Colors.orangeAccent),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'Esc でキャンセル',
                style: TextStyle(color: Colors.black45, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop<HotkeyCombo?>(null),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: captured == null
              ? null
              : () => Navigator.of(context).pop<HotkeyCombo?>(captured),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.active,
    required this.onSelect,
    this.onClose,
  });

  final SettingsTab active;
  final ValueChanged<SettingsTab> onSelect;
  final VoidCallback? onClose;

  /// サイドバー幅 (spec: 178px 前後)。
  static const double _sidebarWidth = 178;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _sidebarWidth,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(
            color: ColorTokens.onSurfaceMuted.withValues(alpha: 0.18),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(SpacingTokens.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Settings',
                    style: TypographyTokens.heading.copyWith(
                      color: ColorTokens.onSurface,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: '閉じる',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: SpacingTokens.sm,
              ),
              children: SettingsTab.values.map((tab) {
                final selected = tab == active;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Material(
                    color: selected
                        ? ColorTokens.accent.withValues(alpha: 0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(RadiusTokens.medium),
                    child: InkWell(
                      borderRadius:
                          BorderRadius.circular(RadiusTokens.medium),
                      onTap: () => onSelect(tab),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: SpacingTokens.sm,
                          vertical: SpacingTokens.sm,
                        ),
                        child: Row(
                          children: [
                            Icon(tab.icon,
                                size: 16, color: ColorTokens.onSurface),
                            const SizedBox(width: SpacingTokens.sm),
                            Expanded(
                              child: Text(
                                tab.title,
                                style: TypographyTokens.body.copyWith(
                                  color: ColorTokens.onSurface,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
