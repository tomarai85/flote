# Flote Desktop アーキテクチャ (Flutter port)

本ドキュメントは Sprint 1 時点のアーキテクチャ概要。

## レイヤー

```
ui/        -> providers/ -> services/ -> models/
                 |             |
                 v             v
             Riverpod    dart:io / http / keychain / window / tray / hotkey
```

依存方向のルール (インポート境界):

- `models/` は他のどのレイヤーにも依存しない (純粋データ型)。
- `services/` は `models/` と外部 API/ストレージにのみ依存する。`providers/` は参照しない。
- `providers/` は `services/` と `models/` に依存する。`ui/` は参照しない。
- `ui/` は `providers/` 経由で state を読み、直接 `services/` を呼ばない。
- `theme/tokens.dart` はどのレイヤーからも参照可 (純粋定数)。

## 主要コンポーネント

### Models
- `StickyNote`: 付箋 1 枚のデータ。id/text/richText/position/size/colorTheme/stowState など。
- `NoteGroup`: グループ (Inbox + ユーザー作成)。parentGroupID で階層。
- `NoteColorTheme`: 6 色の enum + 背景/ツールバー/テキスト色。
- `StowState`: expanded / rolledUp / mini。

### Services
- `PersistenceService`: atomic write + JSON。macOS は `~/Library/Application Support/Flote/`、Windows は `%APPDATA%\Flote\`。
- `OrganizeService`: Ollama + Claude ルーティング。200 文字 / 5 行超で Claude、未満で Ollama。
- `HotkeyService`: hotkey_manager ラッパ。⌥Space / Alt+Space。
- `TrayService`: tray_manager ラッパ。menubar / systemtray アイコンとメニュー。
- `KeychainService`: flutter_secure_storage ラッパ。Claude API キー保管。

### Providers (Riverpod)
- `noteManagerProvider`: ノート CRUD と 500ms debounce 保存。
- `groupManagerProvider`: Inbox 自動作成、グループ階層管理、128 深エスケープ。

### UI
- `AppShell`: メインウィンドウのシェル。
- `NoteWindow`: 独立 OS ウィンドウとして開く付箋 (desktop_multi_window)。
- `SettingsWindow`: 6 セクション構成の設定画面。
- `GroupsWindow`: 2 ペインのグループ一覧 (設定画面の Groups タブと兼用検討)。

## プラットフォーム差分

| 機能 | macOS | Windows |
|---|---|---|
| Dock 非表示 | LSUIElement=YES | 標準で非適用 |
| nonactivating panel | NSPanel (Sprint 3 で Swift 側実装) | 技術的不可、always-on-top で妥協 |
| メニューバーアイコン | menubar 右上 | systemtray 右下 |
| Global hotkey | ⌥Space | Alt+Space (標準 window メニューと要警告) |
| 配布形式 | ad-hoc dmg | .exe + Zip (PowerShell ワンライナー配布) |

## Sprint 粒度の実装計画

各機能の実装は `.harness/spec.md` の Sprint 定義を参照。Sprint 1 では各レイヤーの雛形のみを置き、以降のスプリントで `throw UnimplementedError()` を本実装に差し替えていく。
