# Flote Desktop (Flutter port)

Flote の Windows + macOS クロスプラットフォーム版。Flutter 3.x。

既存 SwiftUI 版 (`apps/macos/`) は凍結対象。こちらが新規実装。

## ディレクトリ構成

```
apps/flutter/
  lib/
    main.dart            - エントリポイント
    models/              - StickyNote / NoteGroup / NoteColorTheme / StowState
    services/            - Persistence / Organize / Hotkey / Tray / Keychain
    providers/           - Riverpod state (NoteManager / GroupManager)
    ui/                  - Widget ツリー (app_shell / notes / settings / groups)
    theme/               - デザイントークン (tokens.dart)
    l10n/                - ローカライズ (日本語のみ MVP)
  assets/icons/          - アプリアイコン (Sprint 6 で本配置)
  macos/                 - macOS ネイティブレイヤ
  windows/               - Windows ネイティブレイヤ
  test/                  - ユニットテスト
  docs/                  - 開発者向けドキュメント
  scripts/               - ビルド補助スクリプト
  Makefile               - build-mac / build-win / run-mac / run-win など
```

## セットアップ

```
cd apps/flutter
flutter pub get
```

## よく使うコマンド

```
make help        # 利用可能なターゲット一覧
make run-mac     # macOS でデバッグ実行
make build-mac   # macOS リリースビルド
make build-win   # Windows リリースビルド
make clean       # build 出力削除
```

## Sprint 進捗

- Sprint 1: Flutter 基盤 + 共通アーキテクチャ + ビルド設定 (現在)
- Sprint 2: データ層 + ノート CRUD + 永続化
- Sprint 3: 浮動ウィンドウ + 3 状態トグル + Menubar/Tray + Hotkey
- Sprint 4: Rich text + カラーテーマ + 基本ツールバー
- Sprint 5: AI Organize + Groups + Settings 画面
- Sprint 6: 配布パッケージ + デザイントークン土台 + 最終検証
