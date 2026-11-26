# ウィルシー（well-see）

iPhone / iPad アプリ「ウィルシー」。ほかのアプリや Web サイトから共有で取り込んだものを、
端末の中で解析して登録し、あとから言葉で探せるようにする。

## いま入っている機能（これだけ）

1. 共有シートから取り込む（URL・文字・画像）。入力は何も求めない。
2. 取り込んだものを解析し、共有元・ジャンル・取り込み日を付けて登録する。
3. 日付のあるものは「予定」に並べ、場所のあるものは「マップ」にピンを立てる。
4. ベクトル検索（意味の近さ）と言葉の一致を合わせた検索。
5. ジャンルと、その中の分類（アニメ、寿司 など）での絞り込み。ピン留めと削除はスワイプで。
6. 見た目はシンプルに。細部は丁寧に。

状態（気になる／行きたい）、メモ、きっかけ、ふりかえり、友人への共有、課金は**まだ入れていない**。
持ち主が1つずつ決めていく方針なので、頼まれていない機能を足さない。

## 前提

- 持ち主の手元にあるのは iPad だけ。Mac も Xcode もない。
- ビルドと配信はすべて GitHub Actions の mac ランナーで行う。
- この開発環境（Linux）では Swift をコンパイルできない。「push → Actions のログを読む → 直す」で進める。
- **ワークフローは手動実行（workflow_dispatch）だけ**。push で自動実行する設定を足さない。

## 構成

| 場所 | 中身 |
| --- | --- |
| `project.yml` | XcodeGen の設定。`WellSee.xcodeproj` を生成する（xcodeproj はコミットしない） |
| `Shared/Inbox.swift` | アプリと拡張の受け渡し用の置き場（App Group）と、画像を小さくする道具 |
| `WellSeeShare/` | 共有シートに出る拡張。受け取ったものを置き場に書いて閉じるだけ |
| `WellSee/Models.swift` | `Item`（取り込んだ1件）と `Genre`（10ジャンルと色） |
| `WellSee/Analyzer.swift` | 解析。ページの埋め込み情報 → サイトごとの決まり → 端末内AI の順 |
| `WellSee/Search.swift` | ベクトル化（`Embedder`）と検索（`SearchEngine`） |
| `WellSee/Importer.swift` | 置き場から取り込み、順番に解析する。カレンダー登録もここ |
| `WellSee/Views/` | 画面（ホーム／マップ／予定／詳細）。ホーム1画面で、操作は画面の下に集める |
| `.github/workflows/build.yml` | 署名なしのコンパイル確認 |
| `.github/workflows/testflight.yml` | アーカイブ → 権限付け → 署名 → TestFlight |
| `docs/design.md` | 仕様 |

- Bundle ID：アプリ `com.sawswork.wellsee` ／ 拡張 `com.sawswork.wellsee.share`
- App Group：`group.com.sawswork.wellsee`
- ホーム画面の名前：ウィルシー ／ プロジェクト名：WellSee
- 最低対応 OS：iOS 26 ／ Swift の言語モード：5

## Apple 側で一度だけ行う準備（持ち主がブラウザで行う）

API キーでは App Group を有効にできないため、手で登録する。
Apple Developer の「Certificates, Identifiers & Profiles」で：

1. Identifiers → App Groups → `group.com.sawswork.wellsee` を作る。
2. Identifiers → App IDs → `com.sawswork.wellsee` を作り、App Groups にチェックを入れて上のグループを選ぶ。
3. 同じく `com.sawswork.wellsee.share` を作り、App Groups で同じグループを選ぶ。
4. App Store Connect で新規アプリを作る（名前：ウィルシー、Bundle ID：`com.sawswork.wellsee`）。

## 必要な Secrets（リポジトリの Settings → Secrets and variables → Actions）

| 名前 | 入れるもの |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API キーの「キー ID」 |
| `ASC_ISSUER_ID` | 同じ画面の「Issuer ID」 |
| `ASC_PRIVATE_KEY` | `AuthKey_XXXXXXXXXX.p8` の中身全部 |
| `APPLE_TEAM_ID` | Apple Developer の「チーム ID」 |

white-search と同じ値でよい。

## 署名のしくみ（大事）

アーカイブは署名なしで作るので、そのままでは App Group の権限が入らない。
`testflight.yml` の「権限（App Group）を付ける」で、証明書なしの仮署名（`codesign --sign -`）を
拡張 → アプリの順に行い、権限を持たせてから書き出す。この手順を消すと、
共有シートで「保存できませんでした」になる（置き場が開けないため）。

## 守るべきルール

- 仕様は `docs/design.md` どおり。変えるときは設計書も直す。
- 解析・検索は端末の中で行う。通信するのは、取り込んだ URL のページとその画像を読むときだけ。
  分析ツール、広告、外部 SDK、自前サーバーを入れない。
- 端末内AI（Foundation Models）が使えない端末でも動くようにする。AI は足りないところを埋めるだけ。
- Foundation Models の API は記憶で書かず、公式文書で確かめる。
  `https://developer.apple.com/tutorials/data/documentation/foundationmodels.json`
- 解析のしくみを変えたら `Item.currentAnalysisVersion` を上げる（既存のものが次の起動で読み直される）。
- `Item` に項目を足すときは初期値を付ける（既存のデータを引き継ぐため）。
- コード内のコメントと画面の文言は日本語。
- 持ち主にしか決められないことは、作業を止めて聞く（推奨を添えて、1つずつ）。
- 変更したらこまめにコミットして push する。
