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

## 16. FOD channels made consecutive again; NHK Plus moved (2026-10-26)
- Owner requirement: the FOD Live channels must be consecutive. After the section 14 guard, FOD Live Ch 01-03 had been pushed to sids 1068-1070 while 04-08 sat at 225-229, and 09 / 22 were at 954 / 230.
- Original layout (numbers `400 + sid`): FOD 01-08 = sids 222-229 (numbers 622-629), then 230; NHK Plus had taken over 222-224 when it was re-added. Chosen fix: restore FOD, move NHK Plus.
- Done with the bridge stopped (no recordings): `state.json` backup `state.json.bak-pre-fodswap-<ts>`; `uuid_to_sid` and `sid_to_uuid` edited for 9 keys:
  `fod-live-01/02/03` -> 222/223/224, `fod-live-09` -> 230, `fod-live-22` -> 954, `nhkplus-g1/e1/s1` -> 1068/1069/1070 (numbers 1468-1470).
  Result [verified]: FOD Live Ch 01-09 = serviceIds 222-230 consecutive, Ch 22 = 954, NHK Plus 1068-1070, 961 services, 0 duplicated ids.
- EPGStation rule 13 (disabled: `reserveOption.enable=false`) pointed at the NHK Plus ids 4000000222-224; updated to 4000001068-1070 so it keeps meaning "NHK Plus + TVer simul + 4000000173". Original JSON saved as `fod-live/rule13-backup-<ts>.json`.
- Nothing else referenced the FOD ids (no recordings/reserves/rules). MiraTV: anything cached by the old NHK Plus ids (4000000222-224) now sees FOD, and the NHK Plus services are 4000001068-1070.
- To keep a family contiguous in the future, new channels get `next_sid` (end of the range); the family-ordered list (`virtualFamilyRank`) keeps them together in `/api/services` and on the top page, but sids/numbers stay registration-ordered.

## 17. Hulu live events without purchase (2026-10-28)
- Problem: the Hulu event slots (`hulu-event-01..10`) stayed empty. Cause: `hulu-tvod-discover.py` only sees **purchased** TVOD products (`onRental`, 0 for this account), and `hulu-linear-monitor.py` /
  `hulu-schedule-epg.py` had a hand-written `CHANNEL_MAP` of only 3 channels (巨人戦 115322, MotoGP 115119, ラグビー 217556). Free live events such as the Japan Series (`hulu.jp/livetv/285`) were never looked at.
- Source of truth: `https://www.hulu.jp/livetv` (needs the saved login cookie). Next.js flight data (`self.__next_f.push`) lists every channel as `linear_channel_meta` with `id` (channel id), `id_in_schema` (the number in `/livetv/<n>`), `rental:false`,
  and section `real_time_type` = `event` (one-off events) or `channel` (always-on: KBS WORLD+, TV5MONDE, 日テレNEWS24, BBC, CNN).
- New `fod-live/hulu-live-discover.py` (cron `8-59/10`, log `hulu-live-discover.log`): parses the hub, keeps the `event` channels, maps them to slots **04..10 stably** (a channel keeps its slot while listed; freed 6 h after it leaves the hub) in
  `hulu-live-slotmap.json`; also writes `hulu-live-channels.json`. Slots 01-03 stay fixed. If the hub parse gives < 3 channels the previous files are kept.
- `hulu-linear-monitor.py` (`load_dynamic_map()`, clears stale linear slots that are no longer mapped) and `hulu-schedule-epg.py` (`_merge_dynamic_channels()`) now include the mapped channels (backups `*.bak-pre-dynamic-<ts>`):
  playback auth + MPD/licence are resolved when an event goes on air, and the schedule (`schedule[channel_ids]` Falcor path) puts upcoming events in the EPG ahead of time.
