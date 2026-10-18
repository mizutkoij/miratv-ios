#!/usr/bin/env python3
"""Add /timefree/radiko/<station>.m3u8?ft=YYYYMMDDHHMMSS&to=YYYYMMDDHHMMSS to radio-web (VPS2).

Why: the app could only play past radiko programs that the archive pipeline had uploaded (nzb). radiko itself keeps
7 days of timefree; this serves any program in that window as an HLS VOD playlist whose segments go through the
existing /live/radiko/<station>/seg proxy (auth header injection). Playlist building walks 5-min slices (radiko limit)
in 4 threads and is cached for 15 minutes.
"""
import shutil, sys, time

P = "/home/ubuntu/radio-web/server.py"
s = open(P, encoding="utf-8").read()
if "_timefree_radiko_playlist" in s:
    print("already patched"); sys.exit(0)
shutil.copy(P, P + ".bak-" + time.strftime("%Y%m%d%H%M%S"))

MODULE = '''# ---------- radiko 聴き逃し(timefree)の HLS(VOD) プレイリスト生成 ----------
_tf_cache = {}  # (station, ft, to) -> (expiry_ts, playlist_text)
_tf_lock = threading.Lock()
TF_CACHE_SEC = 15 * 60


def _tf_slice(base, sess, station, cur, end_dt, to):
    """5 分刻みの 1 枚ぶん: master -> media -> セグメント一覧。空なら番組の終わりの先"""
    sep = "&" if "?" in base else "?"
    length = min(radiko.TF_CHUNK_SEC, int((end_dt - cur).total_seconds()))
    cur_str = cur.strftime("%Y%m%d%H%M%S")
    master_url = f"{base}{sep}" + radiko.urlencode({
        "station_id": station, "start_at": cur_str, "ft": cur_str, "end_at": to, "to": to,
        "l": str(length), "lsid": sess["info"]["userid"], "type": "b"})
    media_url = radiko._resolve_media_url(master_url, sess)
    if media_url is None:
        return []
    req = urllib.request.Request(media_url, headers={
        "X-Radiko-AuthToken": sess["token"], "X-Radiko-AreaId": sess["area_id"], "User-Agent": "Mozilla/5.0"})
    status, _, body = radiko.http(req)
    if status != 200:
        raise RuntimeError(f"timefree medialist failed: {status}")
    return radiko._parse_media_segments(body.decode("utf-8", errors="replace"))


def build_timefree_playlist(station, ft, to, sess):
    from concurrent.futures import ThreadPoolExecutor
    base = radiko._playlist_create_url(station, sess, timefree=True)
    start_dt, end_dt = radiko._parse_ts(ft), radiko._parse_ts(to)
    slices, cur = [], start_dt
    while cur < end_dt:
        slices.append(cur)
        cur += radiko.timedelta(seconds=radiko.TF_CHUNK_SEC)
    with ThreadPoolExecutor(max_workers=4) as ex:
        results = list(ex.map(lambda c: _tf_slice(base, sess, station, c, end_dt, to), slices))
    seen, segs = set(), []
    for res in results:
        for pdt, extinf, url in res:
            if (pdt is not None and pdt >= end_dt) or url in seen:
                continue
            seen.add(url)
            segs.append((extinf, url))
    if not segs:
        return None
    longest = 6
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-MEDIA-SEQUENCE:0"]
    body = []
    for extinf, url in segs:
        try:
            longest = max(longest, int(float(extinf.split(":", 1)[1].split(",")[0]) + 0.999))
        except Exception:
            pass
        body.append(extinf if extinf.startswith("#EXTINF:") else "#EXTINF:5.0,")
        body.append(f"/live/radiko/{quote(station, safe='')}/seg?u={quote(url, safe='')}")
    lines.insert(2, f"#EXT-X-TARGETDURATION:{longest}")
    return "\\n".join(lines + body + ["#EXT-X-ENDLIST"]) + "\\n"


'''

METHOD = '''    # ---- radiko 聴き逃し(timefree): 過去 7 日の任意の番組を HLS(VOD) で ----
    def _timefree_radiko_playlist(self, station, ft, to):
        if not radiko.C["radioAreaId"].get(station):
            return self._error(404, f"unknown station: {station}")
        if not (re.fullmatch(r"\\d{14}", ft or "") and re.fullmatch(r"\\d{14}", to or "")):
            return self._error(400, "ft/to must be YYYYMMDDHHMMSS")
        try:
            span = (radiko._parse_ts(to) - radiko._parse_ts(ft)).total_seconds()
        except ValueError:
            return self._error(400, "bad ft/to")
        if not (0 < span <= 4 * 3600):
            return self._error(400, "length must be within 4 hours")
        key = (station, ft, to)
        with _tf_lock:
            hit = _tf_cache.get(key)
        if hit and time.time() < hit[0]:
            return self._text(hit[1], content_type="application/vnd.apple.mpegurl")
        area_id = resolve_default_area(station)
        sess = get_session(area_id)
        try:
            text = build_timefree_playlist(station, ft, to, sess)
        except Exception:
            with _sess_lock:
                _sessions.pop(area_id, None)
            sess = get_session(area_id)
            text = build_timefree_playlist(station, ft, to, sess)
        if text is None:
            return self._error(404, "no timefree data (outside the 7-day window or not aired)")
        with _tf_lock:
            _tf_cache[key] = (time.time() + TF_CACHE_SEC, text)
            if len(_tf_cache) > 200:
                for k in sorted(_tf_cache, key=lambda k: _tf_cache[k][0])[:50]:
                    _tf_cache.pop(k, None)
        self._text(text, content_type="application/vnd.apple.mpegurl")

'''

ROUTE = '''            if path.startswith("/timefree/radiko/") and path.endswith(".m3u8"):
                station = path[len("/timefree/radiko/"):-len(".m3u8")]
                return self._timefree_radiko_playlist(station, qs.get("ft", [""])[0], qs.get("to", [""])[0])
'''

a = "class Handler(BaseHTTPRequestHandler):"
b = "    # ---- ListenRadioライブ(Refererチェック式"
c = '            if path.startswith("/live/listenradio/") and path.endswith("/playlist.m3u8"):'
for m in (a, b, c):
    assert s.count(m) == 1, m
s = s.replace(a, MODULE + a, 1).replace(b, METHOD + b, 1).replace(c, ROUTE + c, 1)
open(P, "w", encoding="utf-8").write(s)
import ast; ast.parse(s)
print("patched")
