<!-- session: 2026-04-19 18:30 -->

# Flote Flutter MVP 手動 E2E チェックリスト

Sprint 6 完了時点で本ドキュメントを基に手動 E2E テストを実施する。macOS 版での実行は開発者本人が担当、Windows 版は GitHub Actions で Zip を生成 → 他人の Windows マシン / Parallels VM で開発者が確認する (DD-5 / DD-6 承認済みの方針)。

各項目は [PASS] / [FAIL] を記入、FAIL の場合は再現手順 + 気づきを付記する。未実装のまま MVP で妥協している挙動 (SnackBar でスピナー代替、Shortcuts リバインドのキャプチャ等) はそのまま [PASS (MVP)] と記録し、第二段階で見直す。

---

## テスト環境

| 項目 | 値 |
|---|---|
| OS | macOS 15.x (MacBook Pro) / Windows 10 22H2 (Parallels VM または別マシン) |
| Flutter | 3.41.7 stable |
| ビルド | `flutter build macos --release` / `flutter build windows --release` (CI) |
| Claude API | dev キー (Keychain or Credential Locker 経由)、Ollama は localhost:11434 |
| テストデータ | 空状態スタート (`~/Library/Application Support/Flote/` を事前削除) |
| 配布物 | macOS: `dist/flote-mac-v1.0.0.dmg`、Windows: `flote-windows-v1.0.0.zip` |

---

## 1. ⌥Space (Mac) / Alt+Space (Win) で新規ノート作成

### 手順

1. アプリを起動 (menubar / systemtray にアイコン表示を確認)
2. 他アプリ (Safari / メモ帳) をフォアグラウンドにする
3. ⌥Space (Mac) または Alt+Space (Win) を押下
4. 新規ノートウィンドウが画面中央付近に出現することを確認
5. テキストを入力 ("テスト 1" 等)
6. アプリを完全終了 (menubar Quit or systemtray Quit)
7. アプリ再起動
8. 入力したノートが復元されていることを確認

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- Windows では Alt+Space が OS 標準のウィンドウメニューを開くことがある。その場合は hotkey_manager の警告ログを確認。

---

## 2. 3 状態トグルの 6 方向遷移

expanded ↔ rolledUp ↔ mini すべての方向で 1 ステップ遷移可能であること (Sprint 3 Feature 3.5 の対称性要件)。

### 手順

1. 新規ノート作成 (expanded 状態)
2. 以下の 6 遷移を順に実行、各遷移後にウィンドウサイズと表示内容を確認:
   - [ ] expanded → rolledUp (巻物化ボタン: 高さ 26px、タイトル中央表示)
   - [ ] rolledUp → expanded (タイトルダブルクリック: 通常編集画面に復帰)
   - [ ] expanded → mini (mini 化ボタン: 48x48 円形、先頭 1 文字表示)
   - [ ] mini → expanded (クリック: 通常編集画面に復帰)
   - [ ] rolledUp → mini (巻物状態から mini ボタン、expanded 経由しない)
   - [ ] mini → rolledUp (mini 状態から巻物ボタン、expanded 経由しない)
3. アニメーション中に連打してもクラッシュしないこと (連打ガード確認)

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- rolledUp 時のタイトル編集 UI は MVP 外 (spec 3.3 参照)。編集不可で問題なし。

---

## 3. 6 色のカラーテーマ切替

### 手順

1. 新規ノートを 6 枚作成 (⌥Space を 6 回連打)
2. 各ノートが自動で異なる色になっていることを確認 (被りゼロが理想、全色使い切ったらランダム再選択)
3. 1 枚のノートを右クリック or ツールバー → カラーピッカー → 各色を順に選択
4. 背景色・ツールバー色・テキスト色が切り替わること
5. 黄/ピンク/青/緑/紫/オレンジ全てで textColor が WCAG AA (4.5:1) を満たす見た目であること (目視で可読)

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- 色コントラストの数値計算は `lib/theme/wcag.dart` のユーティリティで自動検証済み (ユニットテスト)。

---

## 4. B/I/U/S + ハイライト + 文字色の rich text 編集

### 手順

1. 新規ノートで以下のテキストを入力:
   `これは テスト です。`
