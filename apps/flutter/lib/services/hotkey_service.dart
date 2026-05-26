import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

typedef HotkeyCallback = void Function();

/// HotkeyService の Riverpod Provider。
///
/// Sprint 5 Round 2 で Settings からリバインド API を呼ぶため Provider 化。
/// アプリ全体で 1 インスタンスだけ持つ (グローバル OS 登録のため)。
final hotkeyServiceProvider = Provider<HotkeyService>((ref) {
  final service = HotkeyService();
  ref.onDispose(() async {
    await service.unregisterAll();
  });
  return service;
});

/// グローバルホットキーの用途 (Sprint 5 Round 2 Feature 5.4 のリバインド対象)。
///
/// これを拡張するときは [slotKey] / [defaultComboLabel] 両方を更新し、
/// AppSettings.customShortcuts と settings_window.dart の UI も追随させる。
enum HotkeySlot {
  /// 新規ノート作成 (既定: ⌥Space / Alt+Space)。
  newNote,

  /// Groups 画面を開く (既定: Control+Option+G / Ctrl+Alt+G)。
  openGroups,

  /// アクティブノートのアーカイブ (既定: ⌘W / Ctrl+W)。
  archive,
}

extension HotkeySlotX on HotkeySlot {
  /// AppSettings.customShortcuts のキー。
  String get slotKey {
    switch (this) {
      case HotkeySlot.newNote:
        return 'newNote';
      case HotkeySlot.openGroups:
        return 'openGroups';
      case HotkeySlot.archive:
        return 'archive';
    }
  }

  /// UI 表示用の人間可読ラベル。
  String get displayName {
    switch (this) {
      case HotkeySlot.newNote:
        return '新規ノート';
      case HotkeySlot.openGroups:
        return 'Groups 表示';
      case HotkeySlot.archive:
        return 'Archive';
    }
  }

  /// プラットフォーム別のデフォルト組み合わせ (ComboString)。
  /// - modifiers は小文字 ["shift","ctrl","alt","meta"] の組み合わせ
  /// - key は LogicalKeyboardKey の keyLabel を小文字化した名前
  String defaultCombo() {
    switch (this) {
      case HotkeySlot.newNote:
        return 'alt+space';
      case HotkeySlot.openGroups:
        return Platform.isMacOS ? 'ctrl+alt+g' : 'ctrl+alt+g';
      case HotkeySlot.archive:
        return Platform.isMacOS ? 'meta+w' : 'ctrl+w';
    }
  }
}

/// 1 つのホットキー組み合わせを文字列化 / 解析するユーティリティ。
///
/// 形式: `"<modifiers>+<key>"` 例 `alt+space` / `ctrl+alt+g` / `meta+shift+n`
/// 修飾子は ["shift","ctrl","alt","meta"] の順に正規化する。
class HotkeyCombo {
  HotkeyCombo({
    required this.modifiers,
    required this.logicalKey,
  });

  final Set<HotKeyModifier> modifiers;
  final LogicalKeyboardKey logicalKey;

  /// 正規化された文字列表現 (AppSettings.customShortcuts に格納される形)。
  String toComboString() {
    final order = <HotKeyModifier, String>{
      HotKeyModifier.shift: 'shift',
      HotKeyModifier.control: 'ctrl',
      HotKeyModifier.alt: 'alt',
      HotKeyModifier.meta: 'meta',
    };
    final modNames = <String>[];
    for (final entry in order.entries) {
      if (modifiers.contains(entry.key)) {
        modNames.add(entry.value);
      }
    }
    modNames.add(_keyName(logicalKey));
    return modNames.join('+');
  }

  /// UI 表示用に修飾子名を macOS 記号化する (⇧⌃⌥⌘)。非 Mac では Shift/Ctrl/Alt/Win。
  String toHumanLabel() {
    final isMac = Platform.isMacOS;
    final parts = <String>[];
    if (modifiers.contains(HotKeyModifier.shift)) {
      parts.add(isMac ? '⇧' : 'Shift');
    }
    if (modifiers.contains(HotKeyModifier.control)) {
      parts.add(isMac ? '⌃' : 'Ctrl');
    }
    if (modifiers.contains(HotKeyModifier.alt)) {
      parts.add(isMac ? '⌥' : 'Alt');
    }
    if (modifiers.contains(HotKeyModifier.meta)) {
      parts.add(isMac ? '⌘' : 'Win');
    }
    parts.add(_keyLabel(logicalKey));
    return isMac ? parts.join('') : parts.join('+');
  }