- First run [verified]: slot 04 = BEYOOOOONDS concert (11/11 18:00), 05 = Juice=Juice tour (11/25 18:00), 06 = **日本シリーズ** (SoftBank vs DeNA, 10/28 17:53-00:00), 07 = Turkish volleyball league (10/31 21:55, 11/14 19:55); `virtual-epg.json` holds them.
- Caveat: `hulu-event-NN` channel names stay generic ("Hulu Event 06"); the title is in the EPG. Streaming of these events uses `hulu-stream.py` (seq-1 catch-up + live tail, same design as U-NEXT); **not yet exercised on a live event** -- first chance: Japan Series 10/28 17:53 JST and MotoGP 10/31 11:45.
- Gotcha for edits from a laptop: a bash heredoc through the harness collapses `\` to `\` -- write scripts with regexes using the file-write tool, not `cat <<EOF`.

## 18. Hulu purchase-required (store/TVOD) live events shown before purchase (2026-10-28)
- Owner requirement: purchase-required live events (e.g. "≠ME 特別公演 2026", 11/8 16:30) must appear in the slots/EPG even when not purchased; no "【要購入】" label wanted.
- Source: store banners `happyonapp://store/series/<id>` on `/`, `/livetv` and `/features/sports_live`. Each banner's series page `/store/series/<id>` is plain HTML with the Falcor cache inline (no Next flight chunks):
  `isTvodLive:{"$type":"atom","value":true}`, `leadEpisode` (name "... 【ライブ】11/8 (日) 16:30開演", `idInSchema` = live asset id), `edgeEpisode` (catch-up asset), and `/`-escaped slashes (decode with `unescape_js`).
  Non-live products (e.g. HiGH&LOW) are skipped (`isTvodLive` false / no start).
- `fod-live/hulu-live-discover.py` (same cron `8-59/10`) now also: upserts those events into `hulu-events.json` (same shape as `hulu-tvod-discover.py`, `_discover.source = "store-banner"`, default 3 h duration, `auto_catchup`),
  and gives each current live event of `hulu-events.json` a stable slot (kind `store`, slots 04..10 shared with the free events) in `hulu-live-slotmap.json`.
- `hulu-schedule-epg.py` writes the store events into the EPG (`hulu-virtual-epg.json`) under `hulu-event-NN`; `hulu-event-monitor.py` (`_slot_order`) resolves a store event into **its mapped slot** when it is in window
  (60 min before start) so the slot shown in the guide days ahead is the slot that gets the stream. Backups `*.bak-pre-store-<ts>`.
