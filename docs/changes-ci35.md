# ci35: 自前の中継 streamd と音声のみの軽量化（2026-10-19）

- server/streamd.py（新規）: Mirakurun の TS から要らないパケットを捨てるだけの中継。エンコードなし。詳細は docs/streamd.md
- 再生モード「音声のみ」は streamd 経由（約 0.3Mbps）。streamd に繋がらなければ自動で Mirakurun の原画質から
- 設定に「中継 streamd」の URL と接続テスト
- TSPipeline: 音声のみのときは映像の無い TS も開ける
