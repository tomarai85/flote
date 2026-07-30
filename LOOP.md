# Flote — standing loop anchor (never published; gitignored)

## Mission
Flote v1 を「完璧」まで磨き切る (Tom 2026-07-11 01:30 directive): 競合他社の
機能パリティ + UI デザインのブラッシュアップ + 磨き残しの狩り。作業は全部
この loop 経由、毎項目 GUI live-fire 受領書付き。

## Done bar
- competitive/index.html の機能マトリクス P0/P1 全行 = 済 (marked in plan S7)
- 各 ship = build exit 0 + crash-invariant grep + GUI live-fire PASS (idle-gated)
- UI brush-up pass 完了 (spacing / typography / hover / dark-desktop legibility)
- Tom device batch + taste 承認 (the only human row)

## Constraints
- 実 panel を frame-animate しない (crash invariants; radius 12 literals)
- コンテンツ保護 > 全部 (mid-flight guard / 戻す / fail-closed key)
- 合成入力 (CGEvent) は system idle > 120s のときのみ — Tom のタイプを奪わない
- push / 課金 / App Store / 外部送信 = Tom gate
- Plan of record: **~/.claude/plans/flote-glass-keychain-2026-07-12.md**(現 phase = P0 keychain 根絶 + Glass しまうシステム + Glass テーマ/Settings)。前 phase 正本 = goal-loop-sleepy-castle.md(v1 core 完成分)

## Backlog (top = next) — 引き継ぎ正本: **HANDOFF-flote-simplify-2026-07-13.md**(要件台帳 A-H)
- [ ] **[返却 2026-07-26]** ⌘W 無条件close (752b253 b6) の live 確認 — idle>120s 限定。手順書完備: ~/.claude/loop/evidence/flote-live-confirm-runbook.md (4行マトリクス: plain/rolledUp/mid-IME/animating)。証拠は ~/.claude/loop/evidence/flote-live-confirm-2026.md へ
- [ ] **[現行 campaign 7/13-14]** 台帳の Tom verdict 待ち: 島の見た目+OSS レシピ選び
  (design-refs-island-oss-2026-07-14.md)/ 記入時方眼 / F「エディタを前提」射程 /
  DP provisioning(準備書 = code/.harness/dp-keychain-provisioning-prep.md、Xcode 5分)
- [ ] **Wave B = 糸(バルーン紐の見た目)**: Tom taste 未達で保留中(7/12 裁定)。chrome 案A は出荷済。
  再開時 = handoff-2026-07-12/thread-look-mock-R4.html から絵で再提示
- [ ] Wave C(G1後): 監査LOW残・小粒ギャップ・思想層2件(要Tom相談)
- [Tom queue] G1 taste判定 / S0.5+課金§5 / push判断

## Done (evidence 1-line each)
- **[07-14 loop] GUI live-fire ship-gate 修復(偽陰性根治)+並列QA修正**: Tom 離席でマシン idle 解禁→
  据置の GUI live-fire を実行。B/C-island-stow が再現的 FAIL → **AX で stow ボタン press=notes 1→0 実証
  = app 無問題、synthetic 座標クリックが nonactivating-panel の SwiftUI Button に届かない harness 限界**
  (ship-gate が実 stow 回帰をマスクしていた)。gui-drive に axpress 追加+flow B 経由化→**8/8 ALL PASS**
  (4b6d010)。並列 Opus QA が session の非ライセンス変更を精査→実バグ2修正: onboarding が既存 appTheme を
  無条件上書き(medium・4b6d010)/dead frost code の two-owners ドリフト除去(5597e44)。全 sweep green。
- **[07-14 loop] REPLAN 2巡で branch-independent 作業を刈り取り→gate 承認停止**: Planner#1=create-gate 回帰
  テスト s25(正+負対照・98d0a57)/isEditable 陳腐化コメント修正/checklist bookkeeping(9df8fb7)。Planner#2=
  **#2 修正の実残余を発見**: FloatingPanel は .nonactivatingPanel でフォーカス時 didBecomeActive 非発火→
  becomeKey() で再評価 post(s26 正+負対照・5e03222)。全 sweep s14-s26 green。gate が zero-admissible 停止を
  機械発行(手動でなく Planner+gate 判定・sanction 16:15)
