# Playing past NZB recordings in MiraTV via nzb-dl

**Date**: 2026-10-19
**Status**: Design / fact sheet. Nothing implemented yet on the app side.
**Goal**: from the MiraTV iOS app, browse the Usenet archive (recordings posted as NZB) and stream any
of them, with seek, without downloading the whole file first.
**Scope**: how nzb-dl serves bytes, what the archive actually contains, what MiraTV can reuse,
and what is missing. No secrets in this file (API key and Tailscale addresses live in
`reference_vps-ssh` / `nzb-dl/internal/config/config.go`).

---

## 1. The whole mechanism in one picture

```
 Usenet (Eweka)                      VPS1 (Ubuntu, 4 cores, 3.8GB)                       iPhone
 -------------                       ------------------------------                       ------
 yEnc articles  <--NNTP (14 conns)-- nzb-dl (Go, pm2, :8083)  <--HTTP Range over Tailscale-- MiraTV
 ~716,800 B each                      |                                                     TSPipeline (ts)
                                      |  nzb-dl.sqlite                                      AVPlayer   (mp4)
                                      |   items        400k rows (tv/on = 75,812)
                                      |   nzb_index    per-file segment lists (3.0M rows)
                                      |   file_geom    exact byte layout per file
                                      |  caches: RAM 64MB LRU -> disk artcache 20GB -> NNTP
                                      v
                       GET /webdav/<cat>/<item>/<file>      (no auth, Range)
                       GET /api/stream/<itemId>?apikey=     (main file auto-picked, Range)
```

One request = `Range: bytes=a-b` on a *decoded file offset*. nzb-dl maps it to articles with integer
arithmetic, fetches them (prefetching ahead), yEnc-decodes, and writes the bytes in order. Nothing is
stored as a file on the server; the Usenet articles are the storage.

### 1.1 Why byte offsets are exact (and why that matters for a player)
- Every article states its decoded range (`=ypart begin/end`) and the file's true size (`=ybegin size`).
  Parts are a constant 716,800 bytes except the tail. nzb-dl reads part 1 and the last part once, verifies
  `size == (n-1)*partSize + tail`, and stores the result in `file_geom`.
- The old code scaled encoded NZB sizes (3% larger) across the file, which was wrong locally by hundreds
  of KB. That broke TS packet alignment. It is fixed; verified on a 19 GB TS at 60% (TS sync locked, no
  zero fill). So `Content-Length` and Range are trustworthy for **seeking**.
- Source: `dev/docs/2026-09-17-usenet-streaming-layer-redesign.md`.

### 1.2 Speed and caching (measured, VPS1 localhost)
| case | time |
|---|---|
| first touch of a place in a file (cold) | 0.3-3.3 s |
| same range again / next bytes of the same article | 0.03-0.05 s |
| same range after nzb-dl restart (disk cache) | ~0.04 s |
| sustained single stream | ~4 MB/s at prefetch 4; prefetch now 7 (14 conns / 2) |

- Broadcast TS is 15-17 Mbps (~2 MB/s); streaming-source recordings ~9 Mbps. One viewer is well inside
  the budget, but **every seek costs a cold 1-3 s**, so the player needs a buffering state on seek.
- Responses carry `ETag` and `Cache-Control: public, max-age=31536000` (not `immutable`), and honour
  `If-None-Match` (304, zero NNTP) and `If-Range`.
- Disk cache stops writing when free space < 40 GB. VPS1 root was at 89% (68 GB free) on 2026-10-19, so
  there is roughly 28 GB of headroom before the cache goes quiet.

### 1.3 Shared resources (why not to hammer it)
- Eweka account: 50 connections total, shared by every site. nzb-dl is capped at **14**
  (`NZBD_MAX_CONNECTIONS`). It is also used by highlight-generator, clip-worker and extract.
- `streamSlots = 24` process-wide (OOM protection on a 3.8 GB host; do not raise).
- `/api/conns` shows `refused_too_many`; non-zero means other sites are holding the account.
- Missing articles are zero-filled (no backup provider). A hole shows up as a glitch or a few lost
  seconds, not an error.

---

## 2. What is in the archive

Counts from `nzb-dl.sqlite` on VPS1 (2026-10-19):

| category | status on | status off |
|---|---|---|
| tv | 75,812 | 56 |
| radio | 138 | 212,795 |
| stream | 18 | 175 |
| uncategorized | 991 | 170,311 |
| posts | 3,109 | 1 |

- **Only `status=on` items are listed by WebDAV** and meant to be played. Radio is almost entirely
  `off`; MiraTV radio already has its own path (radio-web `/archive/...`), so this document is about TV.
- Item name = NZB file name: `YYYYMMDD-HHMMSS <station> <title>[字][デ]... [reupload-1].nzb`
  (examples: `20260527-173000 ＧＡＯＲＡ [生]ガオトラ！タイガース中継2026 阪神vs北海道日本ハム(5．27).nzb`).
  Station and title are full-width in many cases. The start time is in the name; **the end time and
  duration are not**.