  /// AppSettings に保存された ComboString を parse する。不正なら null。
  static HotkeyCombo? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final tokens = trimmed
        .toLowerCase()
        .split('+')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) {
      return null;
    }
    final mods = <HotKeyModifier>{};
    LogicalKeyboardKey? key;
    for (final t in tokens) {
      switch (t) {
        case 'shift':
          mods.add(HotKeyModifier.shift);
          break;
        case 'ctrl':
        case 'control':
          mods.add(HotKeyModifier.control);
          break;
        case 'alt':
        case 'option':
        case 'opt':
          mods.add(HotKeyModifier.alt);
          break;
        case 'meta':
        case 'cmd':
        case 'command':
        case 'super':
        case 'win':
          mods.add(HotKeyModifier.meta);
          break;
        default:
          final parsed = _logicalKeyFromName(t);
          if (parsed != null) {
            key = parsed;
          }
      }
    }
    if (key == null) {
      return null;
    }
    return HotkeyCombo(modifiers: mods, logicalKey: key);
  }

  /// LogicalKeyboardKey.keyLabel (and a few specials) から正規化名へ。
  static String _keyName(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.space) return 'space';
    if (k == LogicalKeyboardKey.enter) return 'enter';
    if (k == LogicalKeyboardKey.escape) return 'escape';
    if (k == LogicalKeyboardKey.tab) return 'tab';
    if (k == LogicalKeyboardKey.backspace) return 'backspace';
    if (k == LogicalKeyboardKey.delete) return 'delete';
    if (k == LogicalKeyboardKey.arrowUp) return 'up';
    if (k == LogicalKeyboardKey.arrowDown) return 'down';
    if (k == LogicalKeyboardKey.arrowLeft) return 'left';
    if (k == LogicalKeyboardKey.arrowRight) return 'right';
    final label = k.keyLabel.trim();
    if (label.isNotEmpty) {
      return label.toLowerCase();
    }
    // 最後の砦: keyId を 16 進で返す (ほぼ使われない)。
    return '0x${k.keyId.toRadixString(16)}';
  }

  /// UI 表示用の見栄え良いキー名 (Space は "Space" のまま)。
  static String _keyLabel(LogicalKeyboardKey k) {
    final name = _keyName(k);
    if (name.length == 1) {
      return name.toUpperCase();
    }
    return name[0].toUpperCase() + name.substring(1);
  }

  static LogicalKeyboardKey? _logicalKeyFromName(String name) {
    switch (name) {
      case 'space':
        return LogicalKeyboardKey.space;
      case 'enter':
      case 'return':
        return LogicalKeyboardKey.enter;
      case 'escape':
      case 'esc':
        return LogicalKeyboardKey.escape;
      case 'tab':
        return LogicalKeyboardKey.tab;
      case 'backspace':
        return LogicalKeyboardKey.backspace;
      case 'delete':
      case 'del':
        return LogicalKeyboardKey.delete;
      case 'up':
        return LogicalKeyboardKey.arrowUp;
      case 'down':
        return LogicalKeyboardKey.arrowDown;
      case 'left':
        return LogicalKeyboardKey.arrowLeft;
      case 'right':
        return LogicalKeyboardKey.arrowRight;
    }
    // a-z
    if (name.length == 1) {
      final code = name.codeUnitAt(0);
      // LogicalKeyboardKey.keyA..keyZ は 'a'.codeUnitAt(0) と同じ id を使うので
      // LogicalKeyboardKey(charCode) で解決できる。
      if (code >= 'a'.codeUnitAt(0) && code <= 'z'.codeUnitAt(0)) {
        return LogicalKeyboardKey(code);
      }
      if (code >= '0'.codeUnitAt(0) && code <= '9'.codeUnitAt(0)) {
        return LogicalKeyboardKey(code);
      }
    }
    return null;
  }
}

/// OS 標準との衝突候補。UI 側で警告表示するのに使う (保存自体は許可する)。
Set<String> defaultConflictCombos() {
  if (Platform.isWindows) {
    return {'alt+space', 'alt+tab', 'alt+f4', 'ctrl+escape'};
  }
  if (Platform.isMacOS) {
    return {'meta+space', 'meta+tab', 'meta+q'};
  }
  return const <String>{};
}

