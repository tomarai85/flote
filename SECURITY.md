# Security Policy

## Supported Versions

Flote は beta 版です。 現時点では `main` branch のみがサポート対象です。 安定版 release 後、 別途 LTS 方針を定めます。

| Version | Supported |
|---------|-----------|
| main    | ✅        |
| < 1.0   | ⚠️ best-effort のみ |

## Reporting a Vulnerability

セキュリティ脆弱性を発見した場合、 **公開 issue では報告しないでください**。 以下の private channel を使用してください:

### Option 1: GitHub Private Vulnerability Reporting (推奨)

1. 本リポジトリの [Security tab](https://github.com/tomarai85/flote/security) を開く
2. 「Report a vulnerability」 をクリック
3. 詳細 (再現手順 / 影響範囲 / 推奨修正案) を記入

GitHub の private channel 経由なので、 fix がライブまで非公開で進行します。

### Option 2: Email

GitHub アカウント不要の場合は、 メーカー maintainer に直接連絡:

- 連絡先 (= LP 経由): https://flote-app.vercel.app の Roadmap section から GitHub Watch 経由で contact

### What to expect

- **初回 acknowledge**: 5 営業日以内
- **初期評価**: 14 日以内 (= severity 判定 + 修正方針)
- **修正 + advisory 公開**: 高 severity は 90 日以内 (= responsible disclosure 標準)
- **謝辞**: 修正完了時、 advisory + release notes で 報告者を honor (= 希望する場合のみ)

## Out of scope

以下は本 policy の対象外です:

- macOS の Gatekeeper / Notarization 警告 (= 既知、 [LP の FAQ](https://flote-app.vercel.app#download) に記載済)
- AI Organize 機能で Ollama を使う際の Ollama 自体の脆弱性 (= 別途 Ollama project に報告)
- LP (= Vercel 配信) 側の脆弱性 (= 主要 source ではないが、 重大なら報告歓迎)

## Security features in place

- **GitHub secret scanning**: ENABLED (= push 時 + history 全 scan)
- **GitHub Push Protection**: ENABLED (= secret を含む push を block)
- **Dependabot security updates**: ENABLED (= 自動 dependency 更新)
- **`.env*` / `*.key` / `*.pem` / `DevSecrets.swift`**: `.gitignore` で構造的 exclude
- **License (FSL)**: 「中身を読み取っていないか」 を source 監査で確認可能 = 透明性 moat

## Why source-available?

- 個人開発者が「ある日消える」 risk への保証 (= fork で継続可能)
- AI に書いた内容を「中身読み取ってない」 を code で確認可能
- 自分で patch / fix できる権利を user に残す

詳細は [README.md](./README.md) の Why Open section 参照。
