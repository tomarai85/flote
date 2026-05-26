# 04. Moat

> 問い: なぜFloteでなければならないのか (持続的優位性)

## 現時点で確定していること

### 1. Source-available + delayed paywall による信頼性 moat (2026-05-27 確定)

- **License**: Functional Source License (FSL-1.1-ALv2) で source 公開 + 商用 fork 2 年禁止 + 2 年後 (2028-05-27) 自動 Apache 2.0 化
- **意味**: 「中身読み取ってない」 を code で確認可能、 「ある日開発者が消える」 risk への保証、 fork で継続可能 = **個人開発の構造的弱点を構造的強みに反転**
- **Why moat になり得るか**:
  - クラウド一択 (Mem.ai / Reflect / Notion AI) は同じ guarantee を出せない
  - 大手 (Apple Stickies / Bear) は OSS 化のインセンティブなし
  - 小規模個人開発でも、 透明性 commitment は zero-cost で差別化
- **Why moat ではないか (= 自己批判)**: 競合も同 license に切り替え可能、 短期は moat だが長期は標準化リスク → だから 2 年後 Apache 2.0 移行で「先行公開者」 narrative を保持

### 2. Monetize 戦略 = freemium-light + delayed paywall (2026-05-27 確定)

- **当面**: 完全無料 beta、 機能制限なし
- **将来**: 規模拡大 (= 口コミ / 検索 hit) が出てきたら持続化のため ¥300 程度の安価 paid 化を検討
- **既存ユーザー grandfather** / 移行方針: 決定時に transparent に共有 (= 現状未定、 Phase 2 issue)
- **Why この戦略か**:
  - 高単価 SaaS (¥980-2980/月) と差別化 = 「安すぎて proxy 不可」 の volume play
  - paid 化を「危機」 でなく「成長祝い」 narrative にできる
  - 個人開発で課金 infra 整備 burden 小さい (¥300 一括や Gumroad 簡易課金で済む)

### 3. ライセンス + monetize の整合性

- FSL で「fork して同じものを売る」 を 2 年禁止 → Tom が paid 化した後の「fork 無料版」 出現を防止
- 2 年後 Apache 2.0 化 → community contribution が活発化、 paid 版は「公式サポート + cloud sync + 早期機能」 等で差別化
- 「paid 化したら user 離れる」 risk への対抗: source-available なので「金払いたくない user は self-host」 退路あり → backlash 最小化

## 既存の叩き台 (2026-04-14 スナップショット)

**本丸: 使うほど自分専用に育つAI分類**

- 使うほどユーザーの思考パターン・判断基準・タスク分類をAIが学習
- 「あなた専用に育ったFlote」は他者が再現不可
- パーソナライズ学習 × 乗り換えコスト = 二重ロックイン

**サブ差別化**:
- 常駐スティッキー (Option+Space即起動) ≠ Apple Stickies (AIなし)
- 走り書き→テキスト図式 ≠ Napkin AI (画像図式、Web、常駐なし)
- 軽さ (160px固定パネル) ≠ Bear/Apple Notes (全画面エディタ)
- ローカルOllama+Claudeハイブリッド ≠ Mem.ai/Reflect (クラウド一択)

## 検討すべき問い

- **「使うほど育つ」は本当に差別化になるか**: Notion AI, Mem.ai, Reflect, Superhuman も同様のことを謳っている。何が Flote 固有の育ち方か
- **ロックインは本当に効くか**: ユーザーの学習データはエクスポート可能か? 不可能なら倫理的問題 / 可能なら乗り換え可能
- **「軽快な常駐」は競合が真似できないか**: 真似される技術的障壁は存在するか
- **テキスト図式**は強いか: そもそも需要があるか / 誰が欲しがるか
- Moat の階層: (1) 機能的 (誰もがコピー可能) / (2) データ的 (ユーザー学習) / (3) ブランド的 (Bearのような美意識) / (4) エコシステム的 (Notionのテンプレ) のどれで勝つのか

→ 詳細は `99-open-questions.md` で議論する

## 更新履歴

- 2026-04-19: 初期化。既存叩き台を記録、未確定扱い
