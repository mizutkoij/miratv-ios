# Archive search at ~460k items — design (2026-10-19)

## Problem
MiraTV lists/searches archived programs. TV (nzb-dl, ~80k items) is synced to the phone and searched on the device. Radio is
different: `radiko.db` on VPS2 holds ~550k program rows since 2026-05 (listing says ~500k have an nzb name). At 460k+ items the
"sync everything to the phone" approach stops working (hundreds of pages, 100+ MB parsed, memory spikes on iPhone, long first
launch). Existing server search (`radio-web /api/archive/search`) is `LIKE '%kw%'` over radiko.db: ~1 s per query, max 60 rows,
keyword only, no paging, and the app has no radio search screen at all (radio is browsed by station -> day).

## Measured facts
- nzb-dl (`:8083`, status=on): total 80,086 = tv 75,811 + uncategorized 991 + radio 157 (radio = items registered when played).
- `radiko.db` 386 MB, `radiko_programs(prog_id, station_id, title, pfm, ft, to_time, description, tracklist, usenet_nzb, ...)`.
  By month: 05 = 50k, 06 = 90k, 07 = 93k, 08 = 99k, 09 = 134k, 10 = 86k rows.
- Playable nzb exist only from 2026-07-13 (6/25 and 7/9 recently restored; recovery still moving backwards) -> the index must carry a
  per-row `playable` flag, not assume the list = playable.
- homeserver (SQLite 3.37, FTS5 trigram ok) and VPS2 (SQLite 3.45) both support FTS5.

## Method: keep the data on the server, the phone only asks
1. **Search service next to the data** (VPS2, separate small process `radio-search`, own port; read-only on `radiko.db`, own
   sidecar `search.db`). Not inside radio-web (single owner, "rough", restart risk).
2. **Index**: SQLite FTS5 over a *character-split* normalized text (NFKC, hiragana -> katakana, lowercase, a space between every
   character). A query becomes a phrase of characters, so any length works (1-2 character Japanese words too, which the trigram
   tokenizer cannot match). Columns: title, performer, description (+ tracklist optional) in one FTS table; filters (station,
   onair date, source, playable, has_nzb) in a normal table joined by rowid with indexes. Expected size ~0.5 GB, build a few
   minutes with `nice`, queries ~10-50 ms.
3. **Incremental update**: every 5 min append rows with `rowid > last` (new programs) and refresh `playable` for rows whose nzb
   became available; a nightly reconcile compares counts. Playable truth = nzb basename exists in VPS2 `usenet/nzb` / VPS1
   `nzb-from-discord` / registered in nzb-dl (cached list, refreshed hourly), with a configurable floor date as a fallback.
4. **API** `GET /search?q=&station=&source=&from=&to=&playable=1&sort=new|old&limit=50&offset=0`
   -> `{total, items:[{nzb, station, title, performer, onair, minutes, playable, thumbnail}]}`; `GET /stations?q=` for filter chips
   (counts capped). Responses are small (50 rows), cacheable on the phone.
5. **App**: "探す" screen in the Radio tab (query box, station chips, date range, "聴けるものだけ" toggle, infinite scroll). Tapping a
   row uses the existing `playArchive`. The phone keeps only the last results/recent searches (a few KB), never the full catalog.
6. **TV (nzb-dl 80k)** stays on-device for now (works, ~76-80k). If it passes ~150k, move it behind the same engine (homeserver or VPS1) with
   the same API shape; the name parser (`[reupload-N]`, `[字]` flags) would then run server side.

## Why not the alternatives
- Full sync to phone: memory/time scale linearly with items (6x now); every new field costs everyone.
- Server `LIKE`: 1 s/query and still scans everything; grows with the table.
- FTS5 trigram tokenizer: cannot match queries shorter than 3 characters (e.g. "阪神") — common in Japanese.
- Postgres/Elastic: another heavyweight service on a 2.8 GB box; SQLite file + one process is enough for ~1M rows.

## Cost / risk
- VPS2: one extra Python process (~50-100 MB RAM), ~0.5 GB disk, CPU only while syncing/querying. Read-only on radiko.db (no lock
  contention with the pipeline; WAL/readonly URI). Rollback = stop the process; nothing else changes.
- The recovery of old nzb files may restore days at a time; the playable refresh makes them appear without an app update.

## Steps
1. `server/radio-search/` (service + tests against a copy of radiko.db), deploy on VPS2 by hand first, measure.
2. App: search screen + client, ATS entry for the port is not needed (same host as radio-web).
3. Optional: expose the same index for the TV catalog later.
