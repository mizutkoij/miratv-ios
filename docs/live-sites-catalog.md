# World live-event site catalog (started 2026-10-28)

Purpose: one list of sites worldwide that carry live concerts / sports / events, so the owner can pick which to support first.
Workflow decided by the owner (2026-10-28): **build the list first, then implement the wanted sites one by one** (delivery method such as HLS / DASH+DRM differs per site and has to be surveyed per site).

Framework: `fod-live/live-sources/` (see mirakurun-bridge-guide.md section 25). One adapter file per site gives the schedule; playback is a separate, per-site step.

## How to read this table
- **Schedule**: how the schedule could be fetched. `API` = public JSON seen working from homeserver; `HTML` = public page reachable, parser not written; `app` = only inside an app / login (HAR needed); `?` = not surveyed.
- **Delivery**: HLS / DASH / DRM. `?` = **not surveyed** (nothing in this file is a claim about DRM unless written as "seen").
- **Status**: `DONE` adapter live, `REACH` page reachable from homeserver (200), `TODO` not looked at, `SKIP` owner decided to skip, `BLOCKED` seen blocked (403 etc.).
- Everything marked "unverified" came from memory or one search result, not from a request.

## A. Already supported elsewhere in the bridge (own channels, not via the world pool)
TVer (simul + special lives), NHK Plus, NHK World, FOD, ABEMA, U-NEXT, Hulu JP (free + store lives), Lemino (schedule only), DAZN, SkyPerfecTV, GIANTS TV, toratele, J SPORTS, Rakuten TV, niconico (NPB), MLB.tv, EasySports.

## B. World pool (`world-event-NN`) -- sources
| Site | Region | Category | Schedule | Delivery | Status | Note |
|---|---|---|---|---|---|---|
| ESPN scoreboard JSON | US / global | sports (43 leagues) | API | n/a (schedule only; broadcaster names in text) | DONE | `dates=` must be one day per call (range = 400) |

## C. Japan
| Site | Category | Schedule | Delivery | Status | Note |
|---|---|---|---|---|---|
| ZAIKO | concerts | HTML (Inertia JSON) | ? | SKIP | owner skipped |
| ローチケ LIVE STREAMING (l-tike.com/livestreaming) | concerts/sports/stage | HTML | ? | TODO | page timed out from homeserver once (curl 000); retry |
| Streaming+ (eplus) | concerts/stage | ? | ? | TODO | entry URL unknown |
| TELASA | drama/sports/live | HTML (Next.js) | ? | REACH | parser not written |
| WOWOWオンデマンド / WOWOWライブ | concerts/sports | HTML | ? | REACH | |
| DMM TV | anime/sports | ? | ? | TODO | JS shell |
| パ・リーグ.com | NPB PL | HTML | ? | REACH | off-season |
| Prime Video JP (NBA, MLB, SPOTV) | sports | none public | ? | TODO | |
| Netflix JP (WWE, events) | events | none public | ? | TODO | |
| Abema PPV / ライブ | events | covered in A | | | |
| SHOWROOM | idol live | ? | ? | TODO | no structured schedule seen |
| 17LIVE JP | live | app | ? | TODO | |
| LINE LIVE | (closed 2025, unverified) | - | - | - | |
| YouTube Live (official channels) | all | RSS / page | ? | TODO | needs channel list from owner |
| ニコニコ生放送 | all | ? | ? | TODO | only NPB handled |
| Stagecrowd | concerts (WOWOW etc.) | HTML | ? | REACH | |
| Mildom | (closed, unverified) | - | - | - | |

## D. Korea
| Site | Category | Schedule | Delivery | Status | Note |
|---|---|---|---|---|---|
| Beyond LIVE | K-pop | app | ? | SKIP | service ends 2026-12-19 KST |
| Weverse / Weverse Concerts | K-pop | app | ? | SKIP | owner skipped |
| BIGC (BIGC ON) | K-pop | app | ? | TODO | bigc.im answers 301 from homeserver |
| Mnet Plus | K-pop | HTML (Next.js app router flight data) | ? | REACH | 520 KB page, no `__NEXT_DATA__`; parse flight data |
| Fantopia | K-pop | HTML | ? | REACH | `/shows/` 301 -> follow redirect |
| NOL World (Interpark Global) | ticketing | HTML | - | REACH | |
| SPOTV NOW | sports | ? | ? | REACH | JS shell |
| TVING | KBO / drama / live | ? | ? | TODO | |
| Coupang Play | sports | ? | ? | TODO | |
| CHZZK (Naver) | streamers / esports | API? | ? | TODO | unverified |
| SOOP (ex AfreecaTV) | streamers / esports | ? | ? | TODO | unverified |
| KBS / MBC / SBS on-air | broadcast | ? | ? | TODO | geo limits likely |
| Universe / Bubble / Fanclub | idol fan apps | app | ? | TODO | paid fan apps |
| Naver NOW | radio/live | ? | ? | TODO | |

## E. China / Taiwan / Hong Kong
| Site | Category | Schedule | Delivery | Status |
|---|---|---|---|---|
| Tencent Video / Tencent Sports | sports, concerts | ? | ? | TODO |
| Migu Video | sports | ? | ? | TODO |
| iQIYI | live | ? | ? | TODO |
| Bilibili Live | all | API? | ? | TODO |
| Huya / Douyu | esports | ? | ? | TODO |
| Douyin live | all | app | ? | TODO |
| TME Live | concerts | app | ? | TODO |
| Hami Video / friDay / LiTV (Taiwan) | sports, live | ? | ? | TODO |
| Uplive / 17LIVE (Taiwan origin) | live | app | ? | TODO |
| Now TV / HK Cable / Viu (HK) | sports | ? | ? | TODO |

## F. Southeast Asia / India / Middle East / Africa
| Site | Region | Category | Schedule | Delivery | Status |
|---|---|---|---|---|---|
| JioHotstar / JioCinema | India | sports | ? | ? | TODO |
| SonyLIV | India | sports | ? | ? | TODO |
| Sony Sports Network | India | sports | ? | ? | TODO |
| Vidio | Indonesia | sports, live | ? | ? | TODO |
| Bigo LIVE | SEA | live | app | ? | TODO |
| TrueID / AIS Play / Monomax | Thailand | sports | ? | ? | TODO |
| Astro / Sooka | Malaysia | sports | ? | ? | TODO |
| beIN SPORTS / beIN CONNECT | MENA | sports | ? | ? | TODO |
| Shahid | MENA | live | ? | ? | TODO |
| SuperSport / DStv Stream | Africa | sports | ? | ? | TODO |
| Showmax | Africa | sports | ? | ? | TODO |

## G. Europe
| Site | Category | Schedule | Delivery | Status |
|---|---|---|---|---|
| BBC iPlayer (+ Sport) | public TV | ? | ? | TODO (UK licence) |
| ITVX / Channel 4 / Sky Go / NOW | TV | ? | ? | TODO |
| TNT Sports / discovery+ UK | sports | ? | ? | TODO |
| ARD Mediathek / ZDF | public TV | ? | ? | TODO |
| Sky Deutschland / WOW / Magenta Sport | sports | ? | ? | TODO |
| France.tv / Canal+ / RMC Sport | TV, sports | ? | ? | TODO |
| RAI Play / Sky Italia / DAZN Italia | TV, sports | ? | ? | TODO |
| RTVE Play / Movistar+ / DAZN Spain | TV, sports | ? | ? | TODO |
| Viaplay / SVT Play / NRK / DR / YLE | Nordics | ? | ? | TODO |
| Eurosport / HBO Max / discovery+ EU | sports | ? | ? | TODO |
| Arte Concert | concerts | ? | ? | TODO |
| Medici.tv | classical | ? | ? | TODO |
| Berliner Philharmoniker Digital Concert Hall | classical | ? | ? | TODO |
| Stage+ / Marquee TV / On Air | performing arts | ? | ? | TODO |
| UEFA.tv, Olympics.com, F1 TV | sports | ? | ? | TODO |

## H. Americas / Oceania
| Site | Region | Category | Schedule | Delivery | Status |
|---|---|---|---|---|---|
| Peacock / Paramount+ / Max / Prime / Apple TV | US | sports, events | partly via ESPN text | ? | TODO |
| ESPN+ / Fox One / NBC | US | sports | via ESPN JSON | ? | partly DONE |
| Fubo / YouTube TV / Sling | US | TV bundles | ? | ? | TODO |
| Nugs.net | US | jam/rock concerts | HTML (`/on-demand-streams/` = 404, new URL unknown) | ? | REACH |
| Veeps (Live Nation) | US | concerts | ? | ? | TODO |
| Samsung TV Plus / Pluto TV / Tubi / Roku Channel | US/global | FAST + live events | ? | ? | TODO |
| Twitch (esports/events) | global | all | HTML 200 (directory); API needs key | ? | REACH |
| Kick | global | all | ? | ? | TODO |
| YouTube Live | global | all | RSS works (`feeds/videos.xml`) but does not show upcoming | HLS (typical, unverified) | TODO |
| TSN / Sportsnet / CBC Gem | Canada | sports | ? | ? | TODO |
| Globoplay / Vix / Fanatiz / ESPN Latam | LatAm | sports | ? | ? | TODO |
| Kayo / Stan Sport / Foxtel (Binge) | Australia | sports | ? | ? | TODO |
| Sky NZ / Sky Sport Now | NZ | sports | ? | ? | TODO |

## I. Sports leagues / federations with own OTT or open data
| Source | Schedule | Status | Note |
|---|---|---|---|
| MLB statsapi (statsapi.mlb.com) | API 200 | REACH | already covered via ESPN; useful for game-level detail |
| NHL api-web.nhle.com | API 200 | REACH | covered via ESPN |
| NBA cdn schedule JSON | 403 | BLOCKED | covered via ESPN |
| Jolpica (Ergast successor) F1 | API 200 | REACH | F1 via ESPN already |
| TheSportsDB (key 123) | API 200 but only 10 leagues | REACH | thin |
| football-data.org | 200 (needs key for data) | REACH | |
| SofaScore API | 403 | BLOCKED | |
| FotMob | 404 | BLOCKED | |
| LiveSoccerTV | 403 | BLOCKED | |
| PandaScore / Liquipedia APIs | 403 without key | BLOCKED | keys required |
| NBA League Pass, NFL Game Pass, NHL.tv, WWE, UFC Fight Pass, ONE Championship, PFL | ? | TODO | |
| Cricket: ICC, Cricbuzz, Willow | ? | TODO | ESPN cricket slug 404 |
| Rugby: Six Nations, Super Rugby, RugbyPass | ? | TODO | ESPN rugby league ids unknown |
| Tennis: ATP/WTA TV, Tennis Channel | ? | TODO | tournaments are multi-day, need per-match logic |
| Golf: PGA Tour Live, DP World Tour | ? | TODO | multi-day |
| Cycling: GCN+, Tour de France | ? | TODO | |

