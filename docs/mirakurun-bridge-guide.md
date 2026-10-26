# The second Mirakurun (korean-tv-bridge) -- guide for MiraTV development

Written 2026-10-26. Everything marked **[verified]** was checked against the running bridge on 2026-10-25/26;
**[not verified]** means read from code or inferred. Keep this file current when the bridge changes.

## 1. What it is

- `http://192.0.2.10:36196/` (Tailscale) = `korean-tv-bridge`, a node server (`/home/homeserver/korean-tv-bridge/server.mjs`) on homeserver that
  **pretends to be a Mirakurun** (`/api/version` says `4.0.0-beta.16`, `/api/status` says `3.9.0`; both are static stubs).
- It is not a tuner. Each "channel" is a *virtual channel*: on every stream request the bridge spawns a per-request subprocess
  (ffmpeg or a python helper) that pulls an internet source (HLS/DASH, some with Widevine/AES) and emits **MPEG-TS on stdout**.
- Sources: TVer, NHK Plus (NHK ONE), FOD, ABEMA, U-NEXT, Hulu, DAZN, SkyPerfecTV, GIANTS TV, toratele, niconico, MLB, EasySports, ...
- EPGStation (docker `epgstation-korea`, :8890) uses it as its Mirakurun and does the recording. MiraTV uses it as a live source.
- Do not confuse with the real Mirakurun/mirakc instances (tuners at home/remote sites); MiraTV treats them as separate servers.

## 2. HTTP endpoints [verified from code routes 2026-10-26]

| Endpoint | Behavior |
|---|---|
| `GET /api/services` | all virtual services (952 on 2026-10-26: BS 480, CS 375, GR 97). Fields: `id, serviceId, networkId, name, type, logoId, hasLogoData(false), remoteControlKeyId, epgReady, epgUpdatedAt, channel{type,channel}` |
| `GET /api/services/<id>` | one service (404 for an unknown id) |
| `GET /api/services/<id>/stream` | live TS. Query string (`decode=1`, ...) is **ignored** |
| `GET /api/services/<id>/logo` | route exists; services report `hasLogoData:false` **[not verified what it returns]** |
| `GET /api/programs` | **all** programs in one array (26,122 on 2026-10-26). `networkId`/`serviceId` query filters are **ignored** |
| `GET /api/programs/<id>`, `/api/programs/<id>/stream` | one program; stream auto-stops at program end + 2 min |
| `GET /api/channels`, `/api/channels/<GR|BS|CS>/<ch>[/services|/stream]` | Mirakurun-style channel views |
| `GET /api/tuners`, `/api/status`, `/api/version`, `/api/docs` | stubs (tuners are fake devices such as `ABEMA_01`) |
| `GET /api/events/stream` | SSE **stub**: only keep-alive comments, never real events (EPGStation logs a reconnect every minute; harmless) |
| `/tver-event-pl/<hex>.m3u8` | internal, bridge-local playlist used by the rewind code (see section 6). Do not use from the app |

Program JSON: `id, eventId, serviceId, networkId, startAt (ms), duration (ms), isFree, name, description, genres[]`.

## 3. IDs -- the easy way to get it wrong

- `NETWORK_ID = 40000`. URL id of a service = `40000 * 100000 + localSid` = e.g. `4000001048` for serviceId `1048`.
  **Always use the `id` field from `/api/services`, never the bare `serviceId`** (`/api/services/1048` is a 404) **[verified]**.
- `localSid` is assigned once and persisted (`state.json`); adding channels never renumbers existing ones.
- Program id = `40000 * 100000000 + eventId * 10 + sourceIndex`. For virtual EPG, `eventId` is a stable hash of (channel vid, start)
  (`0x90000000 + FNV-1a`), so a program id stays valid across EPG refreshes unless its start time changes.
- Channel numbers: `remoteControlKeyId == serviceId`; `channel.type` is a made-up bucket (BS/CS/GR by vid prefix), `channel.channel` is synthetic.

## 4. Channel families [counts from the 2026-10-26 code, proxy types]

