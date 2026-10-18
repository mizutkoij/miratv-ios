# ci50: Usenet のアーカイブをストリーム再生（2026-10-19）

Usenet に上げた録画（VPS1 の nzb-dl が持つ NZB）を、MiraTV から探して、ダウンロードを待たずに再生できるようにした。
設計と前提の調査は `docs/nzb-stream-playback.md`。サーバー側（nzb-dl）は変更していない。

## 使い方
1. 設定 ›「nzb-dl（Usenet のアーカイブ）」に URL（Tailscale のアドレス、`http://100.x.x.x:8083`）と API キーを入れる → 接続テスト
2. 録画タブ ›「アーカイブ」。初回だけ一覧をまとめて取得する（約 7.6 万件、ページ 1000 件ずつ）。途中でも 2000 件目から見え始める
3. 検索欄で番組名・局・日付（`阪神 0527`、`5/27` など）。全角/半角・ひらがな/カタカナは区別しない。局はメニューで絞れる。「続きから」で途中まで見たものだけ
4. タップで再生

## 再生の仕組み
- 一覧: nzb-dl の `GET /api/items?category=tv&status=on`。検索 API が無いので、全件を端末（Application Support）に保存して端末で探す。
  2 回目からは保存分をすぐ出し、新しい順に 1 ページ見て、保存済みの件に届いたら止める（差分だけ）。
  件数がサーバーと合わなければ（有効/無効の切り替えなど）自動で全件を取り直す。更新ボタンの長押しでも全件取り直し
- 名前 `YYYYMMDD-HHMMSS <局> <番組名>[字][デ]… [reupload-N].nzb` から放送日時・局・番組名・記号を読む。
  同じ放送の再投稿 `[reupload-N]` は 1 件にまとめ、本命が読めないときの予備にする
- 開くとき `GET /api/items/lookup` で本体ファイルの拡張子を確かめる（1 回だけ、端末に覚える）
  - `.ts`: いつもの自前エンジン（TSPipeline）で `GET /api/stream/<id>` を Range で読む。シーク・字幕・PiP・写真・速度が使える。
    長さは libavformat が末尾の PTS から出す（出せないときだけ大きさから約 16Mbps で見積もる）
  - `.mp4`: AVPlayer。URL に拡張子が無いので `AVURLAssetOverrideMIMETypeKey` で mp4 と教える
  - `.7z`（2026-09-18 より前の暗号化投稿）: ストリームできないので「再生できません」と出す。再投稿が別形式であればそちらを試す
- 再生に入る前に失敗したら（記事の欠け等）、再投稿があれば自動で切り替える。途中で止まったら「もう一度」「再投稿で再生」
- 続きから再生（`nzb-<id>` で録画と同じ仕組み）、ミニプレイヤー、ロック画面・Dynamic Island は録画と同じ

## 知っておくこと
- 初めて触る位置は nzb-dl が Usenet から取るので 1〜3 秒。シークは位置を数回測り直すので、冷えた位置だと十数秒かかることがある。
  シークバーは指を離したときだけ読みに行く
- 欠けた記事は nzb-dl が 0 で埋めるので、エラーではなく一瞬の乱れになる（「欠けあり」の表示はまだ無い）
- API キーは端末の UserDefaults に置く。リポジトリには入れない。キーは削除もできる API のものなので、MiraTV は読み取りの API だけを呼ぶ
- Eweka の接続は他のサービスと共有（nzb-dl は 14 本まで）。見ている間に他が詰まるようなら `/api/conns` の `refused_too_many` を見る

## ファイル
- `MiraTV/Usenet/NzbDlClient.swift`: API クライアント（応答の形が細部まで未確認なので寛容に読む）
- `MiraTV/Usenet/UsenetCatalog.swift`: 一覧の保存・差分取得・名前の解釈・再投稿のまとめ・検索
- `MiraTV/UI/UsenetArchiveView.swift`: 録画タブの「アーカイブ」
- `MiraTV/UI/UsenetPlayerView.swift`: 再生画面
- `PlaybackSession`（`.usenet`）、`RecordingsView`（セグメント追加）、`SettingsView`（URL・キー・接続テスト）、`WatchPositions`（文字列のキー）

## 未確認（実機・実サーバーで最初に見るところ）
- `/api/items` と `/api/items/lookup` の応答のキー名（`items`/`total`、`files` の中身）。違ったら一覧が 0 件・拡張子が「?」になる → デバッグログの `[nzb]` を見る
- `/api/items` の `limit` の上限（1000 が切られても、空のページが返るまで送るので取りこぼさない）
- mp4 の Content-Type と AVPlayer の相性
- 冷えた位置へのシーク時間（数か所で測る）

## 次にやれること
- 欠けの有無（`/api/usable`）を一覧に出す
- 暗号化 7z を nzb-dl の extract で準備してから再生
- 野球中継（GAORA・スカイA など）の絞り込みボタン