## J. Next steps
1. Owner marks the wanted sites (or regions / categories).
2. Per chosen site: survey (schedule endpoint, then delivery: HLS / DASH / DRM / geo-limit / login), write one adapter, test on homeserver.
3. Pool size: 40 channels are full (2026-10-28, 379 events from ESPN alone, 9 dropped); decide whether to raise it or filter leagues.

## K. Reachability probe from homeserver (Japan IP), 2026-10-28
Only the landing page was requested (HTTP 200 does NOT mean the live content is available). Geo limits are not circumvented; only what a Japan-based customer can legitimately reach is in scope.
- Redirected to a Japan/international storefront: nba.com League Pass -> `/league-pass-purchase` (purchasable internationally); nfl.com/plus -> `dazn.com/l/nfl-game-pass` (NFL international = DAZN Game Pass); paramountplus.com -> `/intl/`; pluto.tv -> `/intl/`; viaplay.com -> `/jp-en/`; bein.com -> `?c=jp`.
- Explicit unavailable / geo page: peacocktv.com (`/unavailable`), vix.com (`geo.html`), nbcsports.com/watch (geo text), kick.com and onefootball.com (geo text in page, unverified meaning).
- Reachable without redirect (service availability still unknown): skysports.com, canalplus.com, kayosports.com.au, tsn.ca, fanatiz.com, premierleague.com, dazn.com (en-GB / en-US pages), foxsports.com/live, supersport.com, hotstar.com/in, twitch.tv, youtube.com/live.
- Failed: optussport.com.au (no connection), sonyliv.com (no connection), cbssports.com/watch (406).
- Japan viewing routes found by search (unverified until checked at the source): NBA = NBA docomo (400 games, 16,500 yen/season or 2,728 yen/month) and Prime Video NBA League Pass; NFL = DAZN NFL GAME PASS; Premier League = U-NEXT soccer pack (2,600 yen/month, exclusive); Bundesliga/J.League = DAZN + free ABEMA picks; Serie A / Ligue 1 = DAZN; UEFA CL = WOWOW (+ ABEMA option).

## L. Delivery-format survey (owner's actual goal, 2026-10-28)
Owner wants to know each site's streaming format (HLS / DASH / DRM type); YouTube is out of scope. Two steps: (1) static scan, (2) real playback + network capture for sites that play without login.

### L1. Static scan (landing HTML + first 14 JS bundles, `format_scan.py`, from homeserver) -- weak evidence
A marker in a bundle only shows the code can handle it; players are usually lazy-loaded after login/play, so absence proves nothing.
- Strong markers: **Fox Sports** (HLS, DASH, Widevine, PlayReady, FairPlay, Bitmovin, CMAF/low-latency), **ABEMA** (DASH+HLS, all three DRMs, Shaka/THEO/Bitmovin), **TELASA** (HLS+DASH, 3 DRMs, Bitmovin/Shaka), **Lemino** (HLS+DASH, 3 DRMs, Shaka), **Pluto TV** (3 DRMs in code).
- Some markers: DAZN GB and Kayo (HLS+DASH, Bitmovin), Premier League (HLS, video.js), Twitch (HLS, low-latency), Niconico live (HLS), TSN (video.js/JW Player; WebRTC hits are likely noise), WOWOW Online (DASH+Widevine), Hulu JP / U-NEXT / Beyond LIVE (Widevine/PlayReady/FairPlay strings only).
- Nothing found (shell pages or blocked): Viaplay, beIN, Sky Sports, Canal+ (403), Paramount+ (406), Hotstar, Tubi, Samsung TV Plus, ESPN, Rakuten TV, ZAIKO, TVer, NHK Plus, Mnet Plus, Weverse, Bilibili, DMM TV.
- Ignore the `verimatrix/irdeto/...` column: the regex also matches ordinary words, so it is noise.

### L2. Verified in earlier work on this bridge (real captures, not scans)
| Site | Format seen | Source |
|---|---|---|
| TVer (simul) | HLS with server-side ad insertion session (POST) | this bridge, 10/21-24 |
| TVer special live | Streaks HLS, rewindable (~7 h of numbered segments, AES-128 IV = sequence) | rewind work |
| NHK Plus | CDN npd4/simul2; PSSH found in moov (CENC-protected CMAF) | this bridge |
| Hulu JP | DASH (MPD) + Widevine | `hulu-stream.py` |
| U-NEXT | Widevine, seq-1 catch-up in `unext-stream.py` | this bridge |
| Lemino | Widevine + subscription (playback not implemented) | notes in section 21 |
| GIANTS TV | AES-128 HLS | memory note |

### L3. Next: real playback capture (needs the owner's go)
For sites that play without login, open the player in Chrome, read the network log, record manifest type (m3u8 / mpd), segment container (TS / fMP4 / CMAF), DRM (none / AES-128 / Widevine / PlayReady / FairPlay), license server host, and whether rewind (DVR window) exists. Candidates that may play free from Japan: Pluto TV, Samsung TV Plus, Tubi, Twitch, ABEMA free channels, Mnet Plus free lives, ESPN free, Fox Sports free live. Nothing is logged in or paid.

## M. Measured stream formats via `streamlink --json` from homeserver (Japan IP), 2026-10-29
Script `sl_format_probe.py`; URLs were partly guessed, so a failure is not proof the site cannot work (wrong URL / site changed / geo block / offline).
| Site | Result | Format |
|---|---|---|
| ABEMA NEWS | OK | **HLS** (180p-1080p) |
| Deutsche Welle live | OK | **HLS** (270p-540p50+) |
| RTVE La 1 | OK | **HLS** (360p-720p) |
| CBS News live | OK | **HLS** (150k-540p+) |
| Twitch (earlier, a live channel) | OK | **HLS** (`playlist.ttvnw.net`) |
| SVT1 / SVT24 | manifest `svt-live-channel.akamaized.net/.../manifest.mpd?format=dashhbbtv` could not be opened | **DASH** (URL seen in the error); open failed, likely geo-limited |
| DR1 | `drlivedr1hls.akamaized.net/.../master.m3u8` 403 | **HLS** (URL seen); 403 = geo / token |
| Sportschau | VOD manifest URL on `sportschau-vod.ard-mcdn.de` failed | HLS (URL seen) |
| France 2 | `k7.ftven.fr` 422 | not usable from here |
| BBC One / Two, ZDF, NRK1, Rai 1 / Rai Sport, TF1, Stadium | "No playable streams" | geo-limited or URL not live from Japan (unverified which) |
| Euronews (406), ARTE (404), RTVE Teledeporte (404), NASA+ (404), Olympic Channel / Bloomberg (403), Reuters (401), Vidio (page changed), ARD (timeout) | failed | plugin/URL out of date or blocked |
| Pluto TV, TVP, Bilibili (top page) | no plugin for that URL | wrong URL form |
Takeaway: of 29 URLs only **4 free news/sports-adjacent channels played** from Japan; the rest were geo-blocked, outdated URLs or not live. Everything that played was HLS; SVT is DASH but blocked. No sports league or concert content was among the working ones.

## N. Chrome check of the catalog sites from Japan (2026-10-29, own tab, no login / no signup)
| Site | What the page showed | Verdict |
|---|---|---|
| Fox Sports `/live` | skeleton cards never loaded; banner "WATCH 3 DAYS FREE FOX ONE" | paid (Fox One) / likely geo; not surveyed further (no signup) |
| ESPN global `/watch/` | redirects to the global home, no player | no streaming in Japan |
| Tubi `/live` | redirected to `gdpr.tubi.tv`: "not available in your area" | geo-blocked |
| Pluto TV (earlier) | "not available in your location" | geo-blocked |
| **Mnet Plus** `/contents/ja/lives` | **loads from Japan**; live schedule is in the server HTML (date heading, "8:00PM スタート", title, performers, "追っかけ再生" chip = rewind). Listed 2026-10-29 12:00 M COUNTDOWN PLAY FESTA DAY2 (KST = JST) and 11/03 20:00 IDOL'S TABLE EP.5 | **schedule adapter written** (`adapters/mnetplus.py`, live via the world pool on the next collector run). Player format not surveyed: needs the owner's play + Premium status check |
- Player formats could not be read for these because the pages did not reach a player without login / payment. Real captures need a site where the owner is logged in and presses play.

## O. Second SSR probe of 30 candidate sites (2026-10-29, `ssr_probe.py` from homeserver; date strings found in the server HTML)
- **Only Mnet Plus gave a usable live schedule** (adapter done, section N).
- Server-rendered dates exist but are **not live-stream schedules**: Fantopia `www.fantopia.io/shows/` (24 dates; ticketed physical concerts in Asia, with date/time/city), SHOWROOM `/event` (333 dates; events/auditions), Hello Project / STARTO / AKB48 / Perfume official sites (news and tour dates). Could feed a "concert dates" list later but they are not streams.
- Empty shells or no dates in HTML (client-side or login): Stagecrowd (organiser platform, top page has no event list), WOWOW music page and WOD, TELASA (redirects through a Queue-it token), NOL World, ZAIKO, SPWN, BIGC, Weverse, Beyond LIVE, DMM TV, Rakuten TV, Prime Video JP, Spotify, YouTube Music.
- 404 / unreachable with the URL tried (URL wrong or moved, not proof the service is gone): Streaming+ (live.eplus.jp), Pia live viewing, Rakuten Ticket streaming, niconico official, ABEMA live-event, LINE CONOMI (connection error), ローチケ (read timeout twice).


## P. Country-by-country sweep, round 1 (2026-10-29, probed from homeserver, no login)

Owner direction: "go through it country by country". Method per country: public broadcaster EPG/JSON, league fixture pages, OTT landing pages. Probe scripts: `country_probe1-3.py` (scratchpad).

