# ci39: 録画でも PiP（2026-10-19）

- TS の録画（自前エンジン）: 再生画面に PiP ボタン（縦は操作行、横は上のバー）
  - PiP のウィンドウにもシークバー・一時停止・±15 秒が出る（`PiPController.FileControls`）
  - 時刻は映像のサンプルと同じ時計（PTS 秒）で、範囲は [先頭の PTS, 先頭 + 長さ]
  - 一時停止・長さの確定・シークのたびに `invalidatePlaybackState()` で PiP の表示を更新
- 変換済み mp4 の録画: SwiftUI の VideoPlayer から AVPlayerViewController に変更（PiP ボタン付き、アプリを閉じると自動で PiP）
- ライブは今までどおり（シーク・一時停止なし）
- 再生画面を閉じると PiP も終わる（ライブと同じ。画面を閉じても PiP を続けるのは別対応）