/// グローバルホットキーを管理する。
///
/// Sprint 5 Round 2 で [HotkeySlot] を追加し、rebind API ([registerCustom]) を
/// 公開した。旧 [registerNewNote] は後方互換のため残しているが、内部的には
/// [registerSlot] を HotkeySlot.newNote で呼ぶ薄い wrapper となる。
class HotkeyService {
  final Map<HotkeySlot, _SlotBinding> _bindings = <HotkeySlot, _SlotBinding>{};

  /// いずれかのスロットが登録済みなら true。
  bool get isRegistered => _bindings.isNotEmpty;

  /// 新規ノート (HotkeySlot.newNote) が登録済みかを返す。
  bool get isNewNoteRegistered => _bindings.containsKey(HotkeySlot.newNote);

  /// Sprint 3 互換: 現プラットフォーム向け表示名 (新規ノート固定表示用)。
  String get hotkeyDescription =>
      Platform.isMacOS ? 'Option+Space' : 'Alt+Space';

  /// 指定スロットの現在のコンボ (ユーザー設定 or デフォルト)。
  HotkeyCombo comboForSlot(HotkeySlot slot) {
    final current = _bindings[slot];
    if (current != null) {
      return current.combo;
    }
    // 未登録時はデフォルトを返す (UI の初期表示用)。
    return HotkeyCombo.tryParse(slot.defaultCombo()) ??
        HotkeyCombo(
          modifiers: const {HotKeyModifier.alt},
          logicalKey: LogicalKeyboardKey.space,
        );
  }

  /// Sprint 3 互換: 新規ノートホットキーを登録する。
  Future<void> registerNewNote({required HotkeyCallback onTrigger}) async {
    await registerSlot(
      slot: HotkeySlot.newNote,
      combo: HotkeyCombo.tryParse(HotkeySlot.newNote.defaultCombo()) ??
          HotkeyCombo(
            modifiers: const {HotKeyModifier.alt},
            logicalKey: LogicalKeyboardKey.space,
          ),
      onTrigger: onTrigger,
    );
  }