| Country | Site | Result | Usable for |
|---|---|---|---|
| UK | BBC Sport scores-fixtures | 200, 700 KB HTML | fixtures only (ESPN already covers PL/EFL) |
| UK | Premier League pulselive API | 200 but empty `content` for the query | needs correct compSeason id; fixtures only |
| UK | TNT Sports | 403 (WAF) | blocked |
| UK | BBC schedules JSON / sport/live | 404 | wrong URL |
| DE | Sportschau `live-und-ergebnisse[/dnYYYY-MM-DD]` | 200, server HTML, ~100 matches/day with `data-datetime` (UTC), sport/competition headings, F1 sessions, handball, DFB-Pokal | fixture schedule (all sports); a few items carry a public **audio HLS** (`data-audiolivestream_hls`, radio conference) with start/end/title |
| DE | ARD Mediathek page-gateway `/pages/ard/home` | 200 JSON, widgets are VOD teasers (no live schedule on this page); `/pages/ard/live` 404 | not a schedule |
| DE | Bundesliga.com matchday, MagentaSport | 200 HTML | fixtures / paid OTT landing |
| DE | ZDF sport live | 404 | wrong URL |
| KR | KBS static API `schedule/weekly?channel_code=11\|12\|14\|81\|N91` | 200 JSON, full per-day EPG (start/end/title/genre), no login | broadcast TV EPG, not live-event specific |
| KR | KBO schedule page | 200 HTML | fixtures |
| KR | Naver Sports API | timeout from homeserver | retry/other host |
| KR | TVING / SPOTV NOW | JS shells (0-4 KB) | need browser/HAR |
| KR | Coupang Play | "not available in your region" | geo-blocked (not circumvented) |
| TW | CPBL schedule | 200 HTML | fixtures |
| TW | MyVideo / Hami Video | 200 HTML, login prompts | needs login/HAR |
| TW | ELTA TV | connection error | unreachable |
| AU | SBS On Demand live | 200 HTML, "epg" strings in page, SSR without JSON | candidate: find the EPG endpoint in page scripts |
| AU | AFL fixture / NRL draw | 200 HTML | fixtures |
| AU | ABC iview, Kayo | 200 / empty shell | no live schedule in SSR |

Findings:
- Fixture lists (who plays when) are easy and public in every country; streams/rights info is not. ESPN adapter already covers most leagues, so national fixture sites add little unless they list *which stream carries the match*.
- Real "live stream with public manifest" so far: Sportschau radio conferences (audio HLS), plus the free news/FAST channels found in section M.
- Follow-ups: SBS live EPG endpoint, ARD live teaser (page id), Naver Sports API retry, Premier League API season id.


## Q. United Kingdom sweep (2026-10-29)

Probe scripts: `uk_probe1-3.py`. All from homeserver, no login, no VPN.

| Site | Result | Status |
|---|---|---|
| **Sky EPG** `awk.epgsky.com/hawk/linear/schedule/<YYYYMMDD>/<sid,...>` | Public JSON, 374 services, every programme has `st` (unix), `d` (sec), title, synopsis. Sports programmes are titled "Live ...". Max ~5 sids per call (more returns no `schedule` key). | **Adapter `sky_uk.py` live**: 20 sports channels (Sky Sports x13, TNT Sports 1-4, Premier Sports 1-2, MUTV, LFC TV), 7 days, 279 events, ~27 s |
| PL pulselive `broadcasting-schedule` | Geo-resolved by caller IP: returns `countryCode: JP` and "Japan - U-NEXT" only; no UK data from Japan, `countryCode` param ignored. Fixtures API needs compSeason id (2026/27 = 841). | Not used (ESPN covers PL fixtures) |
| BBC schedules (HTML) `bbc.co.uk/schedules/<service-pid>/YYYY/MM/DD` | 200, ~76 ISO datetimes per day, BBC One London = p00fzl6p; JSON variant 404 | Candidate: BBC sport programmes (iPlayer live, free in UK only) |
| BBC iPlayer guide | 200 HTML, ~50 ISO datetimes | same as above |
| BBC Sport Live Guide | "no longer available" | dead |
| Channel 4 TV guide | 200 HTML, 461 ISO datetimes | candidate (UK free TV, mostly non-sport) |
| TNT Sports (site) | 403 WAF | blocked; schedule is covered through Sky EPG instead |
| ITV / ITVX | read timeout from homeserver | retry |
| live-footballontv.com | 200 HTML | fixtures with UK broadcaster names (possible cross-check) |
| Premier Sports, DAZN GB, Radio Times, EFL, FA | shells or no schedule in SSR | skipped |

Pool after adding Sky: 658 events on 56/80 channels, 0 dropped (espn 377 + sky_uk 279 + mnetplus 2).
Delivery format: UK pay-TV is DRM-protected (Sky Go / TNT via Discovery+): schedule only. iPlayer is HLS/DASH but UK-IP-restricted (not circumvented).

### Q.2 UK playability (2026-10-29)

Goal: make as much of the UK pool playable as is legitimately possible from Japan (no VPN, no new subscription, no DRM bypass).

| Source | From Japan | Result |
|---|---|---|
| talkSPORT Global `https://radio.talksport.com/stream` (301 -> `talksport.live.stream.broadcasting.news/stream`) | reachable | AAC 64 kb/s mono Icecast; **plays** via `httpstream://` + streamlink + ffmpeg mpegts |
| BBC World Service `stream.live.vc.bbcmedia.co.uk/bbc_world_service` | reachable | audio/mpeg 200 (not yet wired) |
| LBC `ice-the.musicradio.com/LBCUKMP3Low` | reachable | audio/mpeg 200 (not yet wired) |
| BBC Radio 5 Live / Sports Extra (same host, Akamai HLS) | 302 to bbc.co.uk / 410 | UK-only, not circumvented |
| BBC iPlayer, ITVX, Channel 4 | no playable streams | UK IP only, not circumvented |
| Sky Sports / TNT Sports / Premier Sports | DRM + subscription | schedule only |

Implemented: `sky_uk.py` adds talkSPORT (Sky EPG sid 2902, next 3 days, ~19 programmes incl. live Carabao Cup commentary) with `watch_url=httpstream://https://talksport.live.stream.broadcasting.news/stream`, prio 20.
Verified end to end: collector -> `world-event-27` active slot -> `GET /api/services/4000001118/stream` returned 32 s of AAC audio (TS, audio only). Pool: 677 events on 56/80 channels, 0 dropped.
Caveats: audio only; the Global feed can differ from the UK feed during rights-restricted programmes; EPGStation recording of an audio-only world-event slot not yet tested.

### Q.3 Playable-only set and connection check (2026-10-29)