2. 「テスト」だけを選択、ツールバーから Bold 適用 → 太字になる
3. 同じ選択で Italic 追加 → 斜体 + 太字
4. 全体を選択、ハイライト色 (黄) を適用
5. 「これは」部分を選択、文字色 (赤) に変更
6. ⌘A で全選択、書式解除 (B/I/U/S 全てトグル) → 書式なしに戻る
7. ノートを閉じる → 再度開く → 書式が復元されている

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- 日本語 IME 入力中に typing attribute が壊れないことを再確認 (Feature 4.1 の IME composition 対策)。

---

## 5. Ollama 経由の AI Organize + ⌘Z で巻き戻し

### 前提
- Ollama がローカル (localhost:11434) で起動中、gemma3:12b model が pull 済み

### 手順

1. 新規ノートに 50 文字程度のラフテキスト (未整理のメモ) を入力
   例: `明日の会議 資料準備 15 時 スライドと配布資料 プロジェクタ確認`
2. 「整理」ボタン押下 → SnackBar に「整理中...」表示
3. 数秒以内に LLM 応答で rich text が整った内容に置き換わる
4. ⌘Z (Mac) / Ctrl+Z (Win) を押下 → 整理前のラフテキストに戻る
5. ⌘Z を再度押下 → それ以上 undo は効かない (ノート自体の編集履歴には介入しない)

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- 文字数 200+ or 5 行超なら Claude にルーティング。今回は 200 未満なので Ollama が使われる。
- Ollama 未起動時はエラーバナー (network 分類) が出ること。

---

## 6. Claude 経由の AI Organize (API キー必要)

### 前提
- Settings > AI Organize で Claude API キーを保存済み

### 手順

1. 新規ノートに 250 文字以上 または 6 行以上のテキスト (長めのメモ) を入力
2. 「整理」ボタン押下
3. Claude Sonnet 4.5 にルーティングされ、応答で rich text が整形される
4. ⌘Z で整形前に戻る
5. Settings > AI Organize で API キーを削除 → 再度「整理」 → エラーバナー (key 分類)

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- API キーはログに出ないこと (redactApiKey 関数で head + tail 4 文字のみ表示)。
- Claude API の rate limit (429) 時はエラーバナー (rateLimit 分類)。

---

## 7. Inbox ノート 3 件の Batch Classify (新規グループ作成含む)

### 前提
- Inbox に 3 件以上のノートが存在 (例: "会議メモ"、"買い物リスト"、"プログラミングアイデア")

### 手順

1. Settings > Groups タブを開く
2. 左ペインで Inbox を選択、右ペインに 3 件のノートが一覧表示される
3. 「Inbox を整理」ボタン押下 (inboxCount >= 2 でアクティブ)
4. SnackBar「Inbox を分類中...」が表示、数秒後に AlertDialog で結果表示
5. 結果: 成功件数 / 新規グループ数 / 失敗件数 + エラー内訳
6. Groups ツリー左ペインが自動更新、新規グループが追加されている
7. 各ノートが正しく分類されていることを右ペインで確認

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- Claude API キーなしの場合は Ollama fallback。
- LLM 応答が JSON 破損時は failures = parse 件数で表示。

---

## 8. Group の作成 / リネーム / 削除 + 子要素再配置

### 手順

1. Settings > Groups で「新規グループ」ボタン → ダイアログで名前入力 ("テストグループ")
2. ツリーに追加される、親 null (root 配下)
3. テストグループの子としてサブグループ作成 ("子グループ 1")
4. テストグループに Inbox から 1 件ノートを移動 (右ペインから drag or 右クリックメニュー)
5. テストグループをリネーム ("テストグループ更新")
6. テストグループを削除 → 確認ダイアログ → 削除実行
7. サブグループ ("子グループ 1") が root に昇格していることを確認
8. 中にあったノートが Inbox に移動していることを確認

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- 128 深の親子ループは保守的処理でエスケープ、テストでは 3-4 階層程度で十分。

---

## 9. ノート削除 + History から復元

### 手順

1. 任意のノートで「削除」ボタン押下 → 確認ダイアログ → Delete
2. ノートウィンドウが閉じ、リストから消える
3. Settings > History を開く → 削除したノートが一覧に表示
4. 復元ボタン押下
5. Inbox にノートが復元される (元の groupID ではなく Inbox 強制、M9 修正踏襲)
6. History 一覧から削除されていること (またはチェック項目から消えること)
7. History から「全て削除」→ 確認 → 全件消える

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- 空ノート (text が空) は確認なしで削除 (History にも乗らない、現行踏襲)。

