import 'dart:io';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:tray_manager/tray_manager.dart';

/// Menubar と SystemTray をまとめて管理する。
class TrayService with TrayListener {
  VoidCallback? _onNewNote;
  VoidCallback? _onOpenSettings;
  VoidCallback? _onOpenGroups;
  VoidCallback? _onQuit;

  /// トレイアイコンとコンテキストメニューを初期化する。
  Future<void> initialize({
    required VoidCallback onNewNote,
    required VoidCallback onOpenSettings,
    required VoidCallback onOpenGroups,
    required VoidCallback onQuit,
  }) async {
    _onNewNote = onNewNote;
    _onOpenSettings = onOpenSettings;
    _onOpenGroups = onOpenGroups;
    _onQuit = onQuit;

    trayManager.removeListener(this);
    trayManager.addListener(this);

    await _setTrayIcon();

    try {
      await trayManager.setToolTip('Flote');
    } catch (error) {
      stderr.writeln('Warning: trayManager.setToolTip skipped: $error');
    }

    final menu = Menu(
      items: [
        MenuItem(
          key: 'new_note',
          label: 'New Note',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'groups',
          label: 'View Groups...',
        ),
        MenuItem(
          key: 'settings',
          label: 'Settings...',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Quit Flote',
        ),
      ],
    );

    try {
      await trayManager.setContextMenu(menu);
    } catch (error) {
      stderr.writeln('Warning: trayManager.setContextMenu skipped: $error');
    }
  }

  /// トレイアイコンを優先順で設定する。
  Future<void> _setTrayIcon() async {
    try {
      await trayManager.setIcon('assets/icons/tray_icon.png');
      return;
    } catch (error) {
      stderr.writeln('Warning: Failed to load tray icon: $error');
    }

    try {
      await trayManager.setIcon('assets/icons/app_icon.png');
    } catch (error) {
      stderr.writeln(
        'Warning: Failed to load fallback tray icon. Tray icon will be skipped: $error',
      );
    }
  }

  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'new_note':
        _onNewNote?.call();
        break;
      case 'groups':
        _onOpenGroups?.call();
        break;
      case 'settings':
        _onOpenSettings?.call();
        break;
      case 'quit':
        _onQuit?.call();
        break;
      default:
        stderr.writeln('Warning: Unknown tray action: ${menuItem.key}');
        break;
    }
  }

  /// 終了時にトレイ関連リソースを破棄する。
  Future<void> dispose() async {
    trayManager.removeListener(this);

    try {
      await trayManager.destroy();
    } catch (error, stackTrace) {
      stderr.writeln('Failed to dispose tray service: $error');
      stderr.writeln(stackTrace);
    }
  }
}