Owner: only keep what plays on the current connection. Added `uk_radio.py` (BBC World Service, LBC; one 24 h event per JST day, `watch_url` httpstream). Bridge test (homeserver, JP): World Event 49 = mp3 24 kHz stereo, World Event 50 = mp3 44.1 kHz mono, ~30 s each OK; World Event 27 = talkSPORT AAC OK. Pool: 681 events on 56/80, 0 dropped.
Same three URLs also return 200 audio/* directly from the owner's PC (its public IP geolocates to NL via ipinfo, not JP), while BBC 5 Live still redirects to bbc.co.uk. Note: the bridge plays through homeserver's own connection, not the PC's.

### Q.4 UK sites checked in Chrome on the owner's PC (2026-10-29)

No login, no play button pressed, no cookie banner accepted. Tab: own new tab, closed afterwards.

| Site | What the page showed | Verdict |
|---|---|---|
| **Sky News** `news.sky.com/watch-live` | Free Brightcove player, LIVE badge, `<video>` playing (blob/MSE). HLS master `linear901-oo-hls0-prd-gtm.delivery.skycdp.com/v1/master/<id>/prod-gb-lin-skynews-hls-25-web/master.m3u8` (separate audio group `stream08`), no token: 200 from the PC and from homeserver | **Playable.** Added to `uk_radio.py` (24 h event, `hls://` watch_url); bridge test World Event 51: H.264 1920x1080 25 fps + AAC 48 kHz stereo |
| BBC iPlayer live (BBC One) | "Sign in to your BBC account" gate, no `<video>` | login (and UK-only): not done |
| Channel 4 `channel4.com/now/C4` | Player with Restart / Watch live; guide text static | needs a play press by the owner; geo status unknown |
| GB News `gbnews.com/watch/live` | consent wall ("Pay to reject" / "Accept"), no `<video>` | blocked by consent; not clicked |
| ITVX `itv.com/watch/itv` | "page doesn't exist" | wrong URL, retry with the real live path |

Pool: 683 events on 56/80 channels, 0 dropped (uk_radio now 6 = BBC World Service, LBC, Sky News x 2 days).
Caveat: the Sky master URL embeds an id hash (`6404a5d7...`); if it rotates, re-read it from the player's network log (Brightcove `edge.api.brightcove.com/playback/v1/accounts/6058004172001/videos/ref:...`).

### Q.5 Channel 4 live, owner logged in and pressed play (2026-10-29)

Owner logged in (no credentials handled by Claude). Live E4 ("The Simpsons") played in the owner's Chrome. Network, read as host + file type only:
- Manifest: **DASH (.mpd)** from `csm-e-c4ukdash-eb.tls1.yospace.com` (Yospace server-side ad insertion), 2 requests.
- Media segments from `cdn.dai.iso.dash.prod.c4assets.com`.
- `video.mediaKeys` is set => **EME/DRM is active** (Widevine most likely), 1024x576.
Verdict: format = DASH + DRM + SSAI. Not playable through streamlink/ffmpeg without a licence; keys only via the owner's own CDM, so **not wired into the pool** (schedule can come from the Channel 4 TV guide HTML if wanted).
Method note: `javascript_tool` returns `[BLOCKED: Cookie/query string data]` when the output contains URLs with query strings; return host + last path segment only.

### Q.6 Channel 4 family: schedule imported, recording feasibility (2026-10-29)

Six channels in the guide: Channel 4 (C4), E4, More4 (M4), 4seven (4S), Film4 (F4), **4Music (4M)** (not "E4 Extra"; the live switcher shows only 5).
Adapter `channel4_uk.py` (HTML guide `/tv-guide[/YYYY-MM-DD]`, 3 days, end = next start): 349 events (E4 89, C4 75, More4 60, 4seven 56, 4Music 52, Film4 17), prio 50, schedule only. Pool: 1031 events on 61/80 channels, 0 dropped (channel4_uk 349, espn 377, sky_uk 299, mnetplus 2, uk_radio 6).

Recording attempt (stopped, reasons):
- Player manifest (Chrome network log): `csm-e-cec4prdlgblonlived-<n>.bln1.yospace.com/csm/extlive/channelfour01,e4-v3-iso-dash/1.mpd;jsessionid=...?yo.ac=true&...&targetedAdvertising=accepted`.
- From homeserver (JP) the host answers, but without the player's session: `400 Media playlist or segment requested but no current session` (same with the query params). The session is created by a Channel 4 call made after login; not reproducible here without the owner's session.
- Media is DASH + EME (Widevine most likely). No licence request visible in the log (tab had just reloaded). har2key (U-NEXT/Hulu, own CDM) has no Channel 4 flow.
- The owner's PC public IP resolves to NL: whether Channel 4 plays there by entitlement or via a VPN is unknown; recording from Japan would then be a geo question. No VPN/geo workaround is built.
Open decision for the owner: whether to build a Channel 4 flow in har2key (HAR of one live playback incl. licence call, own CDM, rotating live keys).

### Q.7 Channel 4 HAR #1 analysis (2026-10-29, owner file `Downloads/download`, read locally, structure only)

13 entries (captured after playback had already started): player CSS, Yospace `/csm/sdk` x2, MPD x2 (dynamic, `timeShiftBufferDepth=PT60S`, `minimumUpdatePeriod=PT4S`, AST 2026-10-21 so a continuous live), segments from `olsp.live.dash.c4assets.com` (.m4v/.m4a/.vtt), Conviva POST.
MPD ContentProtection: cenc + **PlayReady (9a04f079)** + **Widevine (edef8ba9, PSSH 193 chars)** + Marlin; default KID ends `...65340a`. No licence URL in the MPD (it is inside the PSSH data).
**Missing: the Widevine licence POST** (and any auth header/token it needs) => har2key cannot auto-detect the licence URL. Cause: licence acquisition happens at player start; DevTools was opened after that.
Next: recapture with DevTools open first, Preserve log + Disable cache, then load `/now/E4` fresh, play ~30 s, save HAR with content.

### Q.8 Channel 4 live (E4): har2key result and why EPG recording is blocked (2026-10-29)

HAR #2 (owner re-captured, 129 entries) contains the full player flow. Findings:
- **har2key now supports Red Bee JSON-wrapped Widevine** (`har2key.py`, backup on homeserver `har2key.py.bak-pre-redbee-20261028-174016`): POST `c4.eme.lp.aws.redbeemedia.com/wvlicenceproxy-service/widevine/acquire` with `{token, video, message=b64(challenge)}`, certificate first (`message="CAQ="`), response `{license=b64}`. Other services keep the old path (`wrap=None`). Result: one content key for E4 live, KID `0000000000000000000000000065340a` (key value not recorded here).
- Player flow: `GET www.channel4.com/simulcast/channels/E4` -> `videoProfiles` (direct CDN `olsp.live.dash.c4assets.com/dash_iso_sp_tl/live/channel(e4)/manifest_sd.mpd` and Yospace DAI `csm-e-c4ukdash-eb.tls1.yospace.com/csm/extlive/channelfour01,e4-v3-iso-dash.mpd`), each with a 216-char token -> Yospace 302 to a session host -> MPD (dynamic, 60 s buffer) -> licence POST (token + video from the same API) -> segments. No login cookie is needed.
- **The simulcast API is geo-restricted**: from the owner's PC (public IP NL) 200 with data; from homeserver (JP) `403 {"error":{"code":403,"message":"Failed to fetch data"}}` even with browser-like headers. Once a session URL/token exists, homeserver can reach the Yospace session MPD, CDN segments and the licence server (tested), so the block is at token issuance only.
- Consequence: an EPG-scheduled recording on homeserver would have to obtain tokens from a non-JP address (relay from the PC/VPN). That is geo-block circumvention, **not built**. Allowed today: manual har2key from a HAR captured on the owner's own connection, command run on that PC (N_m3u8DL-RE).
- Note: the first successful licence call from homeserver used a token minted on the PC (one manual run); no automation of that was added.
- Cleanup: HAR copy and probe scripts removed from homeserver /tmp.

### Q.9 Decision on Channel 4 recording (2026-10-29)

Owner: recording Channel 4 = fetch the tokens yourself when you want a recording (manual); no automated relay from a non-JP address (geo-restricted token issuance stays out of scope).
Manual recipe: own connection -> open `/now/<CH>` with DevTools (Network, Preserve log, Disable cache) -> save HAR with content -> `har2key.py <har>` (Red Bee wrapper, own CDM) -> run the printed N_m3u8DL-RE command promptly (live MPD keeps 60 s; session URL was still alive after 8 min; token lifetime unknown, opaque).
Open: measure token/session lifetime (right after / 30 min / 2 h) to know whether a pre-fetched bundle can serve a scheduled recording.

### Q.10 Channel 4 family recording built (2026-10-29), activates at the next bridge restart

Owner request: a place to register + all channels recordable. Decision Q.9 stands: tokens are minted manually on the owner's own connection (no relay from another country).

Design (why): Red Bee licence token expires in minutes (HAR 17:36Z ok at ~17:40, "token has already expired" ~20 min later) but the content key of a channel is static (E4 KID ...65340a), so the key is fetched once at registration and stored; recording never calls the licence server. The Yospace session MPD stayed alive for 15+ min in tests (real lifetime unknown); the CDN segments need no token.
- `fod-live/c4-register.py <har>`: for each channel clicked in the HAR (order-based mapping: simulcast call -> session MPD -> Red Bee request) get PSSH from the MPD, key via `har2key` functions (own CDM, Red Bee wrapper), write `fod-live/c4-bundles.json` (0600; {CH: mpd_url, kid, key, saved_at}). Prints no secrets.
- `fod-live/c4-stream.py <C4|E4|M4|F4|4S|4M>`: poll dynamic MPD -> best video + audio `$Time$` segments -> mp4decrypt -> fifo -> ffmpeg -c copy -> MPEG-TS stdout (same shape as hulu-stream.py). Exit 2 = no bundle / session dead. Tested on homeserver with the HAR session + stored key: 36 s, H.264 1024x576 25 fps + AAC 48 kHz stereo, 0 decode errors. ffmpeg's own dash demuxer was unusable here (opens every rendition, 256x144, no audio; its option is `-cenc_decryption_key`).
- Bridge (`server.mjs`, backup `.bak-pre-c4-20261028-175724`): fixed channels `c4-c4 / c4-e4 / c4-m4 / c4-f4 / c4-4s / c4-4m` (proxy `c4`, family rank 46, type BS), stream branch -> c4-stream.py, `GET /c4` upload page, `POST /c4` (HAR -> c4-register.py, 80 MB cap), `GET /c4/status`.
- EPG: `live-sources/c4-epg-fetch.py` (cron 7,37 * * * *) writes `c4-epg.json` (6 channels, 3 days: C4 75, E4 89, More4 59, Film4 17, 4seven 56, 4Music 52) from `live-sources/channel4_guide.py` (the former world-pool adapter, moved out so the programmes are not duplicated); `virtual-epg-fetcher.py` `c4_events()` (backup `.bak-pre-c4-...`).
- har2key: Red Bee wrapper (Q.8).
Not yet verified (needs the bridge restart; deferred because a niconico recording was running at 17:57Z): playback through `/api/services/<id>/stream`, upload page, EPGStation seeing the six channels. Unknowns: behaviour across an ad break (SSAI Period/rendition change is logged but not re-initialised), session lifetime, key rotation.
Test bundle: E4 only, written by the register test with the key obtained earlier from the owner's HAR (file mode 0600 on homeserver).

### Q.11 Channel 4 recording: bridge restart and verification (2026-10-29)

Owner OK'd the restart (interrupting the niconico recording). Bridge restarted by PID (3303634 -> 3410045, `setsid bash start.sh`).
Verified: `/c4` 200, `/c4/status` lists the six channels, Mirakurun services `Channel 4 / E4 / More4 / Film4 / 4seven / 4Music` = 4000001172..77, EPGStation channels list shows them (BS). `GET /api/services/4000001173/stream` (E4): 30-40 s, H.264 1024x576 25 fps + AAC 48 kHz stereo; decode check 1 error at stream start (mid-GOP), 0 when run directly.
Bug found and fixed: the test registration stored a 31-hex KID (typo in the test default), mp4decrypt then decrypted only partly (thousands of AAC/H.264 errors). Fix: bundle KID padded to 32 hex, and `c4-stream.py` now refuses a bundle whose kid/key is not 32 hex (exit 2). Real registrations take the KID from the licence result, so they are unaffected.
Lesson: always run a full-file decode (`ffmpeg -i x.ts -f null -`) and count errors; a stream header that looks right is not proof of correct decryption.
Pending: EPG programmes in EPGStation (arrive at the :14/:29/:44/:59 refresh); registering all six channels from one HAR (only E4 tested); behaviour over an ad break.

### Q.12 Channel 4 registration added to the HAR upload page (2026-10-29)

Owner: make HAR registration reachable from `http://192.0.2.10:36199/` (the existing "HAR 認証アップロード" page, `fod-live/har-upload-server.py`, started by hand with `--daemon`, no cron/systemd).
Change (backup `har-upload-server.py.bak-pre-c4-<ts>`): service `channel4` card with a link to `channel4.com/now/C4`, per-channel chips (6 channels registered / minutes ago, from `c4-bundles.json`), the DevTools how-to, and an upload path that runs `c4-register.py` instead of `har-auto-auth.py` and **deletes the HAR afterwards** (it carries session cookies). Response JSON lists registered channels and per-channel errors; no keys/tokens/URLs.
Server restarted (PID 3704 -> 3413739). Verified: card renders, `/status` has `channel4`, an empty HAR returns `ok:false` with the file removed.
The bridge's own `/c4` page (:36196) stays as a second entry point.
Note: this upload server does not survive a homeserver reboot (no autostart); same as before this change.

### Q.13 ITVX live (ITV1), owner signed in and played, own connection (2026-10-29)

Page `itv.com/watch?channel=itv` plays (ITV1 live, sponsor ad first), `video` 1280x720, `mediaKeys` set (EME/DRM). Network by host and file type only:
- Manifest: **DASH** `.mpd` from `dar-live-red-irdeto-ms.akamai.content.itv.com` (Akamai).
- Licence: **Irdeto** `itvpnp.live.ott.irdeto.com` (2 requests) => Widevine via Irdeto, not Red Bee.
- Other media from `app.10ft.itv.com` (2).
From homeserver (JP): `itv.com` itself times out (000, also in the earlier UK probe), the Akamai MPD host answers 403 and the Irdeto host 429 at their roots (no path/token). The front door (page/API) is not reachable from Japan, so the same geo wall as Channel 4 applies and a new har2key flow for Irdeto would be needed.
Verdict: DASH + Widevine (Irdeto); not built. Free, with sign-in; manual route only (HAR from the owner's own connection + har2key adapter), if ever wanted.
Remaining UK free players not yet checked: My5 (Channel 5), STV Player, BBC iPlayer (BBC account), GB News (consent wall).

### Q.14 ITVX (ITV1) HAR analysis and recording feasibility (2026-10-29)

HAR `www.itv.com_Archive [26-10-29 03-27-11].har` (Firefox, 63 entries, owner's own connection, ITV1 live). Read locally; values not recorded.
- Flow: Yospace DAI again (`csm-e-itv-eb.play.dar.itv.com/csm/extlive/itv01,itv1-dotcom-dash-proda-multicdn.mpd?...` 302 -> session host `csm-e-ceitvlgblonlived-<n>.play.dar.itv.com/.../1.mpd`, jsessionid in path, Akamai bot-manager cookies `_abck`/`bm_sz`). MPD dynamic, TSB 1 min, minimumUpdatePeriod 6 s, 1 Period; segments `cenc-<rep>-<time>.dash` under `dar-live-red-irdeto-ms.akamai.content.itv.com/jwt/<JWT>/playout/common/itv1/cenc.isml/dash/`.
- Licence: Irdeto `itvpnp.live.ott.irdeto.com/Widevine/getlicense?CrmId&AccountId&ContentId`, raw octet-stream challenge (2 POSTs: certificate + licence). **har2key's generic path works unchanged**: 1 key for ITV1 (KID `01d26cd6fd074edfa0e51bc19c92f093`; key value not recorded). No ITV adapter needed.
- **Segment JWT is bound to the client IP**: claims `exp, ip, mip, path, sid, steer, sub` (`ip` = the owner's PC exit address). From homeserver: session MPD `200`, but every segment `403` (with or without cookies). So homeserver cannot record ITVX; only the machine whose IP minted the JWT can. Making homeserver fetch through the owner's IP would be a relay/geo workaround: not built.
- Result: ITVX cannot be an EPG-scheduled bridge channel. Manual route only: HAR on the PC -> `har2key` (homeserver, `/har2key` page) -> the printed N_m3u8DL-RE command run on the PC. PC has N_m3u8DL-RE, ffmpeg and mp4decrypt (OneDrive `DL/PD101関連/PD101jptiktok`).
- Contrast with Channel 4: segments there carry no token/IP binding, so homeserver records them (Q.10).
Open: JWT `exp` vs `iat` lifetime unknown (only `exp` present); My5 / STV not checked.

### Q.14b Correction to Q.14 after a proper retest (2026-10-29)

Owner: "that was insufficient research". Q.14 blamed an IP-bound JWT, tested with the stale URLs saved in the HAR. Retest from homeserver with a **freshly fetched** session MPD:
- Fresh session MPD: 200; fresh segment JWT: claims `exp, ip, mip, path, sid, steer, sub`, **valid ~5.9 h** (exp in 21404 s), `ip` claim = the owner's PC address (minted at session creation).
- Init and newest segment from homeserver, with or without browser headers: **403 `{"error":"geoblock","IP":"<homeserver ip>"}`** => the Akamai CDN geoblocks by the requester's location (Japan). The 403 is a geoblock, not proof of IP binding (whether the `ip` claim is also enforced stays untested, and cannot be tested from a Japan IP).
- Lesson: never judge a token from stale URLs in a HAR; re-fetch the manifest and read the error body before naming a cause.
Conclusion unchanged in effect: homeserver cannot record ITVX (CDN geoblock for JP); the owner's PC can. New fact: one token lasts ~6 h, so a single registration could serve several recordings on the PC within that window.

### Q.15 Where the geo restriction sits, hop by hop (2026-10-29, requests from homeserver, JP IP 150.249.66.100)

| Hop | ITVX (ITV1) | Channel 4 (E4) |
|---|---|---|
| 1. Front door / token issuance (page + playlist/simulcast API) | `itv.com` ReadTimeout (page and /watch) | `/simulcast/channels/E4` 403 "Failed to fetch data" (other channel4.com endpoints answer 200) |
| 2. Yospace session | open: a new session request 302 -> session MPD 200; the JWT's `ip` claim is still the owner's address (it is baked into the request parameters issued by ITV's API, not derived from the requester) | open: session MPD 200 |
| 3. DRM licence | open: Irdeto accepted the replayed request (key obtained from homeserver) | open: Red Bee accepted (key obtained from homeserver) |
| 4. CDN segments | **403 `{"error":"geoblock","IP":"<homeserver ip>"}`** (Akamai, by requester location) | open: 200, no token |

=> ITVX: blocked at hop 1 (issuance) and hop 4 (CDN). Channel 4: blocked only at hop 1; so a registered token bundle lets homeserver record it. Yospace and the licence servers are not geo-restricted for either.

## Q.16 UK football schedule (2026-10-29)
- STV: HLS masters are clear, but segments are AES-128 and the key host (stv-*.akamaized.net) returns 403 from Japan -> not recordable from homeserver. My5: geo-restriction page. Premier Sports/LaLiga TV on STV: 403.
- UK football in the pool: Sky Sports/TNT/Premier Sports "Live" events (sky_uk, schedule only); talkSPORT commentary is the only playable one (watch_url).
- New adapter `adapters/uk_free_football.py` (homeserver `/home/homeserver/fod-live/live-sources/adapters/`): BBC/ITV/Channel 4/5/S4C football programmes from the public Sky EPG (sids in file), keyword filter, 7 days, prio 30, schedule only. First run: 13 events (Match of the Day, EFL Highlights, UEFA Women's CL etc.). Removed keyword "cymru" (matched Welsh non-football shows).
- Owner asked for schedule only (no PC-side recorder, no relay). Geo-block circumvention remains out of scope.

## Q.17 Spain round 1 (2026-10-29, started from the owner's PC as asked, NL IP 91.148.244.236)
- PC side: RTVE Play pages open and the player starts in Chrome (pre-roll ad seen); manifests are DASH (`la1_main_dvr_drm.mpd`, `ztnr/1688877.mpd`), but a re-fetch from the page returns HTTP 451 (so DRM type not confirmed from the PC). Mitele/Telecinco: DRM. yt-dlp: RTVE La 1/2, Atresplayer, 3Cat unsupported; YouTube lives hit bot check. 3Cat guessed HLS URLs 403/404.
- homeserver (Japan IP), streamlink `rtve` plugin (page URL `https://www.rtve.es/play/videos/directo/<ch>/`; channels: la-1, la-2, canales-lineales/24h|tdp|clan; "canal-clasico"/"star" have no stream):
  - 24h: clear HLS 720p H.264+AAC, 0 decode errors (also through the bridge) -> added.
  - La 1 / La 2 / Teledeporte (tdp): HLS with FairPlay SAMPLE-AES (`skd://`, KEYFORMAT com.apple.streamingkeydelivery) -> not recordable (only own Widevine CDM is allowed).
  - Clan: clear HLS manifest, but segments return 403 "Geoblock" from Japan -> not usable.
- New adapter `adapters/es_live.py` (RTVE 24 Horas, 24h event per JST day, watch_url = page URL). Pool slot World Event 20 (service 4000001111) verified: 720p H.264+AAC, 0 errors.
- Not done yet: Spanish programme guide (RTVE API), Atresplayer/Mitele (DRM likely), 3Cat/Telemadrid/EITB/Canal Sur, Spanish radio (Cadena SER / LOS40 answered 206 from the PC; not decode-tested), LaLiga schedule.

## Q.18 Spain round 2 (2026-10-29)
- Owner not interested in Spanish radio (skip Cadena SER / LOS40).
- LaLiga / Copa del Rey schedule already in the pool via the ESPN adapter (`soccer/esp.1`, `soccer/esp.copa_del_rey`): 47 events at the time, schedule only.
- Static HTML scan from the owner's PC (NL IP) of 3Cat (TV3), Telemadrid, EITB, Canal Sur, A Punt, Atresplayer, Mitele, DAZN ES, LaLiga, Movistar+: no m3u8/mpd in the page source for any (JS players; some pages 404 = wrong URL). Real playback capture in Chrome needed (owner presses play), same method as the UK round.

## Q.19 Spain round 3: 3Cat (2026-10-29)
- Owner played TV3/Esport3 in Chrome on the PC (works there; the page's geo.json answered "ESPANYA"). HAR `www.3cat.cat_Archive [26-10-29 13-57-35].har`: Esport3 plain HLS on `directes-tv-es.3catdirectes.cat/live-origin/esport3-hls/`, TS segments `geo-br*_*.ts`, no DRM.
- Public API `api-media.3cat.cat/pvideo/media.jsp?media=video&versio=vast&idint=<id>&profile=pc_3cat` lists every stream host per channel (same answer from the PC and from homeserver): esport3 (cat/es hosts), tv3 (cat/es/int), 324 (int only), super3 (cat/es), tvi (int).
- From homeserver (Japan): the Spain-region hosts return 403 "no disponible a la seva regió" (TV3 Spain feed, Esport3, Super3) -> not used (no relay). The `-int` hosts are open: `directes3-tv-int.../tvi-hls/master.m3u8` (TV3CAT Internacional, 1080p H.264+AAC) and `directes-tv-int.../canal324-hls/master.m3u8` (324 news).
- Added both to `adapters/es_live.py` (hls:// watch_url). Bridge-verified: TV3CAT Internacional = World Event 21 (service 4000001112), 1080p H.264+AAC, 0 decode errors. Audio is a separate HLS group, muxed by the bridge's streamlink+ffmpeg path.
- HAR does not help Esport3 on homeserver: the block is by IP at the CDN, not by token.

## Q.20 France round 1 (2026-10-29, PC first, then homeserver)
- From the PC (yt-dlp): France 2/3/4/5 + franceinfo (ftven tokenised URLs) and BFM TV resolve; M6 and TV5Monde are DRM / Access Denied; CNews/L'Equipe Cloudflare 403; YouTube lives hit the bot check.
- From homeserver (Japan): franceinfo OK (streamlink `pluzz`, up to 1080p). France 2/3/4/5: `k7.ftven.fr` 422 (not usable). BFM TV: no stream. Arte: player API (`api.arte.tv/api/player/v2/config/<lang>/LIVE`) answers 200 but `streams: []` with `geoblocking DE_FR` -> no.
- France 24: the old `static.france24.com/live/*/live_web.m3u8` masters point to a dead akamaihd host (400). New masters `live.france24.com/hls/live/2037179-b/F24_FR_HI_HLS/master_5000.m3u8` (FR) and `.../2037218-b/F24_EN_HI_HLS/...` (EN) are open from Japan: 1080p H.264+AAC (ES 404, AR 403).
- Adapter `adapters/fr_live.py` (24h event per JST day): France 24 FR = World Event 23 (4000001114), France 24 EN = 24 (4000001115), franceinfo = 28 (4000001119). Bridge-verified, 1080p H.264+AAC, 0 decode errors each.
- Not done: French programme guide, Ligue 1 / Rugby schedule, RMC Sport / Canal+ / beIN (paid), LCI / TF1+ (DRM likely).

## Q.21 Per-broadcaster fixed channels instead of the World pool (2026-10-29)
Owner: "world じゃなくて各放送局の番組表ほしい" -> each broadcaster gets its own channel with its own programme guide (like the Channel 4 family), not a 24h event in a World Event slot.
- Station list: `/home/homeserver/fod-live/stations.json` (id, name, country, url, epg). Bridge loads it at start (`// BEGIN stations` block after VIRTUAL_CHANNELS, vid `st-<id>`, proxy `streamlink`, priority 1800+i, family rank 47, type BS). Adding a station = edit JSON + bridge restart.
- Guides: `/home/homeserver/fod-live/stations-epg-fetch.py` (cron `3,33 * * * *`, log stations-epg.log) -> `stations-epg.json` -> `virtual-epg-fetcher.py` `station_events()`. Types: `sky` (public Sky EPG JSON by sid) and `placeholder` (24h event per JST day, used where no public guide was found).
- Stations: UK Sky News (sky 4050, 119 programmes), talkSPORT (sky 2902), LBC (sky 2926), BBC World Service (placeholder); ES RTVE 24 Horas, 3Cat 324, TV3CAT Internacional (placeholder); FR France 24 FR/EN, franceinfo (placeholder).
- Guide sources still to find: RTVE 24h, 3Cat 324/TV3, France 24 (france24.com pages 403 from homeserver), franceinfo (`api-front.yatta.francetv.fr/standard/publish/channels/franceinfo/programs?date=` lists show definitions, not timed slots), BBC World Service.
- Patched with backups `.bak-pre-stations-<ts>`: `korean-tv-bridge/server.mjs`, `scripts/virtual-epg-fetcher.py`. Syntax checked, NOT yet restarted: a bridge recording was running (KBO playoff, service 4000000008, until 18:10-21:50 JST window on 10/29 per EPGStation), so the restart waits for the owner's OK.
- After restart: remove the same stations from the world adapters (`uk_radio.py`, `es_live.py`, `fr_live.py`, and `sky_uk._talkSPORT`) so they are not listed twice.