- **[07-14 loop] ライセンス機構ゲート配線+期限切れシート+敵対的レビュー修正**: create/edit ゲートを
  変異境界に配線(user 新規4サイト+editor isEditable、fd81a73)/期限切れ通知シート(ExpiryNotice.swift、
  データ人質禁止の文言、44ea442)/**Opus 敵対的レビューで本物のバイパス3件検出→修正**: ClipboardCollector
  無ゲート(CRIT)/付箋 stow 設計で isEditable 永久 true(CRIT・私の setup 時評価判断が誤り)/clock 書込失敗
  で trial 永久無期限(HIGH)。**live 検証**=legacy keychain に期限切れ clock 注入→enforcement ON 直接起動で
  state=expired→canCreate/canEdit/canUseAI 全 false 実測、環境クリーン復元。s24 28/28。enforcement OFF 既定=日常無影響
- **[07-14 loop] レビュー残項目#5-7 清算+model footgun 警告**: #7 keychain read 失敗→有料客ロックアウトを
  fail-safe(unreadable→licensedStale・期限切れclock+復号不能blobで licensedStale 実測・6f5aaad)/#6 refund
  delete 片側失敗 retry+log(3c56bb0)/#5 は実LS product 待ちで checklist。model picker に品質ベンチ由来の
  推奨(gemma3:12b 最良・thinking系非対応)caption(bfb26b6)。全7レビュー指摘 処理完了(1-3,6,7 修正・4 accepted・5 checklist)
- **[07-14 loop] Q1-Q4 実行+ライセンス機構(closed component)**: Q3=athenas gemma3:12b 優先を defaults
  設定+live検証/Q4=onboarding エディタ主導刷新(55f4ed2)/ライセンス=License/ フォルダ(層1境界)+
  LicenseMath 純状態機械(s24 16/16: 床日数・巻き戻し凍結・grace/stale)+LS client(製品ピン留め
  fail-closed)+About UI+AI ゲート(d69f65d)→Codex CRITICAL 監査で本物バグ4修正(keychain upsert/
  個人名送信/defaults バイパス→compile 強制/オフライン購入者救済 licensedStale)(3c3c27d)。
  enforcement は既定 OFF = 現ビルド無影響。リリース手順 = .harness/release-checklist-2026-07-14.md
- **[07-14 loop] MVP確定(Tom裁定)→AI機能キャンペーン開始**: ①Organize品質ベンチ実測(5モデル+Apple FM・
  実プロンプト・10ケース = .harness/ai-quality-bench-2026-07-14.md): 内蔵1.5B=捏造あり59%保持/
  gemma3:12b=95%で現既定を追認/**Apple FMがノート内平文指示に完全服従を発見** ②注入防御行を
  A/Bテスト(服従3/3→0/3)して両プロバイダに固定(d001e1a) ③Ollamaモデル選択+「内蔵AIより優先」
  トグル+別マシン導入ガイド(c9b62b7 — 従来は強モデルが構造的に発火不能だった) ④OpenAI互換API
  スロット(GPT/Codex API/LM Studio/vLLM・8a5d173)
- **[07-14 loop] Codex 全面設計レビュー→SurfaceRecipe 一本化+identity guard**: Codex(5.6-sol xhigh)
  が「透明度の意味が5箇所で別解釈=例外が増殖」を追認+新穴4(Reduce Transparency 貫通/ダーク紙
  0.90wash/Designed 二重定義/島<26死にノブ)。Phase A=純関数 resolver 抽出(parity・452b1f4)、
  Phase B=無彩色 guard で全テーマ identity 保証+ダイヤル全域復活(986dce4)。s23 55/55+全スイープ
  green。写真グレースケール化と和紙ink基調変更は却下(ユーザーコンテンツ/テーマ由来は教義対象外)
- **[07-14 loop] ⌘, をノートから**: menu bar 限定だった Settings ショートカットを FloatingPanel
  window レベルで捕捉(⌘W と同前例)。binary シンボル実証済
- **[07-14 loop] 初期値の per-knob 化**: 全6スライダーに ↺(ズレ時のみ出現・hover=初期値・
  クリック=単独復帰)+全体リセットを bordered 左寄せへ(4回目の「初期値どこ?」の根=粒度と配置)
- **[07-14 loop] 2日間アムネジア根治+復旧**: DP keychain entitlement 欠如(-34018実測)→legacy
  fail-open(86a25d3)・ノート4枚復号復旧(新.bak 03:22)・quarantine 判定 pure 化+keyDataInvalid
  誤分類も封鎖(2f7f7d3・s21 15/15)・save失敗アラート(f1dafce+s20 11/11)。バックアップ=
  ~/Personal/flote-data-rescue-20260714-031632
- **[07-14 loop] 位置喪失根治**: rescue=視覚のみ/persist=user意図のみ/画面復帰で home 帰還
  (5471cbd)。drag→relaunch 実測で3画面とも home 完全一致
- **[07-14 loop] 紙 full-bleed 完結**: 島暗下地復元(fbac328)+pitch=resolvedBodyFont(3a890c5)
  +空(36e2372)/記入(bb7b375)両状態 full-bleed+ドラッグ面維持(59a98eb)+s19 位相テスト。
  記入状態の実写・ピクセル走査で位相一致実証
- **[07-14 loop] 島 exit アニメ**(23524f3): open=bouncy/close=臨界減衰(OSS規範)、frame 21 実写証拠
- **[07-12→出荷済] しまうシステム(島β初期値/タブ/完全に隠す 3択+本文1行目タイトル+chrome案A)**:
  上の 07-12 Backlog 決定史はすべて実装済み(AppearanceSettings.stowStyle ほか)。糸の見た目のみ保留(Backlog 残置)
- **[07-12→解消] P0 keychain**: 当初計画の DP 移行は entitlement 欠如で逆に全損級事故を起こし(7/12 06:41)、
  07-14 に fallback 設計で根治。正道化(provisioning)は準備書済み=Tom 5分作業
- **dogfood wave 2 (Tom指摘5点, 07-12 02:0x-02:49, v59)**: ①デッキ=⌘T/⌘]⌘[/スワイプ/⌘1/
  ドット表示(s16 43) ②巻き取り全面再設計=飛行廃止・その場フェード・風船実体・すぐ下復帰
  (StowAnimator -250行) ③⌘+/−/0+文字色メニュー+等幅フック(text-size 28) ④Editor系テーマ6種
  =参照スクショから色採取(夜の森/試写室/首都高/設計図/夜光虫/琥珀)+構文色スウォッチ+白洗い根治
  ⑤Texture増幅=Opacity床30%・線0.2-5.0x・角丸4-24・方眼正方形化・素材1.8x。
  **17 suites 全PASS・build 0・livefire 8/8 @02:49(新仕様のB/C含む)**
- **最終 livefire 8/8 ALL PASS @v58 (2026-07-12 01:10)** — 完成報告のゲート通過。
  A launch/B stow/C return/D palette/E rapid/F ⌥⇧A/G resize-floor 全実機受領書
- **v57-v58 最終バースト (07-11深夜-07-12 00:xx)**: v57=Theme Maker(s15 32)+list/リスト+/x
  (s12 79)+onboarding/What's New v2+監査修理5件(URL egress 4dbee97・IME clobber+角丸
  abd33de・calc汚染/undoガード/⌘X expand=f443439内)。v58=calc仕上げ(千位+2dp統一・
  面積/坪・$10=ペア既定・レート形・s7-calc 269)。**14 suites 全PASS・build 0**
- 監査3本完了 (Agent Teams): spec 12/14→14/14(v58で解消) / protection 3.5/5→FAIL全修理 /
  regression 4/5→MEDIUM全修理・クラッシュ不変条件ゼロ違反
- v53-v54 バースト3 (15:2x-15:4x): v53=テーマ21種(6ダーク・意味スロット+派生・s14 CR監査
  21x2 ALL PASS) / v54=Send to Notes/Obsidian/Bear+クリップボード収集(送信49+収集41テスト・
  concealed/own-copy/substring dedupe のfail-closedゲート)。
  ※v54 で entitlements に apple-events (com.apple.notes 限定 temporary-exception) 追加 —
  MAS 審査で要注意事項 → S0.5 判断材料に追記
- v50-v52 バースト2 (15:0x-15:2x): v50=paste-strip(⌘V書式剥ぎ・s9 69) / v51=通貨+crypto
  (ECB+CoinGecko・鮮度policy純関数・calc 168) / v52=タイマー(左レール実UI・音+通知・s10 98)。
  全deploy済・全suite PASS・build 0
- live-fire **8/8 ALL PASS @v52 (15:08, 7bd29a7)** — A launch / B stow-string / C return /
  D palette / E rapid / **F ⌥⇧A bulk-toggle** / **G resize-floor** 全部実機受領書付き
- v49 バックアップ/復元 (backup-restore agent, merge 2c5faab): Settings>バックアップ=
  平文JSON書き出し(新Mac復元可能・警告文付き)+all-or-nothing検証復元(既存id絶対不上書き・
  pre-restore snapshot 3世代)。round-trip 28/28 + 全suite PASS。NSPanel対話フローの
  live-fire は Tom の初回操作が受領書
- v46-v48 バースト (2026-07-11 14:2x-14:4x, agent並列+main直列統合):
  v46=単位変換+sum/avg (calc-units agent, 101 tests) / v47=Antinote本物描画
  (=ごとaccent色・クリックコピー・√/log/!/ceil/floor, 117 tests) / v48=⌥⇧A一括
  show/hide+空ノート掃除 (summon-hygiene agent, f2 14 tests)。全deploy済・全suite PASS
- 競合仕様書2本納品 (agents): antinote-behavior-specs.md (520行・theme-maker JSから
  描画の正解を回収) + rival-behavior-specs.md (294行・SideNotes/Noticky/Tot)
- 自由リサイズ+サイズ提案 小/中/大 (6a7870d, v43 deploy済): .resizable+inLiveResize判定で
  userResized 化(以後 preset/auto-fit 不干渉・スクロール化・再開時も保持)。小=現行160x120
  そのまま・中240x200・大320x280(preset高を最小に保持)。旧 floteNoteWidth 自動移行。
  回帰3suites PASS・live ドラッグ検証=Tom の初回操作
- calc v2 Antinote品質パス (d4070c5, v41 deploy済): 結果=テーマaccent色+専用attribute
  (ユーザー文字と構造分離・NSKeyedArchiver永続)・式編集でライブ再計算(壊れたら結果削除=
  fail closed)・`100+15%`/`50% of 200`/`2^10` 対応。calc 35/35・sink 15/15・strip 13/13。
  一次資料=antinote.io/user-manual から挙動仕様を抽出して実装(名前移植をやめた第1号)
- Tom dogfood round 3 (779839c, v40 deploy済): ①電卓が x/×/÷ を受けない(34x213=無反応)
  → normalizedOperators(識別子保護付き・calc 23/23) ②リマインダーがチェックボックス行限定
  → plain 行OK ③変換/書き出しが隠し場所限定 → テキスト右クリックに追加(既存 pipeline 経由・
  content-protection 不変)。live 発火確認は Tom の再試行 or 次 idle 窓
- 教訓: 「実装済み」の根拠が pure-test + 隠しUI のとき、Tom の第一想起場所(テキスト右クリック)
  に無ければ体感は「存在しない」。機能の置き場所 = 競合の置き場所に合わせるのが discoverability
- **Qwen DL E2E 完走 (2026-07-11 12:56)**: AXPress で Download 押下 → 838M 着地
  (Container/Models/ HubClient layout) → load 成功 → `.flote-model-ready` sentinel 生成
  → UI「Bundled local AI (Qwen 2.5) = Available」。DL実測 ~60-90s。最後の未live項目クローズ
- keychain fix deploy 済 (v39): 起動時ダイアログ0・ノート復元確認。E2E はこの新ビルドで実施
- GUI 操作の確立手順: Flote は accessory app なので set frontmost 不可 →
  「アクティベート用クリック→選択クリック」2連 + ボタンは AXPress(座標不使用・誤爆ゼロ)。
  sidebar 行は AXRow 非公開で AXPress 無効(座標クリックのみ)
- keychain 凍結の根治 (5b80182, build 0): AIタブを開くだけで秘密本体を読む存在確認4箇所
  (Settings onAppear + didBecomeKey毎回 + OrganizeService routing x2) を metadata-only
  hasAPIKey() に置換 — プロンプトは「実際に Claude を使う瞬間」だけに。真因は live-fire で
  ダイアログ実物を region capture して特定
- Aqua Voice frontmost 問題の特定: 非アクティブ窓への合成初回クリックはアクティベートに
  食われる → 以後 `set frontmost of process` 前置き + クリック点 topmost 検証 (topmost.swift)
- NEW-4 (エラー文言LN化) + lint 12→2 (残2は意図的=content-protection経路の再形成を避ける判断・commit msg文書化) + 新機能discoveryメニュー (v37) — v38稼働
- **Evaluator FINAL (r3c): PASS** — content protection 5/5・regressions 5/5・livefire 6/6 @deployed binary。r3の12件+r3bのNEW-1/2/3全修理を独立検証済 (report=.harness/feedback/v1-eval-r3-2026-07-11.md)
- NEW-3 fail-loudly (0c2eba4, v35): keychain全滅拒否=alert+新規ノート作成遮断
- 誤診→訂正 (2026-07-11 09:5x): 「v24以降未deploy」は偽 — Swift small-string(<=15byte)はgrep不可視。長literal再測定でv33確定。教訓=binary検証は>=16byteのliteralで。Tomの「何も増えてない」の真因=discoverability(全機能が操作の中に隠れている)
- Evaluator r3: FAIL→findings全修理 (9eac9d7+128d306, v32) — CRITICAL=検索のlocked本文leak封鎖・walLoad誤隔離遮断・majors 3-5・minors 8。agent limit死につき再検証はlead inline (report appendix)。livefire再走=unlocked idle窓待ち
- progress.md 補填 (r3 process finding)
- S7-5 電卓 (18/18 pure-region PASS, v27) / v27 regression 6/6 / hot-corner 実射=panel 1→2 / pill maskImage 案は live-fire で棄却(紐消失)→revert (v29)
- S7-3 検証完了: live-fire 6/6 PASS x3 (radius 8 / 16 / default v26, 02:04-02:06) — 角丸は全域で crash-safe
- S7-6b Settings 全文 L() 化 (78 strings/3 batches, build 0 x3, v26) — S7-6 全完了
- live-fire gate 硬化: 自己イベントによる self-block を単調増加トレンド判定で解消
- S7-6a 操作面 L() 化 (build 0, sink/strip PASS, v25) + LN() nonisolated helper
- S7-3 角丸 (45fd763, build 0, live-fire@8/16 は idle 窓待ち) / S7-4 Dock+hot-corner (build 0, v24)
- S7-7 GUI live-fire suite (.harness/tests/gui-livefire.sh) — 初回実走 6/6 ALL PASS 01:34 (A launch/B key-stow-string/C return/D palette open+autoclose/E rapid)。以後の ship はこれが PASS しないと閉じない
- S7-1 search palette (4c9596b, live-fire 3 bugs fixed in-round, v21) / S7-2 date→reminder (detector receipts on 7 real phrases, v22)
- balloon stow (140906e, live full-lifecycle receipts) / data-safety + stable signing (b814a7d) / search palette v1 (built, focus-race fixed live)

## Idle-gated self-doable (next machine wake)
- [ ] **GUI live-fire スイート実行** (.harness/tests/gui-livefire.sh): この session の ~15 commit
  (surface recipe / becomeKey / updateNSView isEditable / onboarding)は build+pure-test のみで
  対話フロー未 live 検証。HID idle>=120s で合成入力可 → 稼働アプリの create/type/stow/settings 回帰確認。
  2026-07-14 16:xx 時点は Tom 能動使用中(idle 2.6s)で block。非侵襲チェックでは稼働健全(0%CPU/log
  エラー0/crash-invariant維持)を確認済。

## Tom queue (non-blocking, batched)
- device batch: リマインダー発火 / Touch ID / URL click / 整列 / 風船の見た目 / S3c 素材スクショ
- **S0.5 + monetization §5 (同一決定群・growth/HANDOFF-flote-monetization-protection-2026-07-11.md)**:
  配布形(直DL notarize vs MAS — 保護層3の可否を決める)/ トライアル日数(1-2週)/
  決済プロバイダ(Gumroad/Lemonsqueezy/MAS)/ 保護層の開始深度(層1のみ推奨)
- push 判断 / digest サンプルの形判定

## Post-build workstream (monetization handoff — アプリ完成後)
- トライアル判定+ライセンス検証を**公開リポ外**の閉じたコンポーネントに実装(層1)
- flote-lp 埋込DLとの接続 / 层2 validation endpoint は §5 決定後