---

## 10. menubar Quit で全 pending save が flush される

### 手順

1. ノートを 3 件作成、テキストを入力
2. すぐに menubar (or systemtray) から Quit
3. ~/Library/Application Support/Flote/notes.json (Mac) or %APPDATA%\Flote\notes.json (Win) の更新時刻が Quit 直前であることを確認
4. アプリ再起動 → 3 件のノートが全て復元されている
5. Activity Monitor (Mac) / タスクマネージャー (Win) で flote_desktop プロセスが残っていないことを確認

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- 500ms debounce の pending save が flushSaveNow で同期 flush されること (Sprint 2 Feature 2.3 実装)。
- history / appSettings の flushSaveNow も同様に flush される。

---

## 追加検証項目 (Sprint 6 配布特有)

### 11. macOS dmg の配布動作

1. `make -C apps/flutter dist-mac` 実行 → `apps/flutter/dist/flote-mac-v1.0.0.dmg` 生成
2. dmg をダブルクリック → マウント
3. Applications フォルダにドラッグ & ドロップ
4. Applications から Flote 起動 → Gatekeeper 警告 (初回のみ)
5. 右クリック「開く」→ 許可して起動 → menubar にアイコン表示
6. ⌥Space で新規ノート動作確認

### 結果
- [ ] PASS / FAIL

### 12. Windows Zip の配布動作

1. GitHub Actions で `Build Windows` workflow を workflow_dispatch で手動実行
2. Artifact `flote-windows-v1.0.0` をダウンロード
3. Zip を解凍 → `flote_desktop.exe` を起動
4. SmartScreen 警告 → 「詳細情報」→「実行」で許可
5. systemtray にアイコン表示、Alt+Space で新規ノート動作
6. アプリを閉じて %APPDATA%\Flote\ に notes.json が保存されていることを確認

### 結果
- [ ] PASS / FAIL

備考:
- PowerShell ワンライナー (LP に掲載予定):
  ```powershell
  Invoke-WebRequest -Uri <url> -OutFile flote.zip; Expand-Archive flote.zip -DestinationPath flote; Start-Process flote\flote_desktop.exe
  ```

### 13. アプリアイコン表示確認

1. macOS: Dock は LSUIElement=true のため非表示だが、Applications で Flote.app のアイコンが表示される
2. Windows: systemtray / タスクマネージャー / エクスプローラーで flote_desktop.exe のアイコン表示

### 結果
- [ ] Mac: PASS / FAIL
- [ ] Win: PASS / FAIL

備考:
- placeholder icon を使用中。第二段階で再デザイン予定。

---

## まとめ

全 13 項目 (10 必須 + 3 配布検証):

| # | 項目 | Mac | Win |
|---|---|---|---|
| 1 | Hotkey で新規ノート + 再起動復元 | | |
| 2 | 3 状態 6 方向遷移 | | |
| 3 | 6 色カラーテーマ | | |
| 4 | rich text B/I/U/S + ハイライト | | |
| 5 | Ollama Organize + undo | | |
| 6 | Claude Organize + key 削除エラー | | |
| 7 | Batch Classify | | |
| 8 | Group CRUD + 子要素再配置 | | |
| 9 | History 復元 + clear | | |
| 10 | Quit で pending save flush | | |
| 11 | dmg 配布動作 | | N/A |
| 12 | Windows Zip 配布動作 | N/A | |
| 13 | アプリアイコン表示 | | |

### 実施記録

- 実施日: (未実施)
- 実施者: Tomonori Arai
- 全体結果: (未実施)

### FAIL 項目の記録欄

(FAIL があった場合、ここに再現手順 + 気づき + 次アクションを記入)

---

## 次タスクへの引き継ぎ

- LP (website/) に PowerShell ワンライナーと dmg 右クリック手順を追記 (本 spec 外の別タスク)
- 第二段階: 第二段階の UX ブラッシュアップ + デザイン工程 (Figma / Claude Design) で既存 tokens.dart を差し替え
- MSIX 化: Windows 配布で署名証明書を導入する場合、msix パッケージで再パッケージング可能
- notarize: macOS で Gatekeeper 警告を消す場合、Apple Developer 契約 + notarize を検討 (99 USD/yr)