## Q.22 Germany round 1 (2026-10-29, PC and homeserver give the same answers)
- Open from both PC (NL) and homeserver (JP): tagesschau24 (`tagesschau.akamaized.net/hls/live/2020115/tagesschau/tagesschau_1/master.m3u8`, 720p H.264+AAC), DW English (`dwamdstream102.akamaized.net/hls/live/2015525/dwstream102/index.m3u8`, 1080p, ENG audio). DW `dwstream103` = Arabic (2015526), `dwstream101` (2015524) also English audio (not added).
- Blocked: ZDF (`zdf-hls-*.akamaized.net` 403 Access Denied), BR/ARD regional (`Blocked: Access denied for this country`), Al Jazeera English / Euronews hosts unreachable. Not checked: n-tv, WELT, Sport1, RTL (pages only).
- Guide source: ARD programme API `https://programm-api.ard.de/program/api/program?day=<YYYY-MM-DD>&channelIds=<id>` (public, homeserver OK; entries `beginNet` ISO start, `duration` s, `title`, synopsis). tagesschau24: 99 programmes. Added as epg type `ard` in `stations-epg-fetch.py`; stations `de-tagesschau24`, `de-dw-en` appended to `stations.json` (take effect at the pending bridge restart).

### Q.23 Italy round 1 (2026-10-29, PC first, then homeserver)
- RaiPlay `dirette.json` lists Rai 1-5, Rai News 24, Rai Sport, Storia, Gulp, YoYo, Movie, Premium, 4K. Relinker (`mediapolis.rai.it/relinker/relinkerServlet.htm?cont=<id>&output=7&forceUserAgent=rainet/1.0`) needs a browser UA + `Referer: https://www.raiplay.it/`; without them it returns 403 Access Denied.
- With UA: only `cont=1` (Rai News 24) returns a real playlist (`rainews1-live.akamaized.net/hls/live/598326/...`); every other Rai channel redirects to `video_no_available.mp4` (geo gate) from both NL (PC) and Japan (homeserver).
- The Rai News 24 playlist itself is 403 from homeserver even with UA + Referer (ffmpeg and streamlink) -> not usable from Japan. No geo workaround (policy).
- Sky TG24 akamai master 403; La7 / Mediaset (TGcom24) / Nove pages 301 or host unreachable; TV8 page 200 but stream URL not extracted yet.
- Next: bulk sweep via the public iptv-org list from homeserver (`iptv_check.py`: playlist -> variant -> first segment), results by country.

