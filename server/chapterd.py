#!/usr/bin/env python3
"""MiraTV CM detection ("chapter") service.

Why: recordings carry no chapter/CM information (no comskip, no .chapter files on this box), and the phone
cannot afford to read a 4-8 GB TS just to look at the audio. This service runs ffmpeg's `silencedetect` on the
audio track only (about 45x real time, one thread, nice 19 / idle IO) and turns the silences into CM blocks.

How CM blocks are found: Japanese broadcasts put a short silence at the boundary of every spot and spots are
15 s multiples. A chain of silences whose gaps are all within +-0.7 s of a multiple of 15 s (>= 2 gaps) is a CM
block. Verified on a 25 min slice of a TBS drama: 0:04-1:49 (sponsor credits + CMs) and 22:07-24:22 (nine 15 s
gaps in a row) were found; dialogue silences practically never line up on the 15 s grid.

API (bound to the Tailscale address only, no auth, read-only):
  GET /raw?name=<video file name>   -> the recording itself, with HTTP Range (direct playback, bypasses EPGStation/Node)
  GET /chapters/<videoFileId>?name=<video file name>
      -> {"status": "pending|running|ready|error", "progress": 0..1, "duration": s, "cm": [[start, end], ...]}
  GET /health
Positions are seconds from the start of the file (ffmpeg zero-bases the stream), which is the same timeline the
app uses (PTS - stream start_time).
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RECORDED = os.environ.get("RECORDED_DIR", "/home/homeserver/recorded")
FFMPEG = os.environ.get("FFMPEG", "/home/homeserver/epgstation_downloader/ffmpeg")
CACHE = os.environ.get("CACHE_DIR", os.path.expanduser("~/.cache/miratv-chapters"))
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "23235"))
APPLOG_DIR = os.environ.get("APPLOG_DIR", os.path.expanduser("~/miratv-chapterd/applog"))
ALGO = 2  # bump when the detection rules change so old cache files are ignored

GRID = 15.0        # CM spots are multiples of 15 s
TOLERANCE = 0.7    # seconds
MIN_GAPS = 2       # at least two consecutive spots
MAX_SPOT_MULT = 8  # up to 120 s single spot
MERGE_GAP = 20.0   # CM blocks closer than this are one break (a single missed silence leaves a 15 s hole)

lock = threading.Lock()
jobs = {}          # videoFileId -> dict(status, progress, duration, cm, path, error)
queue = []         # videoFileIds waiting for the single worker
wake = threading.Event()


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def find_file(name):
    """Only a bare file name is accepted (no path parts); search the recording tree up to 3 levels deep."""
    if not name or "/" in name or "\\" in name or name in (".", ".."):
        return None
    base_depth = RECORDED.rstrip(os.sep).count(os.sep)
    for root, dirs, files in os.walk(RECORDED):
        if root.count(os.sep) - base_depth >= 3:
            dirs[:] = []
        if name in files:
            return os.path.join(root, name)
    return None


_path_cache = {}


def find_file_cached(name):
    p = _path_cache.get(name)
    if p and os.path.isfile(p):
        return p
    p = find_file(name)
    if p:
        _path_cache[name] = p
    return p


def cache_path(vid):
    return os.path.join(CACHE, f"{vid}.json")


def load_cache(vid, path):
    try:
        with open(cache_path(vid), encoding="utf-8") as f:
            c = json.load(f)
        st = os.stat(path)
        if c.get("algo") == ALGO and c.get("size") == st.st_size:
            return c
    except Exception:
        pass
    return None


def save_cache(vid, path, result):
    os.makedirs(CACHE, exist_ok=True)
    st = os.stat(path)
    data = dict(result, algo=ALGO, size=st.st_size)
    tmp = cache_path(vid) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, cache_path(vid))


def detect_cm(mids):
    """mids = sorted silence midpoints (s). Returns [[start, end], ...] of 15 s-grid chains."""
    def on_grid(g):
        k = round(g / GRID)
        return 1 <= k <= MAX_SPOT_MULT and abs(g - GRID * k) <= TOLERANCE

    gaps = [b - a for a, b in zip(mids, mids[1:])]
    blocks, cur = [], None
    for i, g in enumerate(gaps):
        if on_grid(g):
            cur = [i, i] if cur is None else [cur[0], i]
        elif cur is not None:
            blocks.append(cur)
            cur = None
    if cur is not None:
        blocks.append(cur)
    out = []
    for a, b in blocks:
        if b - a + 1 >= MIN_GAPS:
            out.append([round(mids[a], 2), round(mids[b + 1], 2)])
    # one missed silence leaves a ~15 s hole between two chains of the same break: join them
    merged = []
    for blk in out:
        if merged and blk[0] - merged[-1][1] <= MERGE_GAP:
            merged[-1][1] = blk[1]
        else:
            merged.append(blk)
    return merged


def hms(s):
    h, m, sec = s.split(":")
    return int(h) * 3600 + int(m) * 60 + float(sec)


def analyze(vid, path):
    cmd = [FFMPEG, "-hide_banner", "-nostdin", "-threads", "1", "-i", path, "-map", "0:a:0",
           "-af", "silencedetect=noise=-50dB:d=0.1", "-f", "null", "-"]
    log("analyze start", vid, os.path.basename(path))
    p = subprocess.Popen(cmd, stderr=subprocess.PIPE, stdout=subprocess.DEVNULL)
    buf = ""
    mids = []
    duration = 0.0
    last_time = 0.0
    while True:
        chunk = p.stderr.read(2048)
        if not chunk:
            break
        buf += chunk.decode("utf-8", "replace")
        parts = re.split(r"[\r\n]", buf)
        buf = parts.pop()
        for line in parts:
            m = re.search(r"Duration: (\d+:\d+:[\d.]+)", line)
            if m and not duration:
                duration = hms(m.group(1))
            m = re.search(r"silence_end: ([\d.]+) \| silence_duration: ([\d.]+)", line)
            if m:
                mids.append(float(m.group(1)) - float(m.group(2)) / 2)
            m = re.search(r"time=(\d+:\d+:[\d.]+)", line)
            if m:
                last_time = hms(m.group(1))
                with lock:
                    job = jobs.get(vid)
                    if job and duration:
                        job["progress"] = min(last_time / duration, 0.99)
    rc = p.wait()
    if rc != 0:
        raise RuntimeError(f"ffmpeg exited with {rc}")
    mids.sort()
    return {"status": "ready", "progress": 1.0, "duration": duration or last_time, "cm": detect_cm(mids),
            "silences": len(mids)}


def worker():
    while True:
        wake.wait()
        while True:
            with lock:
                if not queue:
                    wake.clear()
                    break
                vid = queue.pop(0)
                job = jobs[vid]
                job["status"] = "running"
            try:
                result = analyze(vid, job["path"])
                save_cache(vid, job["path"], result)
                with lock:
                    job.update(result)
                log("analyze done", vid, "cm blocks:", len(result["cm"]))
            except Exception as e:  # noqa: BLE001
                log("analyze failed", vid, e)
                with lock:
                    job.update(status="error", error=str(e))


def request_chapters(vid, name):
    with lock:
        job = jobs.get(vid)
        if job and job["status"] in ("pending", "running", "ready"):
            return dict(job)
    path = find_file(name)
    if not path:
        return {"status": "error", "error": "file not found"}
    cached = load_cache(vid, path)
    if cached:
        job = dict(cached, status="ready", path=path)
        with lock:
            jobs[vid] = job
        return dict(job)
    job = {"status": "pending", "progress": 0.0, "duration": 0.0, "cm": [], "path": path}
    with lock:
        jobs[vid] = job
        queue.append(vid)
    wake.set()
    return dict(job)


class Handler(BaseHTTPRequestHandler):
    server_version = "miratv-chapterd/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[chapterd] " + (fmt % args) + "\n")

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        # アプリのデバッグログ。日付ごとのファイルに追記する（1 回 64KB まで、1 日 20MB まで）
        u = urllib.parse.urlparse(self.path)
        if u.path == "/shot":
            # デバッグ用のスクリーンショット（PNG、2MB まで）
            name = re.sub(r"[^A-Za-z0-9_-]", "_", urllib.parse.parse_qs(u.query).get("name", ["shot"])[0])[:40]
            data = self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 2 * 1024 * 1024))
            d = os.path.join(APPLOG_DIR, "shots")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, time.strftime("%Y%m%d-%H%M%S-") + name + ".png"), "wb") as f:
                f.write(data)
            return self._json({"ok": True})
        if u.path != "/log":
            return self._json({"error": "not found"}, 404)
        n = min(int(self.headers.get("Content-Length") or 0), 65536)
        body = self.rfile.read(n).decode("utf-8", "replace")
        os.makedirs(APPLOG_DIR, exist_ok=True)
        path = os.path.join(APPLOG_DIR, time.strftime("%Y-%m-%d") + ".log")
        if not os.path.exists(path) or os.path.getsize(path) < 20 * 1024 * 1024:
            with open(path, "a", encoding="utf-8") as f:
                f.write(body.rstrip("\n") + "\n")
        self._json({"ok": True})

    def _raw(self, head):
        """Serve a recording with Range support. Why: EPGStation streams through Node and is the bottleneck on a phone;
        a plain file read is cheap and seekable. Only bare file names under RECORDED are reachable."""
        u = urllib.parse.urlparse(self.path)
        name = urllib.parse.parse_qs(u.query).get("name", [""])[0]
        path = find_file_cached(name)
        if not path or not name.lower().endswith((".ts", ".m2ts", ".mp4", ".mkv")):
            return self._json({"error": "file not found"}, 404)
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip()) if rng else None
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            else:
                start = max(size - int(m.group(2)), 0)
            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        length = end - start + 1
        self.send_header("Content-Type", "video/mp2t" if name.lower().endswith((".ts", ".m2ts")) else "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        self.end_headers()
        if head:
            return
        try:
            with open(path, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    chunk = f.read(min(256 * 1024, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_HEAD(self):
        if urllib.parse.urlparse(self.path).path == "/raw":
            return self._raw(True)
        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/raw":
            return self._raw(False)
        if u.path == "/health":
            with lock:
                return self._json({"ok": True, "queue": len(queue), "jobs": len(jobs)})
        m = re.fullmatch(r"/chapters/(\d+)", u.path)
        if m:
            name = urllib.parse.parse_qs(u.query).get("name", [""])[0]
            res = request_chapters(int(m.group(1)), name)
            res.pop("path", None)
            return self._json(res)
        self._json({"error": "not found"}, 404)


def main():
    threading.Thread(target=worker, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    log(f"listening on {HOST}:{PORT}  recorded={RECORDED}  ffmpeg={FFMPEG}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
