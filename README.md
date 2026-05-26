# Flote

> **走り書きが、勝手に整理される。**
>
> Option+Space で付箋が浮かぶ。思いついたことをそのまま書く。Organize ボタンを 1 回押す。AI がタイトル・要点・チェックリストに変換する。それだけ。

- 公開リポジトリ: https://github.com/Tomonori-Arai/flote (= Phase 1 公開予定)
- 公式 LP: https://flote-website.vercel.app
- 親 brand: [a Direct product](https://direct-homepage.vercel.app)
- License: [FSL-1.1-ALv2](./LICENSE.md) (= 2 年後 Apache 2.0 化)
- Status: **無料 beta** / macOS 14 (Sonoma) 以降 / Apple Silicon

[English README](./README.en.md)

---

## Why Flote

普通のメモアプリは「整理する力がある人」向けに作られている。
Notion / Obsidian / Apple Notes — どれも、 タグを設計し、 階層を引き、 リンクを張る能力が前提。

そうじゃない人もいる。
**思いついたことが頭から蒸発する前に、 とりあえずどこかに書いておきたい。 整理はあとで考えたい (= 本当は考えたくない)。**
そういう人のためのメモ帳が、 これまでなかった。

Flote はその穴を埋めるために作っている。

- 起動 2 秒 (= 常駐)、 Option+Space で 160px の付箋がデスクトップに浮く
- 走り書きを Organize ボタンで AI が構造化 (= タイトル / 要点 / アクションリスト)
- メモは Mac の中だけに保存。 クラウドに送らない (= AI 整理時のみ API と通信、 ローカル AI Ollama 使用時は完全オフライン)
- SwiftUI + AppKit ネイティブ。 Electron じゃない

「整理できない自分」 のための、 整理されたメモ帳。

---

## Install / Quick Start

### macOS

公式 LP からダウンロードするのが最短:

→ https://flote-website.vercel.app

ターミナル 1 行版 (= LP の install hero と同じ):

```
curl -fsSL -o /tmp/Flote.zip https://flote-app.vercel.app/Flote.zip && \
  unzip -oq /tmp/Flote.zip -d /Applications/ && \
  open /Applications/Flote.app
```

初回起動後:

1. メニューバーに **Flote** アイコンが出る
2. `Option + Space` で付箋が浮かぶ
3. 何か書く → Organize ボタンで AI 整理

AI Organize (任意・5 分): [Ollama](https://ollama.com/download/mac) を入れて `ollama pull gemma3` するとローカル AI で動く。 長文や複雑な整理は Claude API key を Settings から入れると Claude で処理される。

> ⚠️ 現状 Apple Developer Program 未加入のため、 初回起動時に「開発元を確認できません」 警告が出る。 `Control` + クリック → 「開く」 で許可。 正式署名 + 公証版は Phase 2 で。

### Build from source

```
cd apps/macos
open Flote.xcodeproj   # Xcode 16+ / Swift 5.10+
```

`Cmd + R` で起動。 API key を使う dev build は Settings UI 経由で Keychain 保存 (= 旧 DevSecrets.swift fallback は `.gitignore` 済、 公開リポには含まれない)。

---

## Features

| 機能 | 説明 |
|---|---|
| **常駐 + 浮遊付箋** | メニューバー常駐、 `Option+Space` で 160px の付箋がどのアプリの上にも浮かぶ |
| **AI Organize** | 走り書きをタイトル / 要点 / チェックボックス付きアクションリストに 1 ボタンで変換。 短いメモはローカル Ollama、 長いメモは Claude API |
| **学習型分類** | 使うほど Flote があなたの分類パターンを学習。 Group へ自動振り分け |
| **Inbox 一括分類** | 溜まった未分類メモを 1 ボタンで AI 分類、 Inbox を空にできる |
| **Undo 対応** | Organize の結果が気に入らなければ `Cmd+Z` で走り書きに戻る |
| **カスタムショートカット** | 新規ノート / Groups 表示 / Archive のキーバインドを変更可能 |
| **データは Mac の中だけ** | メモは全てローカル。 AI 整理時のみ API と通信 (= Ollama 使用時は完全オフライン) |

詳しい使い方は LP の Before/After セクション参照: https://flote-website.vercel.app

---

## License -- FSL-1.1-ALv2

Flote は **Source-available** で公開している:

- **今すぐ可能** (= Permitted Purpose):
  - 個人利用 (= 自分の Mac で end user として使う)
  - 内部利用 (= あなたの会社 / 研究室 内で employee や contractor に配って使う)
  - 非商用の教育 / 研究
  - source code を読む / 改造する / 自分の fork を作る
- **禁止** (= Competing Use):
  - Flote を SaaS / 商用 product としてホスティングし、 第三者に提供する
  - Flote と同等機能を提供する商用 product を作る
- **2 年後** (= 2028-05-27 以降): 自動的に **Apache License 2.0** に切り替わる (= [Functional Source License](https://fsl.software/) の future grant clause)

詳細は [LICENSE.md](./LICENSE.md) を参照。 「FSL-1.1-ALv2」 = 「FSL-1.1-Apache-2.0」 と同義 (= ALv2 = Apache License Version 2.0)。

### なぜ FSL を選んだか

- **MIT / Apache 即時公開**: 「同じものを別 brand で売る」 fork を防げない
- **AGPL**: コミュニティに「使いにくい」 印象 (= 派生 product 全 source 公開強制)
- **完全クローズド**: 個人開発の透明性 / 信用が出せない
- **FSL** はこの 3 つの中間。 2 年の保護期間後に自動 OSS 化することで、 「個人開発の速度 + 真似され防止 + 長期 community 還元」 を同時に取る

---

## Roadmap

### Phase 1 (= 2026-05、 本リポジトリの公開)
- GitHub source-available 化 (= FSL-1.1-ALv2)
- LP に GitHub link + 無料 beta narrative + 事前 email waitlist 追加
- 無料 beta 継続 (= 当面 0 円、 期間制限なし)

### Phase 2 (= 時期未定、 freemium-light 検討)
- 認知拡大 (= GitHub star / DAU / AI 検索 hit のいずれか) 確認後に 新規 user 対象で ¥300 級 paid 化を検討
- 既存無料 user の grandfather 設計は Phase 2 で別決定
- pricing 決定タイミングは「AI 検索で Flote が hit する程度になった頃」 を 1 つの目安に置いている
- waitlist email 実配信 (= Loops / ConvertKit / Buttondown 等で検討)
- Apple Developer Program 加入 + 正式署名 + 公証
- Flutter Windows 版 配布

### Phase 3 以降
- 設定同期 (= Mac 複数台 / Mac+Windows)
- iOS 版検討 (= Helix iOS の delivery path 共有後)

### 公開戦略についての注記
- 現在 LP は `robots.txt` + `X-Robots-Tag: noindex` で検索 engine から非公開化している (= `website/vercel.json`)
- これは「LP を AI 検索や Google で見つけられる level までは brand 化したくない、 Mac dev community 内の口コミ伝播から始めたい」 という Phase 1 stance
- Phase 2 で「discoverability を開ける」 判断を別途行う (= roadmap 上 上記 ¥300 化 timing と同期する可能性が高い)

---

## Contributing

Phase 1 期間中は **Issue 受付のみ**:

- バグ報告 / 機能要望 / 使い勝手 feedback → GitHub Issues に大歓迎
- Pull Request → **当面 close 運用**。 個人開発の速度を維持するため、 2 年後の OSS 化 (= Apache 2.0 自動移行) timing で PR 受付を再開する予定

理由:
- Phase 1 は brand voice / 設計思想を locked-in する段階
- 個人開発者 1 人で merge / review する code review 帯域がない
- 2 年経って Apache 2.0 化した時点で fork + 改造 + community 主導 を始められる構造

緊急の security 報告は Issue ではなく direct contact 推奨。

---

## Acknowledgements

- **Flote is a Direct product.** Direct は 荒井 知憲 (Tomonori Arai) が個人開発で運営する Mac native tool portfolio。 兄弟 product: [Helix](https://direct-homepage.vercel.app) (= privacy-first Chromium fork browser)。
- 走り書きを構造化する AI 処理は [Claude](https://www.anthropic.com/claude) (= Anthropic) と [Ollama](https://ollama.com) (= local LLM runtime) を併用
- アップデート配信は [Sparkle](https://sparkle-project.org) framework

---

## Links

- LP: https://flote-website.vercel.app
- Direct (= parent): https://direct-homepage.vercel.app
- Author: Tomonori Arai (= 荒井 知憲) -- @TomArai85 on X (= 個人 brand)
- License: [FSL-1.1-ALv2](./LICENSE.md)
- This README: 日本語 primary。 [English README](./README.en.md) は派生。