| Family (proxy) | n | Slot-based? | Stream source / notes |
|---|---|---|---|
| `ffmpeg` | 16 | no | direct HLS pull, `-c copy` (toratele, NHK World, ...). toratele-02/03/main start `-450` segments back (~15 min) |
| `nhkplus` | 3 | no | NHK Plus g1/e1/s1. HLS fMP4 + Widevine CENC via `nhkplus-stream.py`, CDN `simul2.hsk.st.nhk/npd4`, 960x540. **s1 (BS) is not working** (no variant id) |
| `tver` | 5 | no | TVer simul (cx/tbs/tx/ex/ntv), Streaks HLS AES-128, session issued per request, 1280x720, starts near the live edge |
| `tver-event` | 12 | **yes** | TVer special lives (sports etc.), see section 5. **Rewinds to the earliest retained segment** |
| `fod-ext` | 10 | no | FOD Live. Rewind lookback up to 3000 segments (~5 h) on the `/fod-ext/` route |
| `giantstv-live` | 3 | no | GIANTS TV. Starts at seq 0 = recording origin (about 2 h before the game) |
| `abema-event`, `unext`, `hulu-event`, `dazn`, `easysports`, `skyperfectv`, `mlb-archive` | 50/50/10/199/10/10/350 | **yes** | event slots filled by monitor scripts (cron). Widevine L3 for U-NEXT/DAZN. An unassigned slot answers 404 |
| `nicolive` | 1 | no | niconico live (NPB) |

"Slot-based" channels have a generic name (`TVer Live Event 04`); **the real title is only in the EPG** (`TVer Live 【TBS】第2戦...`).
Which event sits in which slot changes over time (an event keeps its slot until it ends).

## 5. TVer special lives (`tver-event-01..12`, serviceId 1045-1056) [verified 2026-10-24..26]

- Event list: `fod-live/tver-special-epg-monitor.py` (cron */10) polls the public `service-api.tver.jp/api/v1/callSpecialLiveTimeline`
  (no auth) and writes `fod-live/tver-special-slots.json` (12 stable slots, events up to 48 h ahead, skips >12 h always-on news lives).
- EPG: `scripts/virtual-epg-fetcher.py` (cron */10) -> `korean-tv-bridge/virtual-epg.json`; the bridge caches EPG for 5 min; EPGStation-korea
  re-reads channels/programs about every 15 min.
- Playback chain (done by `tverEventManifest()` in server.mjs): Streaks `playback.../projects/tver-splive-<ch>/medias/ref:<episode id>`
  with a public API key from `player.tver.jp/player/streaks_info_v2.json` -> `POST .../ssai/session` -> master -> best variant (720p).
  The media does not exist until about on-air time (404 earlier), so the bridge **retries for up to 90 s** before answering 502.
- Stream failure modes seen by the client: `404` slot unassigned, `502` playback never appeared / upstream error. Time to first byte can be
  tens of seconds (retry + rewind probing).
- Recording: manual EPGStation reservation (like DAZN), not an auto rule: `POST :8890/api/reserves {"programId":..,"allowEndLack":true}`.
  Results on 10/25: 駅伝 1.9 GB, 菊花賞 1.6 GB, TBS G2 4.0 GB recorded fine.

## 6. Rewind ("segment 1") -- how it works and what it means for the app

Why it exists: the TVer CDN keeps hours of numbered segments (`manifest_<v>_<seq>.ts`, AES-128, **IV = sequence number**) although the
playlist only shows the last ~6. Measured on the 10/24 TBS stream: ~6.7-7 h retained; on the 10/25 NTV stream segment 1 (stream start) was still there.

Implementation (`// BEGIN tver-rewind` block in server.mjs):
1. take the master, pick the highest-bandwidth variant, read the live window, derive the segment URL pattern;
2. binary-search the earliest segment the CDN still serves (search range 9000 segments; each probe retries 6x);
3. register a bridge-local playlist `/tver-event-pl/<id>.m3u8` = `[earliest .. live window]`, regenerated on each ffmpeg reload;
4. run ffmpeg on it with `-live_start_index 0 -http_persistent 0 -seg_max_retry 8` (old segments 404 intermittently; retries are mandatory).
Falls back to plain live (`-live_start_index -3`) on any error. Cost: ~1.2 MB per 4 s segment -> up to ~6.5 GB for a full rewind.
[verified 2026-10-26: slot 05 logged `rewind: seq 1 .. 5481 (5480 segs back) then live`, 45 s = 312 MB, h264 1280x720 + aac]

