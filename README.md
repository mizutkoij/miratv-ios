# MiraTV — Step 1: 最小プレイヤー

Mirakurun の MPEG-2 TS を iPhone 上で直接デコードして再生する、独自プレイヤーの土台です。
サーバー側のトランスコードは不要です。

## 構成

```
Mirakurun /api/services/{id}/stream?decode=1
   │ HTTP (libavformat)
   ▼
TSPipeline（専用スレッド）
   ├─ 映像: mpeg2video ソフトデコード → bwdif デインターレース → NV12 CVPixelBuffer
   ├─ 音声: AAC デコード → swresample (5.1/デュアルモノ → 2ch 48kHz Float32)
   └─ (Step 2/3 用に字幕・データ PID は今は discard)
   ▼ CMSampleBuffer
PlayerEngine
   AVSampleBufferDisplayLayer.sampleBufferRenderer ┐
   AVSampleBufferAudioRenderer                     ├─ AVSampleBufferRenderSynchronizer（音声基準）
```

| ファイル | 役割 |
|---|---|
| `Mirakurun/MirakurunClient.swift` | `/api/services` 取得とストリーム URL 生成 |
| `Player/TSPipeline.swift` | 受信・デマックス・デコード・変換（FFmpeg） |
| `Player/PlayerEngine.swift` | レンダラへの投入と A/V 同期、再生開始バッファ |
| `UI/ChannelListView.swift` | 地上波/BS/CS のチャンネル一覧と設定 |
| `UI/PlayerView.swift` | 全画面プレイヤー（DAR 補正、統計表示） |

## セットアップ

1. Mac で XcodeGen を入れてプロジェクト生成
   ```sh
   brew install xcodegen
   cd MiraTV
   xcodegen
   open MiraTV.xcodeproj
   ```
2. 初回は Swift Package（kingslay/FFmpegKit）の取得に時間がかかります（バイナリ xcframework が大きい）
3. Signing & Capabilities で自分の Team を選ぶ（`project.yml` の `DEVELOPMENT_TEAM` に入れておくと再生成しても消えない）
4. 実機で起動 → 右上の歯車で Mirakurun の URL（例 `http://192.0.2.30:40772`）を入力
5. 初回接続時に「ローカルネットワーク」の許可ダイアログが出るので許可

> シミュレータでも動きますが、デコード負荷の確認は必ず実機で。

## 動作確認ポイント

- 再生中に右上の ⓘ で、解像度・DAR・音声チャンネル数を表示
- 地デジは `1440x1080 DAR 1.778` になっていれば SAR 補正が効いている
- 5.1ch 番組 ↔ ステレオ番組の切り替わりで音が止まらないか（リサンプラ再構築の確認）

## 調整つまみ

- `PlayerEngine.startupBuffer`（既定 0.8 秒）: 小さくすると選局が速いが、途切れやすい
- `TSPipeline.rebuildFilterGraph` の `bwdif=mode=send_frame`: `send_field` にすると 60p で滑らかになる（CPU 約 2 倍）

## 既知の制限（Step 1 時点）

- PTS の 33bit ラップアラウンド（約 26.5 時間連続視聴）は未対応
- 局側の解像度切替時に一瞬乱れることがある（フィルタグラフ再構築）
- デュアルモノ（主/副音声）は左右に分かれたまま出る → 切替 UI は Step 1.5 で
- 選局直後は次の I フレームまで映像が出ない（MPEG-2 の GOP 仕様）
- 受信が途切れたら「再接続」ボタンで手動復帰

## ライセンス注意

kingslay/FFmpegKit の公開版は **GPL-3.0** です。自分用・TestFlight の個人配布なら問題ありませんが、
App Store で配布するなら LGPL 構成で FFmpeg を自前ビルドして差し替える必要があります。

## ラジオ（radio-web 連携）

TV とは別系統で、AVPlayer ベースの `RadioPlayer` を使います（ロック画面・コントロールセンター・バックグラウンド再生対応）。

```
radio-web (:8090, Tailscale 内)
  ├─ GET  /api/stations                 局カタログ（全ソース混在 454 局）
  ├─ GET  /live/radiko/{id}.m3u8        ┐
  ├─ GET  /live/nhk/{area}/{band}       ├─ ライブ → AVPlayer（HLS / Icecast）
  ├─ GET  /live/listenradio/{id}/...    ┘
  ├─ GET  /api/station/schedule         日別番組表（05:00 区切り、nzb 付き＝アーカイブあり）
  ├─ POST /api/archive/play {nzb}       → /archive/stream/{token}（audio/mp4, Range 可）
  └─ POST /api/archive/prefetch {nzb}   次の回を裏で準備
```

| ファイル | 役割 |
|---|---|
| `Radio/RadioWebClient.swift` | API クライアントとモデル（揺れのあるフィールドは寛容にデコード） |
| `Radio/RadioStreamResolver.swift` | 局 → 再生エンジン（AVPlayer / FFmpeg / 未対応）の振り分け |
| `Radio/RadioPlayer.swift` | ライブ・アーカイブ再生、+25 秒の頭出し、404 時の play 取り直し、自動で次の回へ＋prefetch、Now Playing |
| `UI/RadioView.swift` | 地域別局一覧、局詳細（ライブ＋過去 7 日の番組表）、ミニプレイヤー |

挙動のポイント:
- アーカイブ初回は usenet から取得＋remux で 40 秒前後かかる → ミニプレイヤーに経過秒を表示、タイムアウト 180 秒
- サーバーが前番組の末尾 25 秒を頭に継ぎ足すので、読み込み後に 25 秒へシーク
- トークンはサーバー再起動・1 時間無アクセスで失効 → 再生失敗時に 1 回だけ `play` を取り直す
- 番組表の後続回をキューにして、終了時に自動で次へ（次の回は先に prefetch）
- テレビ再生を始めるとラジオは止める

未対応（次ステップ）:
- fmplapla 91 局（Ogg）: TV 用の FFmpeg パイプラインに音声のみモードを足して再生する予定
- JCBA 144 局（WebSocket + Ogg/Opus）: WebSocket 受信 → FFmpeg に流す自前の入力が必要
- NHK のアーカイブ: `archive/search?station=nhk:R1` 経由の画面
- radio-web 側の録音・予約 API（`/api/record/*`, `/api/reserve*`）

## Usenet のアーカイブ（nzb-dl 連携）

録画タブの「アーカイブ」で、Usenet に上げた録画を探してストリーム再生します（ci50、詳細は `docs/changes-usenet-archive.md` と `docs/nzb-stream-playback.md`）。

```
nzb-dl (VPS1 :8083, Tailscale 内, API キー)
  ├─ GET /api/items?category=tv&status=on   一覧 → 端末に保存して端末で検索（差分だけ取り足す）
  ├─ GET /api/items/lookup?folder=          本体の拡張子（ts / mp4 / 7z）
  └─ GET /api/stream/<id>                   本体（Range）→ TS は TSPipeline、mp4 は AVPlayer
```

設定 ›「nzb-dl（Usenet のアーカイブ）」に URL と API キーを入れます（キーはリポジトリに置かない）。

## 次のステップ

- **Step 2: 字幕** — `AVMEDIA_TYPE_SUBTITLE`（codec `arib_caption`）の discard を外し、パケットを libaribcaption に渡して描画したビットマップを PTS 同期で重ねる
- **Step 3: データ放送** — DSM-CC カルーセルを組み立てて web-bml を透過 WKWebView で動かし、リモコン操作 UI と接続
