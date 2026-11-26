# やること

## 持ち主がやること（最初の1回）

- [ ] Apple Developer で App Group と App ID 2つを登録する（手順は CLAUDE.md）
- [ ] App Store Connect で新規アプリ「ウィルシー」を作る
- [ ] このリポジトリに Secrets 4つを登録する
- [ ] Actions の testflight を実行する

## 済んだこと

- 第1段階の実装（取り込み、解析、予定、マップ、検索、ジャンル絞り込み）。
- Actions の build でコンパイルが通ることを確認（2026-11-26）。実機での動作は未確認。

## 確かめたいこと（TestFlight で）

- 共有シートに「ウィルシー」が出て、保存できるか
- 端末内AIの日本語での読み取りの質
- ベクトル検索の当たり具合（しきい値は Search.swift の `best - 0.08`）