**Consequence for MiraTV (important):** `GET /api/services/<tver-event id>/stream` now starts hours in the past and flows as fast as the
client reads. A player that opens it as "live" shows old footage at 1x and will never reach the live edge by itself. For recording that is the goal;
for live viewing it is not. Options (decision pending, **not implemented**):
- A. add an opt-out query on the bridge (e.g. `?live=1` -> skip rewind) and have MiraTV use it for live tiles;
- B. keep as is and give MiraTV a "jump to live" action (seek to end while the stream is still catching up);
- C. keep live viewing on the recorded-file path (see `changes-ci65-follow-live-edge.md`: chapterd `/follow`) and use the bridge stream only for recording.
Other families: tver simul/ffmpeg start at (or ~15 min before) the live edge; giantstv-live starts ~2 h before the game; fod-ext up to ~5 h back.

## 7. Guidance for MiraTV

- Build stream URLs from `service.id`; `decode=1` is harmless but ignored. Expect HTTP 200 with a long wait, not an immediate body.
- `/api/programs` ignores filters and returns everything (~26k programs): keep the `ProgramBulk` approach (fetch once, share across services).
- For slot channels, show the **current program name** instead of the generic channel name, and hide slots with no current/upcoming program
  (they answer 404). Treat `502` as "upstream stopped / not on air yet" (open item from status-2026-10-26: add that message).
- Do not rely on `/api/events/stream` or `/api/status` for state; both are stubs.
- Timestamps in special-live streams jump at SSAI/ad boundaries (ffmpeg logs `timestamp discontinuity`); the TS stays playable but seek positions
  derived from PCR may be unreliable on those recordings **[not verified on the recorded files]**.

## 8. Operations

- Restart only via `cd /home/homeserver/korean-tv-bridge && setsid bash start.sh >> bridge.log 2>&1 </dev/null &` (from a laptop use `ssh -n -f`).
  Before restarting: `ps aux | grep ffmpeg | grep -E '36196|-ext/|manifest|streaks|tver'` must be empty (a restart kills running streams and the
  recordings built on them; EPGStation reconnects on its own and, with rewind, restarts from segment 1). Kill by PID, never `pkill -f` over ssh.
- Edits: every change is preceded by a `server.mjs.bak-<what>-<timestamp>`. Another session once overwrote the file wholesale (6/19) and dropped
  TVer/NHK Plus; a `start.sh` re-injection guard is still **not** in place.
- Related scripts: `fod-live/*-epg-monitor.py` (slot files), `scripts/virtual-epg-fetcher.py`, `fod-live/tver-special-epg-monitor.py`,
  `fod-live/nhkplus-token-refresh.py`.
- EPGStation-korea API quirks: `/api/schedules/<channelId>` needs `days`; `/api/reserves` list needs `isHalfWidth=true&limit=&offset=&type=all`
  (key `reserves`); `/api/recording` needs `isHalfWidth`.

## 9. Open items

1. `start.sh` guard for TVer / NHK Plus / DAZN / tver-event blocks.
2. NHK Plus BS (`nhkplus-s1`) variant id (capture `www.web.nhk/tv/s1` playback).
3. Decide live-view behavior for rewinding channels (section 6, A/B/C).
4. Check seekability of special-live recordings with timestamp discontinuities.
5. `tver-stream.py` (standalone) still uses the dead static-session flow; the bridge does not call it.

## 10. Where the history is

- `secretary/notes/troubleshooting/2026-10-21-bridge-tver-nhkplus-registration-lost.md` (why channels vanished, NHK CDN move, TVer session fix)
- `secretary/notes/learnings/2026-10-24-tver-special-live-har-findings.md` (special lives, HAR limits, rewind measurements)
- `dev/projects/miratv/docs/status-2026-10-26.md` (MiraTV-side status of this server)

## 11. Dynamic channel sync -- findings and proposal (2026-10-26, nothing implemented yet)

Owner's pain: channel order changes and seasonal channels (ABEMA event channels such as "30時間限界突破フェス", service 174 / ch 574) must be detected
and added/removed automatically; they recur periodically.

