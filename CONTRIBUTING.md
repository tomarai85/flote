# Contributing to Flote

ありがとう、 関心を持ってくれて。 Flote は個人開発の source-available product です。 contribution policy はちょっと特殊なので最初に読んでください。

## TL;DR

- **Issue OK** = bug report / feature request / 質問 全部歓迎
- **PR は当面 close 運用** = License 戦略 (= 2 年後 OSS 化) の都合上、 外部 PR は accept しません
- **2 年後 (2028-05-27) に PR open** = License が自動 Apache 2.0 化したタイミングで normal な OSS contribution workflow に切替

## Why PR closed for now?

License = [FSL-1.1-ALv2](./LICENSE.md) (= Functional Source License) で運用しています:

- 商用 fork (= 「同 product を売る」) を 2 年間禁止
- 2 年後 (= 2028-05-27) に自動 Apache 2.0 化 → 全 community contribution welcome

この期間中に外部 PR を merge すると、 contributor の copyright が「2 年制約付き」 license に縛られてしまう問題が発生します (= 2 年後 Apache 化したいのに contribution 側 が同意してない、 等)。 これを避けるため、 PR は 2 年経過するまで close 運用にしています。

## What you CAN do (= 歓迎)

### 1. Issue を立てる

- **Bug report**: 再現手順 + 環境 + 期待動作 + 実動作 を書いて issue ください
- **Feature request**: なぜ欲しいか、 代替手段を試したか、 を書いてください
- **質問**: discussion 形式の質問 OK

template は `.github/ISSUE_TEMPLATE/` に用意してあります。

### 2. Fork して自分で fix を試す

FSL は **個人 + 内部利用 OK** なので、 fork して自分用に patch を当てる行為は問題ありません。 結果を issue で共有してくれると、 maintainer が公式 patch に取り込みます (= attribution は issue thread で残す)。

### 3. Security 脆弱性報告

[SECURITY.md](./SECURITY.md) を参照してください。 Private Vulnerability Reporting flow が整備されています。

## What you CANNOT do (= 制限)

- **商用配布** (= Flote を fork して有料で売る、 SaaS として hosting して課金 等) = 2 年間禁止
- **PR を送る** = 受け付けません (= 上記 license 都合)

## After 2028-05-27 (= 2 年後)

License が自動 Apache 2.0 化したら:
- PR welcome
- Commercial fork も OK
- Contribution Workflow (= fork + PR + review) を standard OSS 形式で再開

それまでは「issue 中心 + fork 自由」 で運営しています。

## Maintainer

- [@tomarai85](https://github.com/tomarai85) = Tomonori Arai (= Tom)
- a [Direct](https://direct-homepage.vercel.app) product

質問あれば issue で気軽に聞いてください。