- `[reupload-N]` items are re-posts of the same broadcast, so the list contains duplicates.
- Each item holds several files: the media file plus `.par2` volumes. `GET /api/stream/<id>` picks the
  largest non-par2/nfo/sfv file; WebDAV needs the file name from the subject (`/api/items/lookup`).

### 2.1 Container type (1% sample of tv/on, main file by size - indicative only)
| period | `.ts` | `.mp4` | `.7z` |
|---|---|---|---|
| 2023-2025 | nearly all | ~0 | few (2024-02..04 was ~25% of a tiny sample) |
| 2026-02..06 | ~95% | ~2% | ~2% |
| 2026-07..09 | ~50% | ~50% (streaming-source recordings: U-NEXT/Hulu/etc.) | 0 |

- **`.ts`**: broadcast MPEG-2 TS. MiraTV's own pipeline (`TSPipeline`) already plays these, including
  captions. Over HTTP it needs only Range.
- **`.mp4`**: AVPlayer path (same as EPGStation mp4 today). No captions/data (those need TS).
- **`.7z`**: posted before 2026-09-18 with AES encryption. **Not streamable** (ffprobe/AVPlayer cannot read
  an encrypted archive). The 2026-05-27 CBC sample I checked was a `.7z`. nzb-dl has an on-demand
  extract (`POST /api/items/<id>/extract`, one at a time, downloads the whole file, par2-repairs it);
  a password field exists in the uncommitted working tree. Treat these as "needs preparation", not
  playable. Whether MiraTV can then fetch the extracted file is **not verified**.
- Decision record: 7z encryption was retired on 2026-09-18 *because it cannot be streamed*
  (`secretary/notes/decisions/2026-09-21-7z-encryption-retired-for-streaming.md`).

---

## 3. How to reach it

| thing | value |
|---|---|
| Host | VPS1, nzb-dl on port 8083 |
| Binding | **loopback + the Tailscale address only** (not the internet). Verified with `ss`. |
| Phone requirement | Tailscale on. MiraTV already reaches homeserver this way. |
| WebDAV (`/webdav/...`) | **no authentication**; `PROPFIND`, `GET`, `HEAD`, `OPTIONS`, read-only |
| REST (`/api/...`) | key required: `?apikey=` or header `X-Api-Key`. Without it: `401 unauthorized` |
| ATS | plain http: same per-host exception route used for Mirakurun (see `2026-10-16-miratv-ats-blocks-http`) |

Endpoints useful to the app:

| endpoint | use |
|---|---|
| `GET /api/items?category=tv&status=on&limit=&offset=` | paged list: `id, name, total_bytes, created_at, enabled_at`. Sorted by `created_at` desc (upload time, **not** broadcast date). `total` = 75,812 for tv. |
| `GET /api/items/<id>` | one item |
| `GET /api/items/lookup?folder=<name without .nzb>` | item + list of file names inside |
| `GET /api/stream/<id>` | **short URL for the main file, Range supported.** Best fit for the app: no need to percent-encode a long full-width path. |
| `GET /webdav/tv/<pct-encoded item name incl .nzb>/<file>` | same bytes, key-less |
| `GET /api/usable?...` | stats 3 articles (first/middle/last): quick "is this alive" check |
| `GET /api/holes`, `/api/verify`, `/api/anchors` | missing-segment map, integrity check, byte<->time anchors (parameters: see `resolveFile` in `internal/api/handler.go`) |
| `GET /api/conns` | connection budget and cache statistics |

Not available: **search**. There is no text/date/station filter; the only lookups are exact name and
paged listing.

---

## 4. What MiraTV already has that applies

| existing piece | reuse |
|---|---|
| `TSPipeline` + `PlayerEngine` over HTTP (libavformat) | Live TV and `/raw` recordings use it. A Range-capable URL is all it needs, so an nzb-dl URL slots into `RecordedPlayerView` the same way `ChapterClient.rawURL` does. |
| Captions (`CaptionController`) | works for TS recordings, so Usenet TS gets captions for free |
| `RecordedPlayerView` seek, speed, buffering, backpressure (2 s ahead) | reuse; backpressure matters because the source is slow on cold seeks |
| AVPlayer for mp4 | same path as EPGStation mp4 |
| `engine.durationHint` | exists for when libavformat cannot report length |
| Radio archive pattern (`RadioWebClient` -> play token -> stream URL) | model for a client class |

Not reusable as-is: CM detection (`chapterd` on homeserver works from a recorded file name, not a URL) and
data broadcast for recordings.

---

## 5. Gaps, in the order they bite