- Before purchase: the listing and EPG exist, but resolving (playback auth) fails -> the slot stays unresolved and the bridge answers 404 for the stream. After purchase `hulu-tvod-discover.py` / the event monitor resolve it normally and auto-create the catch-up (見逃し) slot.
- First run [verified]: slot 08 = ≠ME 特別公演 2026 (11/8 16:30-19:30 in `virtual-epg.json`). Slots now: 04 BEYOOOOONDS, 05 Juice=Juice, 06 日本シリーズ, 07 トルコバレー, 08 ≠ME.
- Caveats: the live duration is a 3 h default (the real length is unknown before the event); Hulu's own notice says "ライブ・リピート・疑似生配信中の巻き戻し・一時停止はできません" for these products, so seq-1 catch-up on a TVOD live is unproven.
- Lesson: when a script is run through a bash heredoc here, `\` is collapsed to `\`; write regex-heavy files with the file-write tool.

### 18b. `/status/channels` shows planned Hulu events (patched 2026-10-28, pending bridge restart)
- The monitor page only listed slots with a resolved playback session (`hulu-event-slots.json`), so planned events looked "(empty)". `renderSlotSection` now calls an optional `cfg.mergePlanned(slots)`; for "Hulu Event" it adds
  planned entries from `hulu-live-slotmap.json` (free events + purchase-required events) and the next upcoming EPG event of `hulu-event-NN` (also for fixed slots 01-03, skipping the "（放映なし）" placeholder). Planned cards have an amber border
  and the subtitle starts with "予定"; the header reads `N/10 assigned · M 予定`. Backup `server.mjs.bak-pre-monitorplanned-<ts>`.
- The change is in the file but **not live** until the bridge restarts (a U-NEXT tennis recording was running at 12:55 JST).

## 19. New live-schedule source candidates (research 2026-10-28)
Already covered: TVer (simul + special live), NHK Plus, FOD, ABEMA (channels + events), U-NEXT, Hulu (free events + store live), DAZN, SkyPerfecTV, GIANTS TV, toratele, J SPORTS (JOD), Rakuten TV, niconico (NPB), MLB, EasySports.
Generic recipe (proven on Hulu): one `*-live-discover.py` per source -> stable slot map (`*-slotmap.json`) -> schedule into `virtual-epg` (so the guide shows events days ahead, purchase or not) -> per-slot stream resolver when on air.

Reachability from homeserver (HTTP 200, public HTML, no login) 2026-10-28:
- ZAIKO (`zaiko.io`): top page lists live-stream events with dates, "LIVEまであとN時間", archive deadlines ("11月04日(水)まで見逃し配信"). Scrapable; viewing needs a ticket.
- ローチケ LIVE STREAMING (`l-tike.com/livestreaming/`): static HTML list (29 KB) of concerts / sports / stage with stream period and archive flag; my first date regex found no dates, needs a dedicated parser. Ticket needed.
- TELASA (`telasa.jp`, Next.js, 55 date strings), WOWOWオンデマンド (`wod.wowow.co.jp`, 1.8 MB, 11 date strings), パ・リーグ.com (95 dates; season is over until spring): schedules visible, parsers not written.
- Lemino (`lemino.docomo.ne.jp`): Next.js SPA (24 KB shell) -> schedule comes from an API that still has to be found with a HAR. Exclusive lives seen in 2026: boxing (井上尚弥 5/2 Tokyo Dome), King Gnu tour final (7/15), F1 (docomo news 2026-03-06), Premium plan 1,540 yen/month.
- Prime Video (JP): NBA on Prime (from 10/25), SPOTV channel MLB (350+ games), WNBA, 侍ジャパン; no public schedule API (official X @pvsportjp / storefront needs login).
- Netflix (JP): WWE Raw/SmackDown/NXT + premium events live from 2026-10-01 (weekly, predictable), WBC 2026 was exclusive. Schedule not in public HTML.
- SPOTV NOW (JS app, 6 KB shell; MLB postseason through 11/1), DMM TV (5 KB shell), ニコニコ生放送 (official programs; only NPB is handled today), Streaming+ (eplus: root URL 404, correct entry URL unknown).
Not tried: YouTube Live (official channels of leagues/artists; HLS without DRM -> easiest to record), Twitch / SHOWROOM / 17LIVE (no structured schedule).
Priority suggestion: Lemino (high-value exclusives) > YouTube Live (free, no DRM) > ZAIKO + ローチケ (EPG listing only, cheap) > WOWOW / TELASA > Prime Video / Netflix schedule-only EPG (DRM makes recording hard, and a subscription is required).
Open: which categories the owner wants (idols/concerts, sports, news); which of these accounts exist (Lemino, WOWOW, Prime, Netflix, DMM TV).

## 20. Overseas live-concert / fan platforms (research 2026-10-28)
Owner wants schedules of Beyond LIVE, Weverse, "HALLO LIVE" and similar overseas sites too (same recipe as section 19: discover script -> stable slots -> EPG). KST = JST (UTC+9), so no time-zone conversion.
- **Beyond LIVE** (`beyondlive.com`, Beyond Live Corporation = SM + JYP; e.g. SMTOWN LIVE FUKUOKA 2026-02-01 was on Beyond LIVE + Weverse Concerts): reachable from homeserver (200). Next.js shell, `pageProps` is empty
  (`serverSearchOptions`, `ua` only) -> the concert list is loaded client side from an API. Needs a HAR (list page + one concert page, logged in) to find it. `/ja` is 404.
- **Weverse** (`weverse.io`): SPA shell (6.5 KB, no data). Some Weverse LIVE events are geo-limited ("日本を除く" / not available in Japan seen on 2024-25 pages). Weverse Concerts = paid streams. API calls are signed -> HAR needed.
- **HALLO LIVE**: not identified. Web search found nothing, `hallolive.com` does not resolve from homeserver, `hellolive.com` is an expired Squarespace site. Need the exact URL/app name from the owner.
- Public HTML listings (schedule only, mostly ticket aggregators; reachable from homeserver, 2026-10-28): Fantopia `fantopia.io/shows/` (214 KB, 44 dates), NOL World / Interpark Global `world.nol.com/en/ticket` (544 KB, 564 dates),
  Mnet Plus `mnetplus.world/ja` (529 KB, 631 dates, has online live/VOD), LATOO `latooevent.com` (179 KB, 194 dates), Stagecrowd `stagecrowd.live` (static, JP, hosts live streams incl. WOWOW concerts; top page shows no dates).
- Questions for the owner: (1) schedule-only (EPG) or playback too (geo-block, DRM, ToS differ per site); (2) which accounts exist; (3) one shared pool of slots for all "live events" or one pool per site; (4) HAR files for Beyond LIVE and Weverse, URL for HALLO LIVE.

## 21. Lemino live schedule (2026-10-28) -- schedule only, no login
- Findings (Lemino web app, logged in via the Chrome extension; the extension hides query strings/cookies, so endpoints were found from `performance.getEntriesByType('resource')` with the query stripped, and calls were replayed from the page with top-level `await`):
  `conf.lemino.docomo.ne.jp/live/login_live/login_live_crid_list_livecms.json` (123 live content ids), `top/live_top/live_top.json` (pickup / new_arrival crid lists), `event/event_genre.json`,
  and `if.lemino.docomo.ne.jp/v1/meta/contents?crid=<a,b,...>&filter={"target_age":["G"],"avail_status":[1]}` (about 13 crids per call). **The metadata API answers 200 without any login from homeserver** (also with other filters; results identical).
- Live items expose `live_start_date`, `live_end_date`, `live_performance_start/end`, `live_delivery_type`, **`startover_flg`** (watch from the beginning), `pit_git_type: LIVE_CONTENTS`, `charge_icon`, ...
- Result on 2026-10-28: 192 crids -> 123 resolved -> only **one upcoming live**: NTTドコモ presents Lemino BOXING ダブル世界タイトルマッチ, 11/26 15:30-23:00 (startover available). The rest are past lives (archives).
  Not covered: genre rows (WOWOW, MLB on SPOTV, soccer, K-POP, tennis) that the live screen does not list -- next investigation.
- `fod-live/lemino-live-discover.py` (cron `3-59/15`, log `lemino-live-discover.log`): collects crids, resolves them, keeps current/upcoming lives (up to 90 days ahead), maps them **stably** to slots 01..10 in `lemino-event-slots.json`
  (an event keeps its slot until it ended + 6 h). Previous file is kept on failure (fewer than 20 contents resolved).
- `scripts/virtual-epg-fetcher.py`: `lemino_event_events()` -> channel_vid `lemino-event-NN`; **its `_keep()` retention window dropped events more than 4 days ahead** (Hulu had a 30-day exception) -> added `lemino-event-` to the 30-day rule
  (backups `.bak-pre-lemino-<ts>`, `.bak-pre-leminowindow-<ts>`). Verified: `virtual-epg.json` holds `lemino-event-01` 11/26 15:30-23:00.
- `server.mjs` (backup `.bak-pre-lemino-<ts>`): 10 channels `lemino-event-01..10` (proxy `lemino-event`, priority 1500-1509, type BS, family rank 44), stream branch answers **404 (schedule only; playback = Widevine + subscription, not implemented)**,
  and a "Lemino Event" card grid on `/status/channels`. **On disk only; goes live with the next bridge restart** (planned after the 18:55 JST U-NEXT recording ends, together with the Hulu planned-card change from 18b).
- Lesson: when a new virtual-EPG source shows up in the fetcher log but not in `virtual-epg.json`, check the `_keep()` retention window first.

## 22. Lemino by category: all-genre live timetable (2026-10-28, supersedes the "only 1 event" result of section 21)
- The genre screens (WOWOW `pickup-genres?genreId=2-1-123`, soccer, tennis, music, K-POP, ...) fill their "今後のライブ" rows with `GET if.lemino.docomo.ne.jp/v1/meta/contents/list` (params `filter`, `range_filter`, `sort`, `limit`, `start`),
  which returns a **`crid_list`** (not metadata); the app then resolves ids with `/v1/meta/contents?crid=..`. Both answer 200 **without login from homeserver**.
  Upcoming lives: `filter={"target_age":["G","R-12","R-15"],"pit_git_type":["LIVE_CONTENTS"],"avail_status":[1]}` (add `"genre_list.vod.id":["2.1.123."]` for one genre; **omit it for all genres**),
  `range_filter={"live_end_date":">=<ISO>|<=<ISO>"}`, `sort={"live_start_date":"asc"}`, `limit=50`, `start=1,51,...` (1-based).
- 2026-10-28: 65 upcoming live events in 29.5 days across all genres (WOWOW genre alone 57: tennis Japan-open-style daily sessions, UEFA football, ...; plus Lemino BOXING 11/26). The curated lists (section 21) only had 1.
- Events overlap (tennis courts, simultaneous matches), so `lemino-live-discover.py` now **packs them like a timetable**: each event goes to the lowest-numbered `lemino-event-NN` channel free at its time (5 min gap), and an assignment never changes.
  Greedy packing needs 16 channels for 65 events (9 for the next 7 days), so 20 channels exist. File layout: `slots` (current-or-next event per channel, for the status page), `schedule` (all events per channel, for the EPG), `assign` (crid -> channel).
- `virtual-epg-fetcher.py` `lemino_event_events()` now reads `schedule` (backup `.bak-pre-leminosched-<ts>`); `_keep()` allows 30 days ahead for `lemino-event-`. Verified: 65 Lemino events in `virtual-epg.json` (16 channels used).
- `server.mjs`: 20 channels `lemino-event-01..20` (backup `.bak-pre-lemino20-<ts>`); like the other Lemino changes it is **on disk only** until the next bridge restart (planned after the U-NEXT recording ends, 18:55 JST).
- Still schedule only: playback is not implemented (Widevine + subscription); a Lemino channel answers 404. `startover_flg` (watch from the beginning) is kept in the data and shown in the EPG description.
- Not yet covered: Lemino "Leminoチャンネル" (linear channels such as WOWOW live) if they have their own timetable API, and non-live pickup rows.

## 23. Lemino "チャンネル" check (2026-10-28): no separate linear timetable
- Genre `2.1.150.` (Leminoチャンネル; `web_config.channel_top.all_works_slider_hidden_channel_list` = `2.1.150.1/.2`) holds **on-demand comedy/live-recording content** (types `PIT` / `SERIES`, e.g. 圧倒的、僥倖ライブ, エバース×オフローズ), not linear channels with a timetable.
  `2.1.150.1` / `2.1.150.2` return no content. WOWOW on Lemino (genre `2.1.123.`) is already covered by the all-genre `LIVE_CONTENTS` query (57 of the 65 upcoming lives).
- `web_config.large_scale_live` (12 `group` crids, `sync_interval_minutes: 1`, `lp_url`) is configuration for the sync/waiting-room of big events; its crids resolve to nothing (`meta/contents` -> 0 items, `meta/member` -> empty) on 2026-10-28, i.e. no extra upcoming events hide there right now.
- Conclusion: the all-genre `LIVE_CONTENTS` list (section 22) is the complete live schedule available without login; no additional Lemino source needed. Re-check `large_scale_live` when a big event (boxing, tour final) is announced.

## 24. Beyond LIVE: skipped; Weverse findings (2026-10-28)
- **Beyond LIVE ends on 2026-12-19 00:00 KST** (notice on the site dated 2026-09-18, Gift Card sales/use also end). Owner decision: **skip**. Only two upcoming concerts were listed (EXO PLANET #6 11/07 18:00 KST, Stray Kids <RUN IT JAPAN> 11/08 16:30 KST);
  the list is in the public `GET beyondlive.com/api/main?lang=ja` (`contentsList[].contents.startDt/endDt`, no login) if it is ever needed.
- **Weverse** (`weverse.io`, tested with the Chrome extension, not logged in): the web app calls `global.apis.naver.com/weverse/wevweb/...` (`init/v1.0/state`, `home/v1.1/home`, `globalHome/v2.0/tabs/discover`, `banner/v1.0/ads/home`, ...)
  with signed query parameters (`wmsgpad` timestamp + `wmd` signature), so plain HTTP replays from homeserver do not work without reproducing the signing.
  Two different things exist: (1) free artist LIVE broadcasts per artist community (hundreds of communities, some geo-limited to non-Japan), (2) paid concert streams sold as "オンラインストリーミング利用券" at Weverse Shop (home banners on 2026-10-28: TXT <STEAL THE WIND> IN SEOUL, SHINee MINHO CONCERT <MEAN : of feral>, ...).
  Scope for schedule-only EPG still to be decided (paid concerts via Shop pages vs. a list of artists to follow).

## 25. World live-event framework (2026-10-28) -- schedule only
- Why: owner wants schedules of live streams/broadcasts from sites worldwide (concerts, sports, esports, ...). One collector with plug-in adapters instead of one script per site; shared pool of 40 channels `world-event-01..40` (proxy `world-event`, family rank 45, stream answers 404).
- Layout on homeserver: `fod-live/live-sources/world-live-discover.py` (cron `5-59/15`, log `fod-live/world-live-discover.log`) loads every `live-sources/adapters/*.py` (not starting with `_`). Adapter contract: `NAME`, `fetch(now) -> [{id, title, start, stop, desc, prio}]` (unix seconds; `id` globally unique, prefix it with the source; lower `prio` is placed first when channels run out).
- Output `fod-live/world-event-slots.json`: `slots`, `schedule` (all), `assign` (stable: an event never moves), `sources` (per adapter: ok, events, last_ok, error). A failing adapter keeps its previous events. Events that fit no channel are dropped (count in the log line).
- `scripts/virtual-epg-fetcher.py`: `world_event_events()` + 30-day `_keep()` rule (backup `.bak-pre-world-<ts>`); `server.mjs`: 40 rows, 404 branch, "World Event" card on `/status/channels` (backup `.bak-pre-world-<ts>`). Live since the bridge restart at 15:5x JST (1021 services, ids unique).
- First adapter `espn.py`: `site.api.espn.com/apis/site/v2/sports/<sport>/<league>/scoreboard?dates=YYYYMMDD` (public, no login). **A date range (`dates=a-b`) returns HTTP 400 -> one call per day.** Leagues: MLB, NBA, NHL, NFL, UEFA CL, Premier League, La Liga, UFC. End time is estimated per sport; broadcaster names go into the description. Result: 104 events on 15 channels (4-day window, ~15 s per run).
- Probed from homeserver: TheSportsDB free key 403, PandaScore 403 (needs key), Liquipedia API 403 (needs key/ToS), nugs.net 200 (238 KB HTML, not parsed yet), bigc.im 301.
- Add a site = drop one adapter file; nothing else to edit.

## 18c. Hulu live rewind test on a real event (2026-10-28 17:55 JST)
- Event: SMBC日本シリーズ2026 (linear channel 285, slot 06), started 17:53 JST. `hulu-linear-monitor.py` run by hand at 17:55 filled `hulu-event-slots.json` slot 06 (`type: linear`, MPD on `manifest.streaks.jp`); the `*/10` cron would only have caught it at 18:00 (the event monitor `hulu-event-monitor.py` does not handle linear slots: `in_window=0` is expected for them).
- Request `GET /api/services/4000000364/stream` (45 s): `hulu-stream.py` logged `rewind from event start (epoch 1793177580) = seq 1828`, `catch-up seq 1828..1850 = 23 segs = 2.3 min`; the 45 s capture holds **60 s of 1080p29.97 H.264 + AAC (6.3 Mbps, 45 MB)** = faster than real time -> **rewind from the event start works**.
- Segment numbers on a linear channel count from the channel start, so "seq 1" is not the event start; the script maps the event start time to the sequence number. Not tested: rewinding to before the event start (CDN window length unknown).
- Hulu's own UI says rewind/pause are not possible for TVOD lives, but the CDN serves older segments to the same session logic as U-NEXT/TVer.
- **Follow-up 18:04 JST (owner: "seq1から"):** `hulu-stream.py` (backup `.bak-pre-seq1-<ts>`) now rewinds **linear** slots (`slot.type == "linear"`) from seq 1 = MPD availabilityStartTime (~14:49 JST for this channel), env `HULU_FROM_SEQ1=0` restores the event-start behaviour; free/store events still start at the event start. `CATCHUP_PACE` 1.5 -> 5 (env `HULU_CATCHUP_PACE`): a 3 h backlog at 1.5x never finishes before the program end. Measured ~2 MB/s (~2.6x real time, decrypt-bound).
- Gotcha: `stream-resume.json` keeps a per-slot checkpoint (`hulu-06`) and a stale one overrides `catchup_start` -> clear the entry before restarting a recording from seq 1.
- Gotcha: a reservation created while the slot is still empty never records (EPGStation `preprec` runs at start, stream 404). Fix by deleting and re-adding the reserve (`DELETE /api/reserves/<id>`, `POST /api/reserves {"programId":..,"allowEndLack":true}`); it starts at once and the stream script rewinds. TODO: fill linear slots a few minutes BEFORE the start (cron */10 only catches it after the start).

## 26. World pool: 80 channels, Hulu pre-start gate, streamlink playback (2026-10-28 night)
- Pool raised 40 -> 80 (`SLOT_COUNT = 80` in `world-live-discover.py`; `world-event-41..80` rows in `server.mjs`; backups `.bak-pre-80-<ts>`, `.bak-pre-world80-<ts>`). 377 ESPN events fit on 48 channels, 0 dropped. Bridge restarted 22:2x JST (cut the U-NEXT / niconico recordings once; EPGStation resumed them as `(1)` files).
- `fod-live/hulu-prestart-gate.py` (cron every minute, log `hulu-prestart-gate.log`): runs `hulu-linear-monitor.py` only from 10 min before to 15 min after a `hulu-event-*` start in `virtual-epg.json`, so a linear Hulu live (e.g. Japan Series) fills its slot before an EPGStation reservation starts.
- **Playback for the world pool**: an adapter event may carry `watch_url`. `server.mjs` (`// BEGIN world-play`, `worldEventWatchUrl()`, backup `.bak-pre-worldplay-<ts>`): for `proxy: 'world-event'` the on-air event's `watch_url` switches `proxyType` to `streamlink` (the ABEMA branch: streamlink -> ffmpeg -> MPEG-TS, heartbeat, respawn); with no `watch_url` the branch still answers 404. **On disk only; goes live with the next bridge restart.**
- `adapters/streamlink_live.py`: reads `live-sources/watchlist.json` (`[{url, label}]`), asks `streamlink --json <url>` whether it is live, emits one event per live URL (`prio 3`, `start` = first seen live, rolling `stop` = now + 2 h, state in `streamlink-live-state.json`). Seeded with Twitch riotgames / esl_csgo / valorant / nba / nfl (none live at the test; a live channel was detected correctly, HLS on `playlist.ttvnw.net`).
- streamlink 8.3.0 on homeserver supports (plugins): abematv, app17 (17LIVE), ard_live/ard_mediathek, artetv, atresplayer, bbciplayer, bigo, bilibili, bfmtv, chzzk, dailymotion, dlive, douyin, drdk, huya, kick, nicolive, nrk, olympicchannel, pixiv, pluto, pluzz, radiko, raiplay, rtve, sbscokr, showroom, soop, sportschau, stadium, svtplay, tf1, tiktok, trovo, twitcasting, twitch, vidio, vimeo, wwenetwork, youtube, zattoo, zdf_mediathek and generic `hls` / `dash` / `http` (full list: `streamlink --plugins`). It does **not** do DRM: Widevine/PlayReady sites (Hulu, U-NEXT, Lemino, Fox Sports, ...) need their own scripts. Geo limits still apply (e.g. Pluto answers "not available in your location" from Japan).
- **DASH and HTTP streams through streamlink (tested 2026-10-28 night, outside the bridge):** pipeline `streamlink --stdout --ffmpeg-ffmpeg /home/homeserver/bin/ffmpeg --ffmpeg-fout mpegts <url> best | ffmpeg -i pipe:0 -c copy -f mpegts`. DASH (`dash://<mpd>`, test vector 4K H.264 + AAC) muxed video+audio into MPEG-TS fine; HTTP (`httpstream://<flv>`, local FLV) fine. **Without `--ffmpeg-ffmpeg` streamlink prints "No valid FFmpeg binary" (no ffmpeg in its PATH) and cannot mux DASH / separate-audio streams** -> `server.mjs` streamlink branch now passes both flags (backup `.bak-pre-slffmpeg-<ts>`, on disk until the next bridge restart; also applies to the ABEMA channels).
- Watchlist entries may use streamlink's prefixes, e.g. `dash://https://.../live.mpd`, `httpstream://http://.../x.flv`, `hls://...`. DRM-protected DASH still cannot be played (no key handling in streamlink).