Findings [verified 2026-10-26]:
- The 47 ABEMA channels are **hand-written rows** in `server.mjs` (`proxy: "streamlink"`, vid `abema-<ABEMA id>`, url `https://abema.tv/now-on-air/<id>`,
  hand-assigned `priority`). Adding/removing one means editing the file and restarting.
- ABEMA publishes the authoritative list: `GET https://api.abema.io/v1/media?dateFrom=&dateTo=` (anonymous token via `abema_token()` in
  `virtual-epg-fetcher.py`) -> `channels[]` with `id, name, order, mediaStatus` (56 channels), plus `GET /v1/channels` (`playback.hls`).
  `virtual-epg-fetcher.py` already calls `/v1/media` every 10 min for EPG but ignores the channel list.
- Diff against the bridge: 2 dead rows (`30h-1` the festival, `mahjong-2`), **11 ABEMA channels missing** (disney, anime-special-3/4, isekai-anime-4/5,
  anime-live3, family-anime-3, asia-drama-4, drama-4, fishing, boatrace) and the bridge's relative order differs from ABEMA's `order`.
- Ordering key in the bridge = type bucket + `priority` + name (`channelSortKey`); ABEMA is bucketed as GR (`channelTypeFor`).

Proposal:
1. `abema-channels-sync.py` (cron */10) writes `fod-live/abema-channels.json` from `/v1/media` channels (id, name, order, status).
2. Bridge rebuilds the ABEMA part of `VIRTUAL_CHANNELS` from that JSON on a timer (no restart); new ids get a persisted `localSid`, removed ids are hidden
   from `/api/services` but keep their sid in `state.json`; order = ABEMA `order` unless overridden in `fod-live/channel-order.json`.
3. Same registry pattern for other sources whose channel set changes (FOD, DAZN, etc.).
Open risk: how EPGStation-korea reacts when a channel disappears from `/api/services` (reserves/rules/recordings on it) -- test with one disposable channel first.
Open decision: order = follow ABEMA's `order`, or keep the owner's manual order and append new channels at the end.

## 12. Top page / `/api/services` order fixed (2026-10-26)
- Symptom: `http://192.0.2.10:36196/` listed ABEMA named channels (574..) and ABEMA Event slots (709..) one by one alternately, and U-NEXT/Hulu/SkyPerfecTV
  interleaved too (133 runs of consecutive families over 952 rows). Cause: `channelSortKey` sorted virtual channels by the hand-assigned `priority` only, and the
  priority ranges of several families overlap (abema named 800-847 vs abema-event, unext 900-949 vs hulu-event 920-929 vs skyperfectv 930-939).
- Fix: `virtualFamilyRank(vid)` (new, above `channelSortKey`) ranks the family first, then priority, then name. Key = type bucket + sub + family rank + priority + name.
  Backup `server.mjs.bak-pre-familysort-<ts>`. Bridge restarted by PID 1358161 -> 1656510 with no recording running.
- Only the list order changed. `localSid` / channel number (`400 + sid`) / service ids are persisted in `state.json` and do not depend on the sort, so EPGStation
  reservations and MiraTV ids are untouched [verified: still 952 services]. The number column on the page is registration order, so it is ascending inside a family but jumps between families.
- Result [verified]: 18 runs instead of 133: ABEMA named (47) -> ABEMA Event (50) -> NHK World / NHK Plus -> TVer -> TVer Live -> FOD -> J-Sports -> toratele ->
  EasySports -> GIANTS TV -> U-NEXT -> Hulu -> SkyPerfecTV -> MLB TV -> MLB Audio -> Korean/other -> DAZN.
- Family order lives in `virtualFamilyRank` (edit the table to reorder families); unknown prefixes get rank 90.

## 13. ABEMA channel registry -- IMPLEMENTED (2026-10-26; supersedes the proposal in section 11)
- `fod-live/abema-channels-sync.py` (cron */10, log `abema-channels-sync.log`) writes `fod-live/abema-channels.json` from ABEMA `/v1/media` channels (id, name, order)
  plus `last_seen` per id. It ignores results with < 20 channels (API glitch) and writes atomically. It reuses `abema_token()` from `scripts/virtual-epg-fetcher.py`.
