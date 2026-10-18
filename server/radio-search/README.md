# radio-search

Fast archive search for ~500k radio programs (VPS2 `radiko.db`) for MiraTV. Design: `docs/archive-search-design.md`.

- `radio_search.py` — stdlib-only service: sidecar SQLite (`search.db`) with an FTS5 index over character-split normalized text
  (any query length works), read-only on `radiko.db`, 5-minute incremental sync + hourly reconcile (nzb / playable flags).
- `run.sh` — pm2 entry (`nice -n 10`, `ionice -c3`): `pm2 start run.sh --name radio-search --interpreter bash --max-memory-restart 400M`.
- `test_radio_search.py` — self-test against a fake radiko.db.
- API: `GET /search?q=&station=&from=&to=&playable=1&sort=new|old&limit=&offset=`, `GET /stations?q=&playable=1`, `GET /health`.
- `playable_from.txt` (next to `search.db`, `YYYYMMDD`) moves the "playable" floor as lost nzb files are restored
  (default 20260713). Files present in `/home/ubuntu/usenet/nzb` count as playable regardless of the date.
- First build: ~500k rows in ~40 s, index ~275 MB, queries 20-300 ms.
