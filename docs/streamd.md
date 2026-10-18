# streamd: エンコードしない自前の中継

## なぜ
- EPGStation の変換配信（ffmpeg のエンコード）は録画機の CPU を大きく使い、recpt1 / Mirakurun と取り合う
- 放送の TS は 15〜17Mbps だが、大半は映像。音声だけ欲しいときや回線が細いときは、映像のパケットは丸ごと無駄
- TS はパケット（188 バイト）単位で PID を見れば、デコードせずに要る・要らないを分けられる → CPU はほぼ使わない

## 今あるもの（server/streamd.py）
```
iPhone ──▶ streamd :23236 ──▶ Mirakurun /api/services/{id}/stream?decode=1
           │  PAT/PMT を読んで PID ごとに通す・捨てる
           │  PMT は残した ES だけに書き換え（CRC 再計算）
           ▼
  /live/{id}?video=0          音声 + 字幕だけ（約 0.2〜0.4Mbps）
  /live/{id}?video=1&data=0   映像 + 音声 + 字幕（データ放送の ES を除く）
  /health
```
- 実測（合成した 12Mbps の MPEG-2 + AAC の TS）: 音声のみで **1.5%** のサイズ、CPU は 20 秒分の処理に 0.07 秒
- 字幕（PES private data、component_tag 0x30〜0x38）は残す。データ放送（DSM-CC 0x0D など）は既定で捨てる
- PCR が映像の PID に乗っていたら PCR なし（0x1FFF）と書き換え、PCR 専用 PID（地デジに多い）なら残す
- PMT が 2 パケットにまたがる場合は書き換えずに通す（ISDB ではまず無い）

## 追っかけ再生（/timeshift）
```
GET /timeshift/{id}/start        貯め始める（貯めていればそのまま）。状態を返す。アプリは見ている間 5 秒おきに呼ぶ
GET /timeshift/{id}/info         状態だけ {"bytes", "seconds", "available_from", "stopped"}
GET /timeshift/{id}/play?from=S  バッファ開始から S 秒の位置から流す。貯まっている端に追いついたら、そのまま新しい分を待って流し続ける
GET /timeshift/{id}/stop         この端末はもう見ない（ほかに見ている端末も再生中の play も無ければ止めて消す）
```
- どれも `client=<端末 ID>` を付ける。`play` には `id=<バッファ番号>`（start が返す）も付け、作り直されていたら 404
- Mirakurun から原画質の TS を受けて `TIMESHIFT_DIR` に 32MB ごとのファイルで書くだけ（エンコードしない。CPU はほぼ使わない、ディスクの書き込みは約 2MB/s）
- `TIMESHIFT_MINUTES`（既定 30）より古いファイルは消す。30 分で約 3.5〜4GB
- `start` が `TIMESHIFT_IDLE` 秒（既定 180）来なくて、`play` も開いていなければ止めて消す
- Mirakurun には優先度 0 で頼むので、録画が始まってチューナーが足りなくなれば、こちらが先に切られる
- 一時停止して 30 秒以上読まないと、サーバーが接続を閉じる（アプリはその位置で開き直す）


```sh
curl 'http://<tailscale-ip>:23236/probe/<serviceId>?seconds=10'
# {"in_mbps": {"video": 13.1, "audio": 0.25, "caption": 0.01, "data": 0.9, "si": 0.1}, ...}
```
"other" には PMT に載らない PID（地デジの PCR 専用 PID 0x01FF など）が入る。
データ放送を捨てて意味があるかは、局ごとにこれで実測して決める（映像が大半なら、データを捨てても数 % しか減らない）。
`/live` を閉じたときもログに同じ内訳が出る。

## 動かし方（homeserver）
```sh
cp server/streamd.py ~/miratv-chapterd/
cp server/miratv-streamd.service ~/.config/systemd/user/
# HOST（Tailscale のアドレス）と MIRAKURUN（同じ機械なら 127.0.0.1 のポート）を合わせる
systemctl --user daemon-reload && systemctl --user enable --now miratv-streamd
curl http://<tailscale-ip>:23236/health
```
アプリは設定「中継 streamd」にこの URL を入れる（空なら使わない）。

## アプリ側
- 再生モード「音声のみ」: streamd があれば `/live/{id}?video=0` を開く。開けなければ、その画面では Mirakurun の原画質から端末で映像を捨てる方式に戻る
- TSPipeline: 音声のみのときは映像ストリームが無くても開ける
- 追っかけ再生: 原画質で見ている間、映像の下に「⏪15・一時停止・シークバー・LIVE」が出る。戻す・止めると `/timeshift/{id}/play?from=` に切り替え、LIVE で Mirakurun 直に戻る

## この先（エンコードせずにできること／できないこと）
- できる: 音声のみ、データ放送の除去、副チャンネル・EIT などの除去、複数台で同じ局を見るときの上流 1 本化
- できない: 映像そのものの軽量化。解像度・ビットレートを下げるにはエンコードが要る
  - やるなら GPU（VAAPI / QSV / NVENC）があるときだけ、CPU はほぼ使わずに済む。録画機の構成次第
- アプリ側で「データ切れが続いたら音声のみに自動で落とす」を足すと、回線が細いときに途切れず聴き続けられる
