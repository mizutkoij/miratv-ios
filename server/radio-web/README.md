# radio-web patches (VPS2, /home/ubuntu/radio-web/server.py)

radio-web is the single owner of the radio catalog and stream URL resolution (see notes); these scripts patch it in place
(each makes a timestamped `server.py.bak-*` first and refuses to run twice). Restart with `pm2 restart radio-web`.

- `add_timefree_endpoint.py` — adds `GET /timefree/radiko/<station>.m3u8?ft=YYYYMMDDHHMMSS&to=YYYYMMDDHHMMSS`
  (HLS VOD of any radiko program within the last 7 days; segments go through the existing `/live/radiko/<station>/seg`
  proxy). 15-minute cache. A later hand edit on the server added a 7-day window check (404 outside it) — re-apply if the
  script is run on a fresh server.