1. **No catalog/search.** 75k items, paged by upload time. Without search the app cannot find "the 4/21
   Tigers game". Needs a read-only query (date range, station, text, container) returning parsed
   `{date, start, station, title, size, ext, streamable}`. Cheapest place: a small endpoint in nzb-dl
   (`items.name` is indexed; a `LIKE` over 75k rows is milliseconds). The name parser already exists in
   `g-guide-analysis/viewer/usenet_index.py` (`parse_record_name`). Alternative: a separate service on
   VPS1 so the sensitive streaming path is untouched.
2. **Duration is unknown.** The name has no end time. Options: let libavformat read PCR at the tail
   (costs one or two cold Range fetches, ~1-3 s each); or estimate `size / bitrate`, **sampling the
   bitrate at the middle of the file, not byte 0** (head sample was 5x wrong on a recording with a
   low-bitrate pre-roll; see 2026-09-21 audit, Part 6). `durationHint` can carry the estimate.
3. **Streamable flag.** `.7z` (encrypted) items must be filtered or marked, otherwise the user taps and
   gets a hang. Needs the main-file extension (from `nzb_index.subject`), not the item name, because
   `usenet_recordings.videoFileName` can say `.ts` while the NZB holds a `.7z`.
4. **Duplicates.** `[reupload-N]` copies of the same broadcast: dedupe by start time + station + title.
5. **Dead articles.** Zero-filled holes are silent. Show a "may have gaps" badge from `/api/holes` or
   `/api/usable` instead of discovering it mid-play. 5 of 7 sampled clips had at least one hole in the
   old measurement, which is why this matters.
6. **Cold-seek UX.** 1-3 s per first touch; a seek bar drag generates many Ranges. Debounce the seek
   (commit on release) and show buffering.
7. **Auth.** WebDAV is open on Tailscale, REST uses an API key that has been the hardcoded config default
   (`/api` includes DELETE on items). The app should hold the key in settings, never in the repo, and
   only call read endpoints. Consider rotating the key and setting `NZBD_API_KEY` explicitly.
8. **Network path.** Tailscale may relay (DERP) instead of going direct, which caps throughput. A TS at
   ~2 MB/s needs a healthy direct path; check with `tailscale ping` before blaming nzb-dl.

---

## 6. Proposed plan

Smallest vertical slice first, each step checked on a real item before the next (no "ran once = done"):

1. **Prove playback with a known good item** (no code): pick a 2026-03..06 `.ts` item, `curl -r 0-1048575`
   and `-r <60%>-` against `/api/stream/<id>` from the phone's network, then open the URL in VLC/the
   current `/raw` code path by hand. Pass = 206 + TS sync + moving picture. The 19 GB U-NEXT TS verified
   on 2026-09-21 is a ready candidate.
2. **Server: catalog endpoint** (section 5.1 + 5.3 + 5.4). Read-only, paged, with `streamable`.
3. **App: `NzbDlClient`** (list/search/streamURL) + settings fields (base URL, API key) +
   `UsenetBrowseView` (date -> station -> title). Reuse `RecordedPlayerView` with a URL source.
4. **App: duration + seek behaviour** (5.2, 5.6).
5. **Badges**: holes/usable, container type, captions available.
6. **Later**: encrypted `.7z` via extract queue ("prepare" button), chapter/CM detection from URL.

Verification gates (from the streaming redesign): byte-exactness against a locally extracted copy for a
sample; seek latency measured over several offsets, not one; end-to-end on the phone over cellular +
Tailscale; watch `/api/conns` (`refused_too_many`) and VPS1 `free -h` during a session.

---

## 7. Open questions for the owner

- Which content matters first: baseball broadcasts (GAORA, Sky A, KTV, ...) or everything in `tv`?
  That decides how much catalog parsing is needed.
- Is a new endpoint inside nzb-dl acceptable, or should the catalog be a separate service so the
  streaming core stays untouched?
- Encrypted pre-2026-09 `.7z` items: skip, or invest in the extract-and-serve path?
- Rotate the nzb-dl API key now (it is a repo-visible default)?

## 8. Sources
- `dev/docs/2026-09-17-usenet-streaming-layer-redesign.md` - coordinate layer, latency, budget
- `secretary/notes/troubleshooting/2026-09-21-nzbdl-streaming-origin-audit-and-anchor-backfill-deadlock.md` - cache headers, disk cache, bitrate sampling
- `secretary/notes/learnings/2026-09-16-nzb-dl-backlog-and-streaming-panic.md` - registration, prefetch pipeline
- `secretary/notes/decisions/2026-09-21-7z-encryption-retired-for-streaming.md`
- memory `project_nzb-dl-audit-2026-09-19`, `project_nzb-dl-segment-storage-design`, `reference_eweka-connection-budget`
- Live checks on VPS1 2026-10-19: `ss -ltn`, `/api/items`, `/api/items/lookup`, WebDAV `PROPFIND`, sqlite counts
- `dev/projects/miratv/docs/status-2026-10-19.md` - app state, `/raw` precedent
- Code: `nzb-dl/cmd/nzb-dl/main.go`, `internal/api/handler.go`, `internal/webdav/handler.go`, `internal/stream/serve.go`
