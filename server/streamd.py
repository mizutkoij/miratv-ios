#!/usr/bin/env python3
"""MiraTV stream relay ("streamd"): lighter live streams without any encoding.

Why: transcoding on the recording box (EPGStation + ffmpeg) costs a lot of CPU and competes with recpt1/Mirakurun.
A broadcast TS is ~15-17 Mbps, but most of it is video. When the phone only needs the sound (audio-only mode,
weak mobile link), the video packets are pure waste. This relay reads the service stream from Mirakurun and
forwards only the TS packets that are needed. It never decodes or encodes, so the cost is a few % of one core
per viewer (packet header parsing in Python).

  GET /live/<serviceId>?video=0         audio + captions only (~0.2-0.4 Mbps)
  GET /live/<serviceId>?video=1&data=0  video + audio + captions, without data broadcast / other ES
  GET /health

The PMT is rewritten to list only the kept elementary streams (and the CRC recomputed), so the player does not
wait for streams that never arrive. If a PMT spans more than one TS packet, it is forwarded unchanged.
Bound to the Tailscale address only, no auth (same as chapterd).
"""
import os
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MIRAKURUN = os.environ.get("MIRAKURUN", "http://127.0.0.1:40772").rstrip("/")
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "23236"))
CHUNK = 188 * 512

# ISO/IEC 13818-1 + ARIB STD-B10 stream types
VIDEO_TYPES = {0x01, 0x02, 0x1B, 0x24, 0x10}
AUDIO_TYPES = {0x03, 0x04, 0x0F, 0x11}
PES_PRIVATE = 0x06          # ARIB captions / superimpose are PES private data (component tag 0x30-0x38)

viewers = 0
viewers_lock = threading.Lock()


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def component_tag(descriptors):
    """stream_identifier_descriptor (0x52) -> component_tag, else None"""
    i = 0
    while i + 2 <= len(descriptors):
        tag, length = descriptors[i], descriptors[i + 1]
        if tag == 0x52 and length >= 1:
            return descriptors[i + 2]
        i += 2 + length
    return None


