<!-- session: 2026-04-19 18:30 -->

# Flote MVP 配布メモ (Sprint 6 成果物)

本ドキュメントは MVP 配布時に LP (website/) や README、Slack / メール等のアナウンスに転用するテキスト断片を保持する。LP の更新は Flutter プロジェクトの責務外 (DD-11 で Flutter プロジェクトを apps/flutter/ に隔離、website/ は別管理) なので、本 docs を引き継ぎポインタとして残す。

---

## macOS 配布 (ad-hoc dmg)

### ダウンロード

1. GitHub Releases (または開発者が直接配布する dmg 共有リンク) から `flote-mac-v<version>.dmg` をダウンロード
2. ダブルクリックしてマウント
3. Applications フォルダに `flote_desktop.app` をドラッグ & ドロップ

### 初回起動 (Gatekeeper 警告の回避)

Apple Developer 契約なしの ad-hoc 署名のため、初回起動時に「開発元を確認できないため開けません」と出る。以下のいずれかで許可:

- Finder で Flote を **右クリック → 開く** → 確認ダイアログで「開く」
- System Settings → プライバシーとセキュリティ → Flote について「このまま開く」ボタンを押す

2 回目以降は通常のダブルクリックで起動できる。

### アンインストール

- Applications から Flote.app をゴミ箱に移動
- データも削除する場合: `~/Library/Application Support/Flote/` を削除
- Keychain の Claude API キーも削除する場合: Keychain Access で `com.flote.floteDesktop` の項目を削除

---

## Windows 配布 (.exe + Zip)

### ダウンロード + 起動 (PowerShell ワンライナー)

```powershell
# 例: v1.0.0 の場合
$v = "1.0.0"
$url = "https://github.com/<OWNER>/<REPO>/releases/download/v$v/flote-windows-v$v.zip"
Invoke-WebRequest -Uri $url -OutFile "flote-v$v.zip"
Expand-Archive -Path "flote-v$v.zip" -DestinationPath "flote-v$v"
Start-Process "flote-v$v\flote_desktop.exe"
```

### 初回起動 (SmartScreen 警告の回避)

未署名のため、Windows Defender SmartScreen で「Windows によって PC が保護されました」と出る。

1. 「詳細情報」をクリック
2. 「実行」ボタンを押す

2 回目以降は自動で許可される。

### アンインストール

- 展開したフォルダをそのまま削除
- データも削除する場合: `%APPDATA%\Flote\` (エクスプローラで `%APPDATA%\Flote` を開いて削除)
- Credential Locker の Claude API キーも削除する場合: 「資格情報マネージャー」で `com.flote.floteDesktop` の項目を削除

---

## GitHub Actions からの取得 (開発者向け)

1. GitHub リポジトリの Actions タブを開く
2. `Build Windows` ワークフローを選択
3. `Run workflow` ボタン (workflow_dispatch) で手動実行、または v* タグを push すると自動実行
4. 完了後、Artifacts セクションから `flote-windows-v<version>` (Zip) をダウンロード

---

## 今後の改善 (第二段階以降)

### macOS
- Apple Developer 契約 (99 USD/yr) + notarize で Gatekeeper 警告を消す
- `notarytool` を GitHub Actions に組み込んで自動 notarize + stapling
- menubar アイコンの SF Symbols 化

### Windows
- msix パッケージに切り替え (署名証明書 $200-400/yr が必要)
- SmartScreen 警告の消失には Authenticode 証明書の実績蓄積が必要 (配布実績が増えてから検討)
- SCCM / Intune での配布サポート

### 共通
- 自動アップデート (Sparkle / auto_updater plugin の統合)
- クラッシュレポート収集 (Sentry / Crashlytics)
- アイコンの本格リデザイン (現在は Flutter デフォルト青地の placeholder)

---

## LP (website/) への転記ガイド

以下を LP の「インストール手順」セクションに貼り付け可能:

### Mac 版
```
1. flote-mac-vX.Y.Z.dmg をダウンロード
2. ダブルクリックしてマウント、Applications にドラッグ
3. 初回起動は右クリック→「開く」で許可 (Gatekeeper 警告の回避)
```

### Windows 版
```
1. Releases から flote-windows-vX.Y.Z.zip をダウンロード
2. Zip を解凍、flote_desktop.exe をダブルクリック
3. 初回起動は SmartScreen の「詳細情報」→「実行」で許可
```

### PowerShell ワンライナー (Windows 技術ユーザー向け)
```powershell
$v = "X.Y.Z"; Invoke-WebRequest -Uri "https://github.com/<OWNER>/<REPO>/releases/download/v$v/flote-windows-v$v.zip" -OutFile "flote.zip"; Expand-Archive flote.zip flote-v$v; Start-Process "flote-v$v\flote_desktop.exe"
```

以上。LP 反映時に `<OWNER>/<REPO>` を実 URL に置換すること。
