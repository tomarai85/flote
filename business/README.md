# Flote ビジネスロジック

Floteというプロダクトの「なぜ存在するか」「誰のためか」「何が独自か」を言語化し続ける場所。

## このフォルダの役割

- Floteの企業理念・ビジョン・戦略の**正本 (single source of truth)**
- 機能仕様や技術判断は含めない。それらは `.harness/` や `memory/` に任せる
- 対話を通して少しずつ書き足す。未確定でも良い、むしろ未確定こそ `99-open-questions.md` に残す

## 読む順序

| # | ファイル | 問い |
|---|---------|------|
| 01 | [vision.md](01-vision.md) | Floteで世界をどう変えたいのか / なぜ今か |
| 02 | [target.md](02-target.md) | 誰の、どの瞬間の、どんな痛みを解決するのか |
| 03 | [core-value.md](03-core-value.md) | 機能説明を超えた一文で、Floteは何か |
| 04 | [moat.md](04-moat.md) | なぜFloteでなければならないのか |
| 99 | [99-open-questions.md](99-open-questions.md) | 未確定の論点、対話で埋めていく場 |

## 運用ルール

1. **確定したことだけ書く**。迷いがあるものは `99-open-questions.md` へ
2. **更新時は日付を残す**。各ファイル末尾に「更新履歴」を置く
3. **既存の戦略メモとの関係**: `memory/project_strategy_foundation.md` は 2026-04-14 時点のスナップショット。このフォルダが正本となった後は、memoryは「business/ 参照」のポインタ化
4. **対話ログはここには書かない**。対話の結論だけを書く

## 関連ドキュメント(参考)

- `memory/project_strategy_foundation.md` -- 2026-04-14 対話スナップショット(旧)
- `memory/project_commercialization.md` -- 商用化技術ロードマップ
- `memory/project_flote_overview.md` -- 技術構成・機能

## 更新履歴

- 2026-04-19: フォルダ初期化、雛形と未確定論点を記載
