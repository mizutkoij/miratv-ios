"""Play a recording that is still being written ("追っかけ再生" of an in-progress recording).

The app cannot seek past the size the file had when it was opened, so chapterd serves:
  GET /follow/info?name=<file>        -> {"duration": s, "size": bytes, "growing": bool}
  GET /follow?name=<file>&t=<seconds> -> the TS from about t seconds in, then keeps sending new data as the
                                          recorder appends it, and ends once the file has stopped growing
Times come from the PCR (the broadcast clock in the TS), so a position means the same thing as in the finished
recording. Byte positions for a time are found by binary search on the PCR (about 20 small reads).
"""
import os
import time

PKT = 188
WRAP = 1 << 33
GROWING_IDLE = 20.0          # no new bytes for this long = the recording has finished
# While waiting for the recorder, send a null packet now and then so the player's read timeout (15 s) never fires
NULL_PACKET = b"\x47\x1f\xff\x10" + b"\xff" * 184


def _pcr_in(buf, want_pid=None):
    """First PCR in buf (aligned to 188). Returns (pid, pcr seconds as 90 kHz base) or None."""
    n = len(buf) - len(buf) % PKT
    for off in range(0, n, PKT):
        if buf[off] != 0x47:
            return None
        b3 = buf[off + 3]
        if not (b3 & 0x20) or buf[off + 4] < 7 or not (buf[off + 5] & 0x10):
            continue
        pid = ((buf[off + 1] & 0x1F) << 8) | buf[off + 2]
        if want_pid is not None and pid != want_pid:
            continue
        p = buf[off + 6:off + 11]
        base = (p[0] << 25) | (p[1] << 17) | (p[2] << 9) | (p[3] << 1) | (p[4] >> 7)
        return pid, base
    return None


def _last_pcr_in(buf, want_pid):
    """Last PCR of want_pid in buf (buf starts on a packet boundary)."""
    last = None
    n = len(buf) - len(buf) % PKT
    for off in range(0, n, PKT):
        if buf[off] != 0x47:
            break
        if not (buf[off + 3] & 0x20) or buf[off + 4] < 7 or not (buf[off + 5] & 0x10):
            continue
        if (((buf[off + 1] & 0x1F) << 8) | buf[off + 2]) != want_pid:
            continue
        p = buf[off + 6:off + 11]
        last = (p[0] << 25) | (p[1] << 17) | (p[2] << 9) | (p[3] << 1) | (p[4] >> 7)
    return last


def _sync(f, pos, size):
    """First packet boundary at or after pos (three 0x47 in a row)."""
    f.seek(pos)
    buf = f.read(PKT * 3 + 4096)
    for i in range(min(len(buf) - 2 * PKT, 4096)):
        if buf[i] == 0x47 and buf[i + PKT] == 0x47 and buf[i + 2 * PKT] == 0x47:
            return pos + i
    return None


def _pcr_at(f, pos, size, pid=None, span=512 * 1024):
    s = _sync(f, pos, size)
    if s is None:
        return None
    f.seek(s)
    r = _pcr_in(f.read(min(span, max(size - s, 0))), pid)
    return (s,) + r if r else None


class Index:
    """Maps seconds <-> bytes for one file. The first PCR fixes 0 s; it is the same clock the app uses
    (the PCR runs with the PTS, so this matches the finished recording within a fraction of a second)."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            size = os.path.getsize(path)
            first = _pcr_at(f, 0, size)
            if not first:
                raise RuntimeError("no PCR (not a TS?)")
            _, self.pid, self.pcr0 = first

    def seconds(self, pcr):
        return ((pcr - self.pcr0) % WRAP) / 90000.0

    def info(self):
        size = os.path.getsize(self.path)
        with open(self.path, "rb") as f:
            # 末尾の少しだけを読んで、いちばん後ろの PCR を取る（無ければ範囲を広げる）
            last = None
            back = 512 * 1024
            while last is None and back <= 32 * 1024 * 1024:
                s = _sync(f, max(size - back, 0), size)
                if s is not None:
                    f.seek(s)
                    last = _last_pcr_in(f.read(size - s), self.pid)
                back *= 8
        dur = self.seconds(last) if last is not None else 0.0
        growing = time.time() - os.path.getmtime(self.path) < GROWING_IDLE
        return {"duration": round(dur, 2), "size": size, "growing": growing}

    def offset_for(self, t):
        """Byte offset (packet aligned) of about t seconds in. Lands a little before t, never after."""
        size = os.path.getsize(self.path)
        lo, hi = 0, size
        best = 0
        with open(self.path, "rb") as f:
            for _ in range(40):
                if hi - lo < 256 * 1024:
                    break
                mid = (lo + hi) // 2
                r = _pcr_at(f, mid, size, self.pid)
                if not r:
                    hi = mid
                    continue
                at, _, pcr = r
                if self.seconds(pcr) <= t:
                    best, lo = at, mid
                else:
                    hi = mid
            s = _sync(f, best, size)
        return s if s is not None else 0


_indexes = {}


def index_for(path):
    ix = _indexes.get(path)
    if ix is None:
        ix = _indexes[path] = Index(path)
        if len(_indexes) > 64:
            _indexes.pop(next(iter(_indexes)))
    return ix


def stream(path, t, write, chunk=256 * 1024):
    """Send from about t seconds, then follow the file while it grows. write(bytes) raises on a closed client."""
    ix = index_for(path)
    pos = ix.offset_for(max(t, 0.0))
    last_sent = time.time()
    with open(path, "rb") as f:
        while True:
            f.seek(pos)
            data = f.read(chunk)
            data = data[:len(data) - len(data) % PKT]     # 書きかけのパケットは次の回に（null パケットと混ざらないように）
            if data:
                write(data)
                pos += len(data)
                last_sent = time.time()
                continue
            # caught up with the recorder: wait for more, end once the file stops growing
            now = time.time()
            if now - os.path.getmtime(path) >= GROWING_IDLE:
                return
            if now - last_sent >= 2.0:
                write(NULL_PACKET)                 # 待っている間も接続を生かしておく（プレイヤーが読み切れで止めないように）
                last_sent = now
            time.sleep(0.25)
