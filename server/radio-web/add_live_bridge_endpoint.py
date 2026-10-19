#!/usr/bin/env python3
"""Add /live/fmplapla/<slug>.mp3 and /live/jcba/<slug>.mp3 to radio-web (VPS2). Needs live_bridge.py next to server.py.

Why: FMぷらぷら (Ogg) and JCBA (WebSocket + Ogg/Opus) could not be played on iPhone. live_bridge.py transcodes them to a
progressive MP3 that AVPlayer opens like an Icecast stream. The route only validates the slug and hands over to the bridge;
fmplapla's tokenised URL is resolved here with the existing resolve_fmplapla_stream().
"""
import shutil, sys, time

P = "/home/ubuntu/radio-web/server.py"
s = open(P, encoding="utf-8").read()
if "live_bridge" in s:
    print("already patched"); sys.exit(0)
shutil.copy(P, P + ".bak-" + time.strftime("%Y%m%d%H%M%S"))

IMPORT_AFTER = "import radiko  # noqa: E402\n"
IMPORT = "import live_bridge  # noqa: E402  (fmplapla / JCBA -> MP3)\n"

METHOD = '''    # ---- FMぷらぷら / JCBA のライブを MP3 にして流す(live_bridge.py) ----
    def _live_bridge(self, kind, slug):
        if not live_bridge.valid_slug(slug):
            return self._error(400, "invalid station")
        url = None
        if kind == "fmplapla":
            try:
                url = resolve_fmplapla_stream(slug)
            except Exception as e:
                return self._error(502, f"resolve failed: {e}")
        err = live_bridge.serve(self, kind, slug, fmplapla_url=url)
        if err == "busy":
            return self._error(503, "too many live streams")
        if err:
            return self._error(502, f"stream failed: {err}")

'''

ROUTE = '''            if path.startswith("/live/fmplapla/") and path.endswith(".mp3"):
                return self._live_bridge("fmplapla", unquote(path[len("/live/fmplapla/"):-len(".mp3")]))
            if path.startswith("/live/jcba/") and path.endswith(".mp3"):
                return self._live_bridge("jcba", unquote(path[len("/live/jcba/"):-len(".mp3")]))
'''

b = "    # ---- ListenRadioライブ(Refererチェック式"
c = '            if path.startswith("/live/listenradio/") and path.endswith("/playlist.m3u8"):'
for m in (IMPORT_AFTER, b, c):
    assert s.count(m) == 1, m
s = s.replace(IMPORT_AFTER, IMPORT_AFTER + IMPORT, 1).replace(b, METHOD + b, 1).replace(c, ROUTE + c, 1)
open(P, "w", encoding="utf-8").write(s)
import ast; ast.parse(s)
print("patched")