### Q.24 Stan Sport (Australia) schedule via public feeds API (2026-10-29)
- Direction from owner: not free IPTV lists; wants overseas editions of paid SVODs (U-NEXT/Hulu-like), DRM/DASH acceptable, mainly to get the programme schedule. Started with Stan (AU). The iptv-org sweep (10,315 URLs, 5,634 reachable from Japan) was dropped as the wrong target; result files stay in the session scratchpad.
- `https://www.stan.com.au/sport/schedule` is a SvelteKit page: the HTML embeds only config (`sports.<name>.feedId`, `events:[]`), events load client-side.
- Discovery: `GET https://api.stan.com.au/?appName=Stan-Web` (public, 46 KB JSON) -> `feeds: https://api.stan.com.au/feeds/v1`. Feed: `GET /feeds/v1/feeds/<feedId>` (public, no login, paginated via `next` with `offset`). Feed ids: Football 1249 (545 entries), Rugby 1089, Tennis 1192, Combat 1618, Modern Pentathlon 4295.
- Entry fields: `title`, `shortMessage` ("Kick-off 5:00pm AEDT"), `sportMetadata{competition, season, round, homeTeam, awayTeam, gameDate(ms)}`, `liveStartDate`, `bundle`, `programType`. A separate "4K •" copy of the same match exists (deduped).
- Adapter `fod-live/live-sources/adapters/au_stan.py` (schedule only, prio 30, 7 days, assumed length football 2h / rugby 1h40 / tennis, combat 3h): 70 events in the world pool (J.League, K League, Premier League, UCL, WSL, rugby, WTA).
- Playback is not available from Japan (paid, AU-only). Playing would need the owner's own Stan login + HAR and own-CDM keys; no geo workaround.
- Gotchas: Chrome extension tab froze on this site (Page.captureScreenshot timeout) and `javascript_tool` blocks any resource-URL listing; the SvelteKit inline script + chunk JS in plain curl was enough. Python `/tmp` on Windows != Git Bash `/tmp` (use relative paths).

### Q.25 United States round 1 (2026-10-30)
- Direction from owner: US services next, schedules for the pool. Probed from homeserver (Japan): Fubo API -> `NO_SERVICE_IN_COUNTRY` (451); Pluto channels API -> empty list; Sling / Tubi hosts unreachable; cdn.nba.com 403; Peacock `api/schedule` 302; `statsapi.mlb.com` open (schedule JSON, MLB already covered elsewhere).
- Working source: Gracenote public TV grid. Lineup list: `GET tvlistings.gracenote.com/gapzap_webapi/api/Providers/getPostalCodeProviders/USA/<zip>/gapzap/en-us` (e.g. 10001 -> `USA-DISH501-DEFAULT`, headend `DISH501`). Grid: `GET /api/grid?lineupId=..&headendId=..&country=USA&timezone=&device=X&postalCode=10001&isOverride=true&time=<unix>&pref=16%2C128&userId=-&aid=orbebb&languagecode=en-us`. Without `aid=orbebb` it returns a misleading 400 "No lineups are available for this ZIP". 593 channels, 1.6 MB per 6-hour call.
- Event fields: `startTime`/`endTime` (UTC ISO), `flag` (`Live`/`New`), `filter` (`filter-sports`, `-news`, `-movie`...), `program{title, episodeTitle, shortDesc, tmsId, seriesId}`.
- Adapter `fod-live/live-sources/adapters/us_gracenote.py`: sports filter + (Live flag or vs/at-style title), dedupes HD/SD/DT copies, 7 days = 28 calls cached 3 h in `cache-us-gracenote.json` (first run ~60 s). Result: 357 events (CBS Sports Network, FS1/FS2, ACC/Big Ten Network, ESPN family, Golf Channel, NASCAR, cricket, FIFA U-17 WWC...). World pool now 1089 events on 80/80 slots, 9 dropped (pool saturated: raise priorities or add a per-network channel set later).
- Schedule only (US-only streams). Any playback needs the owner's own subscription login + HAR + own-CDM; no geo workaround.
- Same grid could back per-broadcaster guides (ABC/CBS/NBC/FOX/ESPN...) if fixed channels are wanted.