- Bridge (`// BEGIN abema-sync` in server.mjs, backup `server.mjs.bak-pre-abemasync-<ts>`): `syncAbemaChannels()` runs at the start of `getAllChannels()` and reloads when the file
  (or `channel-order.json`) mtime changes -- **no restart needed for channel changes**. New ids become `streamlink` rows (`abema-<id>`, `https://abema.tv/now-on-air/<id>`);
  ids missing from ABEMA for more than 30 min are hidden (`hidden: true`, skipped in `getAllChannels`) but keep their sid in `state.json` (a returning channel keeps its service id);
  priority = `10000 + ABEMA order`, so the ABEMA family follows ABEMA's own order.
- Manual order override: `fod-live/channel-order.json`, e.g. `{"abema-conan": 5}` (vid -> priority, lower = earlier inside the ABEMA family, 10000+ is the default range).
- First run [verified]: hid `abema-30h-1` (30時間限界突破フェス) and `abema-mahjong-2`; added 11 (disney, anime-special-3/4, isekai-anime-4/5, anime-live3, family-anime-3, asia-drama-4, drama-4, fishing, boatrace);
  services 952 -> 961. The two removed rows had no EPGStation recordings, reserves or rules. New rows stream fine (`fishing` via the bridge: 40 s = 38 MB, h264 1920x1080 + aac) and their EPG
  arrives automatically (virtual-epg-fetcher already emitted events for every ABEMA channelSchedule; fishing 98 programs, boatrace 13; disney has no schedule).
- Not covered: ABEMA Event slots (`abema-event-NN`, separate slot mechanism), and other families with changing channel sets (FOD, DAZN, ...) -- same registry pattern can be reused.
- Still unverified: EPGStation-korea behavior when a channel vanishes (here harmless: no data on the two removed channels).

## 14. Duplicate service ids: NHK Plus shown under "FOD Live Ch 01-03" (fixed 2026-10-26)
- Symptom (EPGStation-korea guide `:8890/#/guide`): NHK Plus programs listed under FOD 1-3. The bridge EPG itself was right (fod-live-01..03 had 0 events, nhkplus-g1/e1/s1 had 432/439/216).
- Cause: `state.json` mapped **two vids to the same sid** for three pairs: `fod-live-01/02/03` and `nhkplus-g1/e1/s1` (sids 222/223/224, i.e. ids 4000000222-224). `/api/services` therefore listed two services with the same id;
  EPGStation keys channels by id, so one overwrote the other (name "FOD Live Ch 0x" with NHK Plus programs). The pairs most likely date from re-adding NHK Plus on 10/21 with old sids still in the file (not proven).
- Which side keeps the id: EPGStation rule 13 (weekly rule) targets channel ids 4000000222-224 plus the TVer simul ids 4000000739-743 and 4000000173 -> those ids are the NHK Plus ones. No recordings/reserves existed on the duplicated ids.
- Fix: duplicate-sid guard in `getAllChannels()` (backup `server.mjs.bak-pre-sidguard-<ts>`, `state.json.bak-pre-sidguard-<ts>`): channels are processed in the deterministic sort order; if a sid is already owned, the later channel gets a fresh sid and the bridge logs `sid collision: ...`.
  Because `virtualFamilyRank` puts NHK Plus (21) before FOD (30), FOD Live Ch 01-03 moved to sids 1068/1069/1070 (ids 4000001068-1070, numbers 1468-1470); NHK Plus kept 222-224. [verified: 961 services, 0 duplicated ids]
- Side effect to remember: anything pointing at FOD Live Ch 01-03 by the old ids (4000000222-224) now points at NHK Plus. Nothing did at the time (no reserves/rules/recordings on them).
- Check for the future: `python3 -c` over `state.json` `uuid_to_sid` for sids shared by more than one key, or grep `sid collision` in `bridge.log`.

## 15. About the ABEMA `broadcastRegionPolicy` flag
`/v1/media` channels carry `broadcastRegionPolicy` (47 channels = 1, 9 = 0: abema-special, special-plus, anime-live, anime-live2, k-world, mahjong, shogi, fighting-sports, boatrace). Its exact meaning is **not documented/verified**
(an earlier note called it a region restriction -- that was a guess). From homeserver in Japan, 4 of 5 policy-0 channels played fine via streamlink (boatrace, k-world, mahjong, fighting-sports); shogi gave no data in 30 s (off air or other reason, unverified).
The registry does not use this flag.