  /// 任意スロットを登録 (既存の同スロットは上書き解除される)。
  ///
  /// 登録に成功したかどうかを返す。失敗 (プラットフォーム非対応、
  /// hotKeyManager 例外) の場合は false。
  Future<bool> registerSlot({
    required HotkeySlot slot,
    required HotkeyCombo combo,
    required HotkeyCallback onTrigger,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      stderr.writeln(
        'Warning: Hotkey registration is only configured for macOS and Windows.',
      );
      return false;
    }

    // 既存バインドを解除。
    await _unregisterSlot(slot);

    // ModifierKey は HotKey に直接渡す必要がある。
    HotKey hotKey;
    try {
      hotKey = _toHotKey(combo);
    } catch (error) {
      stderr.writeln('HotkeyService.registerSlot bad combo ($slot): $error');
      return false;
    }

    try {
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) {
          onTrigger();
        },
      );
      _bindings[slot] = _SlotBinding(combo: combo, hotKey: hotKey);
      if (kDebugMode) {
        debugPrint(
          'Hotkey registered: ${slot.slotKey} = ${combo.toComboString()}',
        );
      }
      if (Platform.isWindows && combo.toComboString() == 'alt+space') {
        stderr.writeln(
          'Warning: Alt+Space conflicts with the system window menu on Windows.',
        );
      }
      return true;
    } catch (error, stackTrace) {
      stderr.writeln(
        'Failed to register hotkey (${slot.slotKey}): $error\n$stackTrace',
      );
      return false;
    }
  }

  /// 指定スロットの登録を解除する。未登録ならなにもしない。
  Future<void> _unregisterSlot(HotkeySlot slot) async {
    final existing = _bindings.remove(slot);
    if (existing == null) {
      return;
    }
    try {
      await hotKeyManager.unregister(existing.hotKey);
    } catch (error) {
      stderr.writeln('Warning: unregister ${slot.slotKey} skipped: $error');
    }
  }

  /// 既存のホットキー登録をすべて解除する。
  Future<void> unregisterAll() async {
    _bindings.clear();
    try {
      await hotKeyManager.unregisterAll();
    } catch (error) {
      stderr.writeln('Warning: hotKeyManager.unregisterAll skipped: $error');
    }
  }

  HotKey _toHotKey(HotkeyCombo combo) {
    // PhysicalKeyboardKey に変換 (hotkey_manager は PhysicalKeyboardKey 必須)。
    final physical = _physicalFromLogical(combo.logicalKey);
    return HotKey(
      key: physical,
      modifiers: combo.modifiers.toList(growable: false),
      scope: HotKeyScope.system,
    );
  }

  PhysicalKeyboardKey _physicalFromLogical(LogicalKeyboardKey logical) {
    // よく使う特殊キーは明示マッピング。
    if (logical == LogicalKeyboardKey.space) return PhysicalKeyboardKey.space;
    if (logical == LogicalKeyboardKey.enter) return PhysicalKeyboardKey.enter;
    if (logical == LogicalKeyboardKey.escape) return PhysicalKeyboardKey.escape;
    if (logical == LogicalKeyboardKey.tab) return PhysicalKeyboardKey.tab;
    if (logical == LogicalKeyboardKey.backspace) {
      return PhysicalKeyboardKey.backspace;
    }
    if (logical == LogicalKeyboardKey.delete) return PhysicalKeyboardKey.delete;
    if (logical == LogicalKeyboardKey.arrowUp) {
      return PhysicalKeyboardKey.arrowUp;
    }
    if (logical == LogicalKeyboardKey.arrowDown) {
      return PhysicalKeyboardKey.arrowDown;
    }
    if (logical == LogicalKeyboardKey.arrowLeft) {
      return PhysicalKeyboardKey.arrowLeft;
    }
    if (logical == LogicalKeyboardKey.arrowRight) {
      return PhysicalKeyboardKey.arrowRight;
    }
    // a-z マッピング。
    const letterMap = <String, PhysicalKeyboardKey>{
      'a': PhysicalKeyboardKey.keyA,
      'b': PhysicalKeyboardKey.keyB,
      'c': PhysicalKeyboardKey.keyC,
      'd': PhysicalKeyboardKey.keyD,
      'e': PhysicalKeyboardKey.keyE,
      'f': PhysicalKeyboardKey.keyF,
      'g': PhysicalKeyboardKey.keyG,
      'h': PhysicalKeyboardKey.keyH,
      'i': PhysicalKeyboardKey.keyI,
      'j': PhysicalKeyboardKey.keyJ,
      'k': PhysicalKeyboardKey.keyK,
      'l': PhysicalKeyboardKey.keyL,
      'm': PhysicalKeyboardKey.keyM,
      'n': PhysicalKeyboardKey.keyN,
      'o': PhysicalKeyboardKey.keyO,
      'p': PhysicalKeyboardKey.keyP,
      'q': PhysicalKeyboardKey.keyQ,
      'r': PhysicalKeyboardKey.keyR,
      's': PhysicalKeyboardKey.keyS,
      't': PhysicalKeyboardKey.keyT,
      'u': PhysicalKeyboardKey.keyU,
      'v': PhysicalKeyboardKey.keyV,
      'w': PhysicalKeyboardKey.keyW,
      'x': PhysicalKeyboardKey.keyX,
      'y': PhysicalKeyboardKey.keyY,
      'z': PhysicalKeyboardKey.keyZ,
    };
    const digitMap = <String, PhysicalKeyboardKey>{
      '0': PhysicalKeyboardKey.digit0,
      '1': PhysicalKeyboardKey.digit1,
      '2': PhysicalKeyboardKey.digit2,
      '3': PhysicalKeyboardKey.digit3,
      '4': PhysicalKeyboardKey.digit4,
      '5': PhysicalKeyboardKey.digit5,
      '6': PhysicalKeyboardKey.digit6,
      '7': PhysicalKeyboardKey.digit7,
      '8': PhysicalKeyboardKey.digit8,
      '9': PhysicalKeyboardKey.digit9,
    };
    final label = logical.keyLabel.toLowerCase();
    if (letterMap.containsKey(label)) return letterMap[label]!;
    if (digitMap.containsKey(label)) return digitMap[label]!;
    // フォールバック: Space (一番安全な既定)。
    return PhysicalKeyboardKey.space;
  }
}

class _SlotBinding {
  _SlotBinding({required this.combo, required this.hotKey});
  final HotkeyCombo combo;
  final HotKey hotKey;
}