class Filter:
    def __init__(self, keep_video, keep_data):
        self.keep_video = keep_video
        self.keep_data = keep_data
        self.pmt_pid = None
        self.keep = {0x0000}            # PAT always. None = 全部通す（PMT を書き換えられなかったとき）
        self.pmt_cache = {}             # original PMT packet bytes -> (rewritten bytes, keep set or None)

    def _parse_pat(self, pkt):
        if not pkt[1] & 0x40:
            return
        off = self._payload_offset(pkt)
        if off is None:
            return
        off += 1 + pkt[off]             # pointer_field
        sec = pkt[off:]
        if len(sec) < 8 or sec[0] != 0x00:
            return
        length = ((sec[1] & 0x0F) << 8) | sec[2]
        body = sec[8:3 + length - 4]
        for i in range(0, len(body) - 3, 4):
            program = (body[i] << 8) | body[i + 1]
            pid = ((body[i + 2] & 0x1F) << 8) | body[i + 3]
            if program != 0:
                if pid != self.pmt_pid:
                    self.pmt_pid = pid
                    self.keep = {0x0000, pid}
                    self.pmt_cache.clear()
                return

    @staticmethod
    def _payload_offset(pkt):
        afc = (pkt[3] >> 4) & 0x3
        if afc in (0, 2):
            return None
        off = 4
        if afc == 3:
            off += 1 + pkt[4]
        return off if off < 188 else None

    def _rewrite_pmt(self, pkt):
        """Return the packet with non-kept ES removed from the PMT (single-packet sections only)."""
        cached = self.pmt_cache.get(pkt)
        if cached is not None:
            self.keep = cached[1]
            return cached[0]
        out = pkt
        new_keep = None                 # 書き換えられなければ全部通す（音が止まるより、重くても鳴るほうがよい）
        off = self._payload_offset(pkt)
        if off is not None and pkt[1] & 0x40:
            ptr = pkt[off]
            start = off + 1 + ptr
            sec = pkt[start:]
            if len(sec) >= 12 and sec[0] == 0x02:
                length = ((sec[1] & 0x0F) << 8) | sec[2]
                total = 3 + length
                if total <= len(sec):          # whole section in this packet
                    info_len = ((sec[10] & 0x0F) << 8) | sec[11]
                    head = bytearray(sec[:12 + info_len])
                    i = 12 + info_len
                    end = total - 4
                    kept_es = bytearray()
                    keep = {0x0000, self.pmt_pid}
                    dropped = set()
                    pcr_pid = ((sec[8] & 0x1F) << 8) | sec[9]
                    while i + 5 <= end:
                        st = sec[i]
                        pid = ((sec[i + 1] & 0x1F) << 8) | sec[i + 2]
                        es_len = ((sec[i + 3] & 0x0F) << 8) | sec[i + 4]
                        entry = sec[i:i + 5 + es_len]
                        desc = sec[i + 5:i + 5 + es_len]
                        if self._want(st, desc):
                            kept_es += entry
                            keep.add(pid)
                        else:
                            dropped.add(pid)
                        i += 5 + es_len
                    if pcr_pid in dropped:
                        # PCR が捨てた ES（映像）に乗っていた: PCR なしと宣言する（FFmpeg は PTS で再生できる）
                        head[8] = (head[8] & 0xE0) | 0x1F
                        head[9] = 0xFF
                    elif pcr_pid != 0x1FFF:
                        keep.add(pcr_pid)                        # 地デジは PCR 専用 PID (0x01FF など) が多い。小さいので残す
                    new_len = len(head) - 3 + len(kept_es) + 4
                    head[1] = (head[1] & 0xF0) | ((new_len >> 8) & 0x0F)
                    head[2] = new_len & 0xFF
                    section = bytes(head) + bytes(kept_es)
                    section += crc32_mpeg(section).to_bytes(4, "big")
                    payload = pkt[off:start] + section
                    out = pkt[:off] + payload + b"\xFF" * (188 - off - len(payload))
                    new_keep = keep
                else:
                    log("PMT が複数パケットにまたがるため、この局は間引かずに中継します")
        elif off is not None:
            new_keep = self.keep            # PMT の続きのパケット（先頭でない）: いまの設定のまま
        if len(self.pmt_cache) > 64:
            self.pmt_cache.clear()
        self.pmt_cache[pkt] = (out, new_keep)
        self.keep = new_keep
        return out

    def _want(self, stream_type, desc):
        if stream_type in AUDIO_TYPES:
            return True
        if stream_type in VIDEO_TYPES:
            return self.keep_video
        if stream_type == PES_PRIVATE:
            tag = component_tag(desc)
            if tag is not None and 0x30 <= tag <= 0x3F:   # 字幕 0x30-0x37 / 文字スーパー 0x38-0x3F
                return True
            return self.keep_data
        return self.keep_data                              # DSM-CC (0x0D) etc. = data broadcast

    def feed(self, buf):
        """Returns (filtered bytes, consumed). 同期バイト 0x47 がずれたら探し直す。端の半端は呼び出し側に残す"""
        out = []
        mv = memoryview(buf)
        i, n = 0, len(buf)
        while i + 188 <= n:
            if buf[i] != 0x47 or (i + 188 < n and buf[i + 188] != 0x47):
                j = buf.find(b"\x47", i + 1)
                i = n if j < 0 else j
                continue
            pkt = bytes(mv[i:i + 188])
            i += 188
            pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
            if pid == 0x0000:
                self._parse_pat(pkt)
                out.append(pkt)
            elif pid == self.pmt_pid:
                out.append(self._rewrite_pmt(pkt))
            elif self.keep is None or pid in self.keep:
                out.append(pkt)
        return b"".join(out), i


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 30        # 端末が消えたまま書き込みで止まり、チューナーを握り続けないように

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        global viewers
        u = urllib.parse.urlparse(self.path)
        if u.path == "/health":
            body = f'{{"ok":true,"viewers":{viewers}}}'.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        parts = u.path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "live" or not parts[1].isdigit():
            self.send_error(404)
            return
        q = urllib.parse.parse_qs(u.query)
        keep_video = q.get("video", ["1"])[0] != "0"
        keep_data = q.get("data", ["0"])[0] == "1"
        src = f"{MIRAKURUN}/api/services/{parts[1]}/stream?decode=1"
        req = urllib.request.Request(src, headers={"X-Mirakurun-Priority": "0", "User-Agent": "miratv-streamd"})
        try:
            upstream = urllib.request.urlopen(req, timeout=15)
        except Exception as e:
            log("upstream error", parts[1], e)
            self.send_error(502, "Mirakurun: " + str(e))
            return
        with viewers_lock:
            viewers += 1
        log(f"open service={parts[1]} video={int(keep_video)} data={int(keep_data)} viewers={viewers}")
        f = Filter(keep_video, keep_data)
        sent = 0
        t0 = time.time()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            pending = b""
            while True:
                buf = upstream.read(CHUNK)
                if not buf:
                    break
                buf = pending + buf
                data, used = f.feed(buf)
                pending = buf[used:]
                if len(pending) > 188 * 4:      # 同期が取れないまま溜まり続けないように
                    pending = pending[-188:]
                if data:
                    self.wfile.write(b"%X\r\n" % len(data) + data + b"\r\n")
                    sent += len(data)
            self.wfile.write(b"0\r\n\r\n")
        except OSError:                     # 切断・タイムアウト（BrokenPipe / ConnectionReset / socket.timeout）
            pass
        finally:
            upstream.close()
            with viewers_lock:
                viewers -= 1
            dt = max(time.time() - t0, 0.001)
            log(f"close service={parts[1]} {dt:.0f}s {sent * 8 / dt / 1e6:.2f} Mbps viewers={viewers}")


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    log(f"listening on {HOST}:{PORT}  mirakurun={MIRAKURUN}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