### Q.26 Per-broadcaster channels live + US networks (2026-10-30 JST)
- Bridge restarted (old PID 3410045 killed by PID, `start.sh` per standing procedure) after confirming 0 recordings and no bridge-channel reservation within 3 h. Backups: `server.mjs.bak-pre-stations-*`, `server.mjs.bak-pre-nourl-*`.
- `stations.json` now 32 stations: 12 earlier + 20 US (abc/cbs/nbc/fox = New York affiliates WABC/WCBS/WNBC/WNYW, ESPN, ESPN2, ESPNU, ESPNEWS, FS1, FS2, CBS Sports Network, Golf, MLB Network, NBA TV, NFL Network, TNT, TBS, CNN, Fox News, CNBC). New EPG source type `gracenote` in `stations-epg-fetch.py` (28 grid calls, cache `cache-gracenote-full.json` 3 h; first run 5m48s, later runs instant). 89-275 programmes per station.
- Empty `url` = guide-only station: `server.mjs` substitutes `hls://http://127.0.0.1:9/no-stream.m3u8` so playback fails fast (measured: 564 bytes after ~20 s, no hang). Playable ones verified through the bridge: tagesschau24 (720p H.264+AAC, 1 benign error line), Sky News (1080p).
- Mirakurun service ids: `st-*` = 4000001178.. (Sky News 1178, tagesschau24 1188, ABC 1190, CBS 1191, ESPN 1194, ESPN2 1195, ESPNU 1196, ESPNEWS 1197 ...). `/api/programs` uses the short `serviceId` (e.g. 1188), not the 4000001188 form - filtering by the long form gives a false "0 programmes".
- PC (NL) vs homeserver (JP) comparison for the US probe set, done late (I had run it on homeserver only first, against the PC-first rule): Gracenote grid identical on both (593 ch); Pluto channel API returns ~1 MB from the PC but `[]` from Japan (geo-gated, not used); Fubo 404 (PC) / 451 NO_SERVICE_IN_COUNTRY (JP); MLB statsapi open on both.
- Next: remove the duplicate world-pool entries now covered by fixed channels (talkSPORT, LBC, BBC WS, Sky News, RTVE 24h, 3Cat, France 24, franceinfo); the world pool is saturated (80/80, 9 dropped).

### Q.27 Fixed channels at scale (2026-10-30 JST)
- Owner direction: "make them fixed channels, keep going". `stations.json`: 32 -> 103 stations. Added 31 UK (20 Sky Sports / TNT Sports / Premier Sports / club channels via Sky EPG sid + BBC One-Four, BBC ALBA, ITV1-4, Channel 5, 5STAR, S4C) and 40 more US via Gracenote call signs (USA, FX, FXX, HBO, AMC, Bravo, E!, Comedy Central, Discovery, Food, HGTV, TLC, A&E, NatGeo, MS NOW, truTV, SEC/ACC/Big Ten Network, ESPN Deportes, NHL Network, Tennis Channel, beIN, C-SPAN 1/2, TCM, Freeform, Syfy, Disney, MTV, BET, Bloomberg, Lifetime, LMN, Willow, Paramount Network, Travel, Animal Planet, Hallmark, PBS/WNET). Guide-only (empty url) except the playable ones.
- Call signs absent from the DISH NY lineup (not added): HIST, MSNBC (now MS NOW), SECN (use SECAHD), BIGTEN2, NHLN (use NHLNET), PBS (use WNET), NICK, OLY, SHOW, ANPL (use APL).
- World pool de-duplicated: `STATIONS = []` in uk_radio/es_live/fr_live and `_talkSPORT()` stubbed in sky_uk (backups `*.bak-pre-dedupe-*`). Sky Sports/TNT events remain in the pool via sky_uk (276) until those are judged redundant with the fixed channels.
- Cost: `stations-epg-fetch.py` first run with 103 stations = 6m08s (Gracenote 28 calls, then cached 3 h).
- Gotcha: after adding stations, the order matters: stations-epg-fetch -> virtual-epg-fetcher -> bridge restart. The bridge caches `/api/programs` 5 min (`CACHE_TTL_MS`), so new channels show no programmes until it expires.

### Q.28 US streaming-service guides from ESPN scoreboard (2026-10-30 JST)
- Owner: "meanwhile do another US one". Probed from the PC first (NL): `site.api.espn.com/apis/site/v2/sports/<sport>/<league>/scoreboard?dates=YYYYMMDD` (single day; a `YYYYMMDD-YYYYMMDD` range plus `limit=300` returns 400). Each event's `competitions[0].geoBroadcasts[].media.shortName` and `broadcasts[].names` name the carrier, including streaming services: Peacock, Prime Video (and "Prime Video (Local)"), Apple TV (MLS), Paramount+ (UCL), ESPN+, Hulu (NHL), NBA League Pass, plus regional sports networks. Netflix / Max: none found this week.
- New EPG source `espn_stream` in `fod-live/stations-epg-fetch.py`: 16 leagues x 8 days, groups events by carrier, then splits overlapping events into lanes (greedy). Stations `us-<service>-<n>`: Peacock Sports 1-4, Prime Video Sports 1-2, Apple TV Sports 1-4, Paramount+ Sports 1-4, ESPN+ 1-6, Hulu Sports 1-2, NBA League Pass 1-4 (26 channels). Lane counts available now: ESPN+ 13, NBA LP 14, Paramount+ 7, Apple TV 6, Peacock 4, Prime 2, Hulu 2; capped to the busy lanes. Event lengths assumed per sport (NFL 3.5 h, NBA/NHL 2.75 h, ...).
- `stations.json` = 129 stations; bridge restarted again (0 recordings, no reservation within 30 min); 135 st-range channels, all with programmes after restart. Pool still has the ESPN adapter events (duplicates by design until reviewed).
- Schedule only (US-only, paid). Guide quality caveat: ESPN fills broadcast info only a few days ahead, so far-out weeks are sparse.

### Q.29 EPGStation InsertError fixed + 9 more playable fixed channels (2026-10-30 JST)
- Symptom: new fixed channels were registered on the bridge (:36196, 135 in range 1172-1306, all with programmes) but missing from EPGStation's guide. Cause: EPGStation (epgstation-korea, `epgUpdateIntervalTime: 10`) failed EVERY EPG update with `InsertError` (`ProgramDB.insert` rolls back the whole transaction). Visible only in `logs/EPGUpdater/system.log` (the real DB error goes to `console.error`, not the log). Root cause found by inspecting bridge `/api/programs`: 138 duplicate program ids = same World Event channel + same start (two pool events, e.g. `[Copa del Rey]` and `[Sky Sports Premier League]`), because the id derives from `stableEventId(channel_vid, start)`.
- Fix: `scripts/virtual-epg-fetcher.py` now keeps one event per (channel_vid, start) (backup `.bak-pre-dedupe-*`; 17836 -> 17678). After the bridge's 5 min cache and the next EPGStation update: bridge dup ids 0, EPGStation new channels with programmes 122.
- Lesson: any duplicate (channel, start) in virtual-epg.json blocks the guide for ALL channels. Check `EPGUpdater/system.log` after adding adapters.
- Channel 4 recordings at 01:00 JST (4seven, Channel 4) failed with `no bundle registered for 4S/C4`: `c4-bundles.json` only holds E4/F4/M4 (registered 10/28 18:10); 4S and C4 were never registered. Not caused by the bridge restarts. Needs the owner's HAR at :36196/c4.
- New playable fixed channels (all verified through the bridge: H.264 + AAC, 0-2 benign error lines): ABC News (AU) 720p, Fox Sports News (AU) 1080p, Sky News Extra 1 (AU) 576p, Arirang TV 1080p, EBS 1TV 400p, RTHK TV 31 1080p, BFM 2 1080p, DW Espanol 1080p, 24 Horas Catalunya 720p (services 1307-1315). Guides are 24 h placeholders for now. `stations.json` = 138.
- Source of these URLs: the public iptv-org list swept from homeserver (Japan); only streams that decode from Japan were kept, no geo workaround.

### Q.30 Country suffix on channel names + playable US channels (2026-10-30 JST)
- Owner: append the country name after each channel name. `stations.json` names now end with a full-width suffix, e.g. `Sky News（イギリス）`, `ESPN（アメリカ）`, `ABC (WABC)（アメリカ）` (country in Japanese: アメリカ/イギリス/スペイン/フランス/ドイツ/オーストラリア/韓国/香港); the six Channel 4 family names in `server.mjs` too (`Channel 4（イギリス）`...). Backups `stations.json.bak-pre-country-*`, `server.mjs.bak-pre-country-*`. 153 of 153 fixed channels carry the suffix on the bridge. (Windows console shows mojibake because of cp932 only; the API data is correct UTF-8.)
- Owner: "make other US channels watchable somehow". Policy decision recorded: from the iptv-org sweep, US streams that decode from Japan include many raw-IP / unknown-host restreams of pay channels (ESPN, FS1, NFL Network, NBA TV, SEC Network, Big Ten Network, MS NOW, Fox Business, Tennis Channel...). Those are unauthorised relays and are NOT used. Only streams on the broadcaster's own / official hosts were kept.
- Added as playable (bridge-verified, H.264+AAC, 0-1 error lines): Bloomberg TV (existing `us-bloomberg`, now with the official `us-event` stream and the Gracenote guide), Bloomberg Originals, Bloomberg TV Europe, Fox Weather (247wlive.foxweather.com), Newsmax TV (nmx1ota.akamaized.net), NBCLX and Telemundo Puerto Rico (nbculocallive.akamaized.net), PBS Kids (livestream.pbskids.org), CBS News Baltimore and Sacramento (lineup.cbsivideo.com). Services 1272, 1316-1324. Guides are 24 h placeholders except Bloomberg. `stations.json` = 147.
- Official hosts that did NOT decode from Japan (not added): Bloomberg Asia, HSN, QVC, NBC WTVJ, Newsmax Spanish, NTD, The Weather Channel, Cheddar.
- Further US channels (ESPN, FS1, NFL, NBA...) can only become playable with the owner's own legitimate US subscription login + HAR + own-CDM keys; the US subscription services are not obtainable from Japan, so schedule-only stays for them.

### Q.31 Streaming sites opened from the PC (Chrome) + HAR analysis: ABC News Live / NBC News NOW (2026-10-30 JST)
- Owner direction: open the streaming sites from this PC and check. Method: Chrome tab per site, `read_network_requests` for m3u8/mpd after the owner pressed play (play, cookie consent = owner's action). Owner also supplied two HARs (NBC News, ABC News).
- **ABC News Live** (abcnews.com/Live): Disney Streaming (`linear-abcnews-ftc-na-east-1.media.dssott.com`), CMAF-CENC (Widevine) with a signed path (`exp`, `psid`, `did`, `country=US`, `hmac`), license from `disney-entertainment.playback.edge.bamgrid.com/widevine/v1/channel/obtain-license` (needs the viewer's Disney session). Country-bound signed token + authenticated licence => not usable from Japan without relaying a US token; NOT used.
- **NBC News NOW** (nbcnews.com/now -> /watch): the page offers DASH + Widevine (`live-oneapp-prd-news.akamaized.net`, `mt.ssai-oneapp.nbcuni.com`, licence `drmproxy.digitalsvc.apps.nbcuni.com`) AND a clear HLS FAST feed: `https://d368vp0qqzvkid.cloudfront.net/11603/88889709/hls/master.m3u8?ads.*` (Xumo/NBC FAST, 28 ad-config query params, no expiry/signature; segments `xumo-drct-ch101-8hacu.fast.nbcuni.com/live/master_6/*.ts`, no EXT-X-KEY, 720p ladder up to 1080p H.264+AAC). Without the `ads.*` params the master returns 400 `Unable to resolve origin prefix after interpolation`. With the HAR's full URL: PC (NL) master 200; homeserver (Japan) master 200 + decode h264 1080 + aac, 0 errors. Same host also serves Telemundo WTMO-CD (seen in the iptv-org sweep).
- Registered as fixed channel `us-nbcnewsnow` (`NBC News NOW（アメリカ）`, service 1325). URL stored only in `fod-live/stations.json` on homeserver (chmod 600), not copied into notes. Bridge-verified: 3 MB in 5 s, h264 1080 + aac, 1 benign error line. `stations.json` = 148. Guide: 24 h placeholder.
- Fox Weather via Chrome: Fastly + Yospace SSAI with signed time-stamped path (unstable) -> not used; the official fixed `247wlive.foxweather.com` URL already plays from Japan.
- CBS News (cbsnews.com): the extension has no network-read permission for that domain (permission left to the owner); NASA+ and NBC first attempt showed no manifest until the owner pressed play. National CBS News 24/7 still missing; CBS News local feeds (Baltimore, Sacramento, Miami) already added.
- Tabs opened for this were closed.

### Q.32 Asterisk on unwatchable channels (2026-10-30 JST)
- Owner: channels that cannot be watched should carry `*` in the Mirakurun (bridge) channel name. Implemented in `korean-tv-bridge/server.mjs` stations block: `name: s.name + (s.url ? '' : '*')` (backup `server.mjs.bak-pre-star-*`). Rule: `stations.json` entries with an empty `url` (guide-only) get `*`; it disappears automatically once a `url` is set. Bridge result: 154 fixed channels, 116 with `*`, 38 without (Channel 4 family c4-* are defined elsewhere and get no `*` yet: E4/F4/M4 need a fresh HAR registration, 4seven/Channel 4 have none).
- EPGStation picks up the new names on its 10-minute channel update.

### Q.33 US guide-only channels, one by one (2026-10-30 JST)
- Owner: go through the `*` US channels (USA Network ... PBS WNET) one at a time and try to make them watchable. Only legitimate, Japan-reachable sources are acceptable (no VPN / token relay).
- **C-SPAN / C-SPAN2**: c-span.org/networks shows "to watch the live stream you must log in with a TV provider account" (TV Everywhere). Not free -> stays guide-only.
- **MS NOW** (ms.now/live): live player is a timed preview ("preview ends in 04:54") followed by sign-in. Not usable.
- **PBS / THIRTEEN (WNET)** (thirteen.org/live): "Location Required for Live TV - please enable location services" (geolocation-gated to the NY area). Not usable from Japan; no workaround.
- Page-text screening only (not yet confirmed in Chrome): Tennis Channel, Hallmark, NHL Network, beIN Sports, Willow (paid) show login / paid-only; the cable networks (USA, FX, FXX, AMC, Bravo, E!, Comedy Central, Discovery, Food, HGTV, TLC, A&E, NatGeo, truTV, SEC/ACC/Big Ten Network, ESPN Deportes, TCM, Freeform, Syfy, Disney Channel, MTV, BET, Lifetime, LMN, Paramount Network, Travel, Animal Planet) are TV-Everywhere (provider login). HBO = HBO Max subscription.
- Conclusion: for this group the only route to playback is the owner's own legitimate subscription login + HAR + own-CDM keys; the US pay-TV providers are not obtainable from Japan, so they remain guide-only (`*`). Free official FAST-style feeds (e.g. NBC News NOW, Fox Weather, PBS Kids, CBS News local) remain the realistic way to add playable US channels.
- Tabs closed after the check.

### Q.34 Los Angeles local stations + CBS News 24/7 (2026-10-30 JST)
- Owner: "I'm in Los Angeles, so let's try LA TV stations". Method: LA stations' official live pages fetched with curl from the PC, manifest URLs pulled from page meta / embedded JSON (`cbs_scan.py`), then tested from homeserver (Japan).
- **CBS News 24/7 (national)**: `og:video` on cbsnews.com/live = `https://news20e7hhcb.airspace-cdn.cbsivideo.com/index.m3u8` (clear HLS, 8 variants, no EXT-X-KEY). **CBS News Los Angeles** (cbsnews.com/losangeles/live): `https://losandd87138.airspace-cdn.cbsivideo.com/live/manifest.m3u8`. Both: homeserver master 200 + decode h264 1080 + aac, 0 errors. The dai.google.com/linear/hls/event/... URLs on those pages are Google DAI ad-stitched variants (302 redirect), not used.
- **NBC Los Angeles (KNBC) and Telemundo California (KVEA)**: pages embed the FAST feed as a template `d2kowtvrzzi7ps.cloudfront.net/11602/<id>/hls/master.m3u8?ads.*` (placeholders like `APP_NAME` unfilled -> 400/5xx) plus `national_m3u8_url` on `d368vp0qqzvkid.cloudfront.net/11603/<id>/hls/master.m3u8`. A working URL is built from the real `ads.*` values captured in the NBC HAR with only the channel-specific keys swapped (`ads.caid`, `channelName`, `csid`, `xumo_channelId/contentId/contentName/providerId/providerName/streamId`). Ids: NBC LA 88889710 (caid NBCNLA, contentId 3817), Telemundo CA 88889714 (TelemundoNoticiasCA, 3903). Verified distinct feeds: segment hosts `xumo-drct-ch109-...` (LA) vs `ch114-...` (Telemundo CA) vs `ch101-...` (NY). homeserver: master 200, h264 1080 + aac, 0 errors.
- **Correction**: the earlier "NBC News NOW" registration (Q.31, `us-nbcnewsnow`, service 1325) was actually NBC New York's local FAST news feed (`ads.caid=NBCNNY`, `channelName=nbcnewyorknews`, path 88889709), not national NBC News NOW. Renamed to `NBC New York News（アメリカ）`; the Q.31 text describing it as NBC News NOW is superseded.
- Registered (bridge-verified, all h264 1080 + aac, 1 benign error line): 1325 NBC New York News, 1326 NBC Los Angeles News, 1327 Telemundo California Noticias, 1328 CBS News 24/7, 1329 CBS News Los Angeles. `stations.json` = 152. Guides: 24 h placeholders. URLs live only in `stations.json` on homeserver (chmod 600), not in notes.
- Not obtainable: KTLA (403 to curl), ABC7 / FOX LA / Univision KMEX (no manifest in page), PBS SoCal (`player.pbs.org`, needs location/Passport; same class as THIRTEEN). ABC (DSS/Widevine, country-bound) stays excluded.

### Q.35 TBS (US) HAR reviewed, not pursued (2026-10-30 JST)
- Owner supplied a HAR of tbs.com/watchtbs/west and asked to watch US TBS. From Japan, tbs.com redirects to the international Warner Bros. Discovery page (no live).
- HAR shows the live feed is Widevine-protected (CENC) HLS on warnermediacdn.com with SSAI; the page also calls Adobe Pass (TV-provider authentication). It is a pay-TV network feed.
- Decision: not pursued. Obtaining decryption keys for a pay-TV network the owner has no subscription to is out of scope; `us-tbs` stays a guide-only channel (`*`). No key extraction was run on this HAR.

### Q.36 Remaining `*` US cable channels swept (2026-10-30 JST)
- Owner: check the rest in a quick pass, no deep dive. All from the Japan connection (homeserver-equivalent; the owner's own network — the earlier Taiwan/VPN confusion, see below, is unrelated and resolved).
- **Geo-blocked from Japan (403)**: FX, FXX, Discovery Channel, Food Network, HGTV, TLC.
- **TV-provider login required (MVPD/sign-in text on the page)**: HBO (ties to HBO Max subscription), USA Network, Bravo (redirects to nbc.com/live, login), A&E, truTV, Big Ten Network, NHL Network, beIN Sports, TCM, Freeform, Lifetime.
- **Page reachable but no live-stream route found at the guessed URL (404/202, likely wrong path or app-only)**: Comedy Central, SEC Network, ACC Network, ESPN Deportes, Syfy, MTV, BET, Paramount Network.
- **Page loads, no manifest, no obvious login wall either (needs a closer look if ever revisited)**: National Geographic, Tennis Channel, Disney Channel, LMN, Travel Channel, Animal Planet.
- **Willow**: the one `.m3u8` hit was a stale Kaltura entry URL from an old HTML snapshot — re-tested, 404 (expired). Not usable.
- Conclusion: of the `*` US cable set (USA Network through PBS WNET, Q.32/Q.36 combined), none had a legitimate free path from Japan. They stay guide-only. The realistic way to add more playable US channels remains free official FAST/local feeds (as found for NBC NY/LA, Telemundo CA, CBS News national/LA, Fox Weather, Newsmax, NBCLX, PBS Kids, Bloomberg) or the owner's own paid-subscription HAR (as reviewed and declined for TBS, Q.35).
- Session note: a burst of contradictory location claims (Taiwan / Japan / Taiwan / São Paulo within minutes) traced to PrivadoVPN auto-reconnecting to different exit servers (Base IP B.V. US-LA, then NL Amsterdam) while the owner's messages didn't match; confirmed resolved once the VPN tunnel adapter was fully down and the PC's IP matched the known home NURO line (150.249.66.100, Yokohama). No stream work was done against any of those VPN-exit IPs.
