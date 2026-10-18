#!/usr/bin/env python3
"""Pull ARIB (STD-B24) closed captions out of a recorded TS as plain text, without ffmpeg.

Why: the box's ffmpeg may not have an ARIB caption decoder, and we only want the words (for search), not the
layout. Decoding happens on the caption PID only, which is a tiny part of the file: the file is read in large
chunks and caption packets are found with a regex (C speed), so the cost is roughly one sequential read of the
file at idle IO priority, and almost no CPU.

    extract(path, progress=None) -> {"start": first PTS (s), "duration": s, "captions": [[t, text], ...]}

t is seconds from the start of the file on the same timeline the app uses (PTS - the first audio/video PTS).
"""
import json
import os
import re
import sys
import unicodedata

_T = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "arib_tables.json"), encoding="utf-8"))
GAIJI, HIRA, KATA = _T["gaiji"], _T["hiragana"], _T["katakana"]

PKT = 188
WRAP = 1 << 33

# character sets (the "F" byte of the designation) -------------------------------------------------------------
KANJI, ALNUM, HIRAGANA, KATAKANA, JKATA, MACRO, ADDSYM, JIS1, JIS2, OTHER1, OTHER2 = range(11)
# 0x36/0x37/0x38 = proportional 英数 / ひらがな / カタカナ
ONE_BYTE = {0x4A: ALNUM, 0x30: HIRAGANA, 0x31: KATAKANA, 0x36: ALNUM, 0x37: HIRAGANA, 0x38: KATAKANA, 0x49: JKATA,
            0x32: OTHER1, 0x33: OTHER1, 0x34: OTHER1, 0x35: OTHER1}
# 0x39 = JIS 互換漢字 1 面（JIS X 0213 の 1 面）、0x3A = 2 面（文字にしない）、0x3B = 追加記号
TWO_BYTE = {0x42: KANJI, 0x39: JIS1, 0x3A: JIS2, 0x3B: ADDSYM}
WIDTH = {KANJI: 2, JIS1: 2, JIS2: 2, ADDSYM: 2, OTHER2: 2}

# default macros 0x60-0x6F (ARIB STD-B24 vol.1 part 2, table 7-?): only the designations matter for text
def _m(*b):
    return bytes(b)
_ESC = 0x1B
DEFAULT_MACROS = {
    0x60: _m(_ESC, 0x24, 0x42, _ESC, 0x29, 0x4A, _ESC, 0x2A, 0x30, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x61: _m(_ESC, 0x24, 0x42, _ESC, 0x29, 0x31, _ESC, 0x2A, 0x30, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x62: _m(_ESC, 0x24, 0x42, _ESC, 0x29, 0x20, 0x41, _ESC, 0x2A, 0x30, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x63: _m(_ESC, 0x28, 0x32, _ESC, 0x29, 0x34, _ESC, 0x2A, 0x35, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x64: _m(_ESC, 0x28, 0x32, _ESC, 0x29, 0x33, _ESC, 0x2A, 0x35, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x65: _m(_ESC, 0x28, 0x32, _ESC, 0x29, 0x20, 0x41, _ESC, 0x2A, 0x35, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x66: _m(_ESC, 0x28, 0x20, 0x41, _ESC, 0x29, 0x20, 0x42, _ESC, 0x2A, 0x20, 0x43, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x67: _m(_ESC, 0x28, 0x20, 0x44, _ESC, 0x29, 0x20, 0x45, _ESC, 0x2A, 0x20, 0x46, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x68: _m(_ESC, 0x28, 0x20, 0x47, _ESC, 0x29, 0x20, 0x48, _ESC, 0x2A, 0x20, 0x49, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x69: _m(_ESC, 0x28, 0x20, 0x4A, _ESC, 0x29, 0x20, 0x4B, _ESC, 0x2A, 0x20, 0x4C, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x6A: _m(_ESC, 0x28, 0x20, 0x4D, _ESC, 0x29, 0x20, 0x4E, _ESC, 0x2A, 0x20, 0x4F, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x6B: _m(_ESC, 0x24, 0x42, _ESC, 0x29, 0x20, 0x42, _ESC, 0x2A, 0x30, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x6C: _m(_ESC, 0x24, 0x42, _ESC, 0x29, 0x20, 0x43, _ESC, 0x2A, 0x30, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x6D: _m(_ESC, 0x24, 0x42, _ESC, 0x29, 0x20, 0x44, _ESC, 0x2A, 0x30, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x6E: _m(_ESC, 0x28, 0x31, _ESC, 0x29, 0x30, _ESC, 0x2A, 0x4A, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
    0x6F: _m(_ESC, 0x28, 0x4A, _ESC, 0x29, 0x32, _ESC, 0x2A, 0x20, 0x41, _ESC, 0x2B, 0x20, 0x70, 0x0F, _ESC, 0x7D),
}
# C1 controls followed by a fixed number of parameter bytes
C1_PARAMS = {0x8B: 1, 0x91: 1, 0x93: 1, 0x94: 1, 0x97: 1}
DRCS = OTHER1  # DRCS (downloaded glyphs: logos, music notes in some stations) -> no text


class Decoder:
    """ARIB 8-unit code -> text. Keeps the code-set state for one caption statement."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.g = [KANJI, ALNUM, HIRAGANA, MACRO]   # caption initialization (ARIB TR-B14)
        self.gl, self.gr = 0, 2

    def _designate(self, n, f, two, drcs):
        if drcs:
            self.g[n] = MACRO if (f == 0x70 and not two) else (OTHER2 if two else DRCS)
        elif two:
            self.g[n] = TWO_BYTE.get(f, OTHER2)
        else:
            self.g[n] = ONE_BYTE.get(f, OTHER1)

    def _char(self, cs, b, data, i, out, depth):
        """Decode one character of set cs whose first byte (7-bit) is b. Returns the new index."""
        if WIDTH.get(cs) == 2:
            if i >= len(data):
                return i
            b2 = data[i] & 0x7F
            i += 1
            if cs in (KANJI, JIS1, ADDSYM):
                if b >= 0x75 and cs != JIS1:           # rows 85-94: ARIB additional symbols / kanji
                    k = (b - 0x75) * 94 + (b2 - 0x21)
                    ch = GAIJI[k] if 0 <= k < len(GAIJI) else ""
                    out.append(ch or "〓")
                else:
                    try:
                        out.append(bytes([b | 0x80, b2 | 0x80]).decode("euc_jis_2004"))
                    except UnicodeDecodeError:
                        out.append("〓")
            return i
        if cs == ALNUM:
            out.append(chr(b))
        elif cs == HIRAGANA:
            out.append(HIRA[b - 0x21])
        elif cs == KATAKANA:
            out.append(KATA[b - 0x21])
        elif cs == JKATA:
            out.append(chr(0xFF61 + b - 0x21) if b <= 0x5F else "")
        elif cs == MACRO and depth < 2 and b in DEFAULT_MACROS:
            out.append(self.decode(DEFAULT_MACROS[b], depth + 1))
        return i

    def decode(self, data, depth=0):
        out = []
        i, n = 0, len(data)
        repeat = 0
        while i < n:
            b = data[i]
            i += 1
            if repeat and (0x21 <= b <= 0x7E or 0xA1 <= b <= 0xFE or b in (0x20, 0xA0)):
                before = len(out)
                i0 = i
                if b in (0x20, 0xA0):
                    out.append(" ")
                else:
                    i = self._char(self.g[self.gl if b < 0x80 else self.gr], b & 0x7F, data, i, out, depth)
                ch = "".join(out[before:])
                out.extend([ch] * (min(repeat, 40) - 1))
                repeat = 0
                continue
            if 0x21 <= b <= 0x7E:
                i = self._char(self.g[self.gl], b, data, i, out, depth)
            elif 0xA1 <= b <= 0xFE:
                i = self._char(self.g[self.gr], b & 0x7F, data, i, out, depth)
            elif b in (0x20, 0xA0):
                out.append(" ")
            elif b == 0x0D:                            # APR (new line)
                out.append("\n")
            elif b == 0x0C:                            # CS (clear screen)
                out.append("\f")
            elif b == 0x0E:
                self.gl = 1
            elif b == 0x0F:
                self.gl = 0
            elif b in (0x19, 0x1D):                    # SS2 / SS3: one character from G2 / G3
                if i < n:
                    c = data[i] & 0x7F
                    i = self._char(self.g[2 if b == 0x19 else 3], c, data, i + 1, out, depth)
            elif b == 0x16:                            # PAPF
                i += 1
            elif b == 0x1C:                            # APS (move cursor): a jump to a new row reads as a space
                i += 2
                out.append("\n")
            elif b == 0x1B and i < n:                  # ESC
                e = data[i]
                i += 1
                if e == 0x6E:
                    self.gl = 2
                elif e == 0x6F:
                    self.gl = 3
                elif e == 0x7E:
                    self.gr = 1
                elif e == 0x7D:
                    self.gr = 2
                elif e == 0x7C:
                    self.gr = 3
                elif 0x28 <= e <= 0x2B and i < n:      # 1-byte set into G0..G3
                    f = data[i]
                    i += 1
                    if f == 0x20 and i < n:
                        f = data[i]
                        i += 1
                        self._designate(e - 0x28, f, False, True)
                    else:
                        self._designate(e - 0x28, f, False, False)
                elif e == 0x24 and i < n:              # 2-byte set
                    f = data[i]
                    i += 1
                    if 0x28 <= f <= 0x2B and i < n:
                        gn = f - 0x28
                        f = data[i]
                        i += 1
                        if f == 0x20 and i < n:
                            f = data[i]
                            i += 1
                            self._designate(gn, f, True, True)
                        else:
                            self._designate(gn, f, True, False)
                    else:
                        self._designate(0, f, True, False)
            elif b in C1_PARAMS:
                i += C1_PARAMS[b]
            elif b in (0x90, 0x92):                    # COL / CDC: 1 parameter, 2 if the first is 0x20
                if i < n and data[i] == 0x20:
                    i += 1
                i += 1
            elif b == 0x98:                            # RPC: repeat the next character (0x40 = to end of line -> once)
                if i < n:
                    repeat = max(data[i] - 0x40, 1)
                i += 1
            elif b == 0x95:                            # MACRO definition: skip to "MACRO 0x4F"
                end = data.find(b"\x95\x4f", i)
                i = n if end < 0 else end + 2
            elif b == 0x9B:                            # CSI ... 0x20 F
                while i < n and not (data[i - 1] == 0x20 and 0x40 <= data[i] <= 0x6F):
                    i += 1
                i += 1
            elif b == 0x9D:                            # TIME
                if i < n and data[i] == 0x20:
                    i += 2
                else:
                    while i < n and not (0x40 <= data[i] <= 0x43):
                        i += 1
                    i += 1
            # everything else (colours, sizes, BEL, ...) has no parameters and no text
        return "".join(out)


def clean(text):
    """Caption text -> one searchable line: full-width alnum to half-width (NFKC), screens/lines to spaces."""
    t = unicodedata.normalize("NFKC", text.replace("\f", " ").replace("\n", " "))
    return re.sub(r"\s+", " ", t).strip()


def _pts(p):
    return (((p[0] >> 1) & 0x07) << 30) | (p[1] << 22) | ((p[2] >> 1) << 15) | (p[3] << 7) | (p[4] >> 1)


def _caption_statement(pes, dec):
    """PES payload (synchronized PES data) -> text of the first-language caption statement, or None."""
    if len(pes) < 3 or pes[0] != 0x80 or pes[1] != 0xFF:
        return None
    p = 3 + (pes[2] & 0x0F)
    if p + 5 > len(pes):
        return None
    group_id = pes[p] >> 2
    size = (pes[p + 3] << 8) | pes[p + 4]
    body = pes[p + 5:p + 5 + size]
    if (group_id & 0x0F) != 1:                         # 0 = management, 1 = first language, 2.. = others
        return None
    if not body:
        return None
    tmd = body[0] >> 6
    q = 1 + (5 if tmd in (1, 2) else 0)
    if q + 3 > len(body):
        return None
    loop = (body[q] << 16) | (body[q + 1] << 8) | body[q + 2]
    q += 3
    end = min(q + loop, len(body))
    dec.reset()
    texts = []
    while q + 5 <= end:
        if body[q] != 0x1F:
            break
        param = body[q + 1]
        usize = (body[q + 2] << 16) | (body[q + 3] << 8) | body[q + 4]
        unit = body[q + 5:q + 5 + usize]
        q += 5 + usize
        if param == 0x20:                              # statement body (0x30/0x31 = DRCS glyph data)
            texts.append(dec.decode(bytes(unit)))
    return "".join(texts)


def _scan_head(f, limit=24 * 1024 * 1024):
    """Find the caption PID and the first audio/video PTS from the head of the file."""
    data = f.read(limit)
    sync = data.find(b"\x47")
    while sync >= 0 and sync + PKT * 2 < len(data) and not (data[sync + PKT] == 0x47 and data[sync + 2 * PKT] == 0x47):
        sync = data.find(b"\x47", sync + 1)
    if sync < 0:
        return None
    pmt_pid = None
    caption_pid, av = None, set()
    audio_pid = None
    sections = {}
    first_pts = {}
    for off in range(sync, len(data) - PKT + 1, PKT):
        pkt = data[off:off + PKT]
        if pkt[0] != 0x47:
            continue
        pid = ((pkt[1] & 0x1F) << 8) | pkt[2]
        pusi = pkt[1] & 0x40
        afc = (pkt[3] >> 4) & 3
        p = 4
        if afc in (2, 3):
            p += 1 + pkt[4]
        if afc == 2 or p >= PKT:
            continue
        payload = pkt[p:]
        if pid == 0 or pid == pmt_pid:
            if pusi:
                payload = payload[1 + payload[0]:]
                sections[pid] = payload
            elif pid in sections:
                sections[pid] += payload
            sec = sections.get(pid, b"")
            if len(sec) < 3:
                continue
            slen = ((sec[1] & 0x0F) << 8) | sec[2]
            if len(sec) < 3 + slen:
                continue
            sec = sec[:3 + slen]
            sections.pop(pid, None)
            if pid == 0 and sec[0] == 0x00 and pmt_pid is None:
                for k in range(8, 3 + slen - 4, 4):
                    prog = (sec[k] << 8) | sec[k + 1]
                    if prog != 0:
                        pmt_pid = ((sec[k + 2] & 0x1F) << 8) | sec[k + 3]
                        break
            elif pid == pmt_pid and sec[0] == 0x02 and caption_pid is None and not av:
                pil = ((sec[10] & 0x0F) << 8) | sec[11]
                k = 12 + pil
                best = None
                while k + 5 <= 3 + slen - 4:
                    st = sec[k]
                    epid = ((sec[k + 1] & 0x1F) << 8) | sec[k + 2]
                    eil = ((sec[k + 3] & 0x0F) << 8) | sec[k + 4]
                    desc = sec[k + 5:k + 5 + eil]
                    k += 5 + eil
                    if st in (0x01, 0x02, 0x1B, 0x24, 0x0F, 0x11, 0x03, 0x04):
                        av.add(epid)
                        if st in (0x0F, 0x11, 0x03, 0x04) and audio_pid is None:
                            audio_pid = epid           # 最初の音声（主音声）
                    elif st == 0x06:
                        d = 0
                        while d + 2 <= len(desc):
                            tag, ln = desc[d], desc[d + 1]
                            if tag == 0x52 and ln >= 1:
                                ct = desc[d + 2]
                                if ct == 0x30 or (best is None and 0x30 <= ct <= 0x37) or (best is None and ct == 0x87):
                                    if best is None or ct == 0x30:
                                        best = epid
                            d += 2 + ln
                caption_pid = best
            continue
        if pid in av and pusi and pid not in first_pts and len(payload) >= 14 and payload[:3] == b"\x00\x00\x01":
            if payload[7] & 0x80:
                first_pts[pid] = _pts(payload[9:14])
        if pmt_pid is not None and av and len(first_pts) == len(av):
            break
    if not av:
        return None
    start = None
    if first_pts:
        # 33 ビットの折り返しをまたいでも、いちばん早い PTS を選ぶ（どれか 1 つを基準にした差で比べる）
        ref = next(iter(first_pts.values()))
        start = min(first_pts.values(), key=lambda p: ((p - ref + WRAP // 2) % WRAP) - WRAP // 2)
    return {"sync": sync, "caption_pid": caption_pid, "start": start, "pmt_pid": pmt_pid,
            "audio_pid": audio_pid, "audio_first_pts": first_pts.get(audio_pid)}


_MASK_PID_HI = bytes(v & 0x1F for v in range(256))


def _find_packets(data, n, pids):
    """先頭からパケット単位に並んだ data の、PID が pids のどれかであるパケットの番号（昇順）。

    パケットごとに Python で回すと遅いので、各パケットの 2・3 バイト目だけを抜き出した列（C の速さ）の中で
    PID の下位バイトを bytes.find で探し、上位ビットが合うものだけ拾う。目的の PID は全体の数 % なので速い"""
    hi_col = data[1:n * PKT:PKT].translate(_MASK_PID_HI)
    lo_col = data[2:n * PKT:PKT]
    hits = []
    for pid in pids:
        hi, lo = pid >> 8, bytes([pid & 0xFF])
        i = lo_col.find(lo)
        while i >= 0:
            if hi_col[i] == hi:
                hits.append(i)
            i = lo_col.find(lo, i + 1)
    hits.sort()
    return hits


def extract(path, progress=None):
    """字幕だけ取り出す"""
    return scan(path, captions=True, progress=progress)


def scan(path, captions=True, audio_sink=None, progress=None):
    """ファイルを 1 回だけ読んで、字幕の文字と（audio_sink があれば）音声だけの TS を同時に取り出す。

    audio_sink(bytes): PAT・PMT・主音声のパケットだけを並べた小さな TS（録画の 2% ほど）。CM 検出の ffmpeg に流す。
    映像を含む数 GB を ffmpeg に読ませずに済み、字幕と CM 検出でファイルを 2 回読むことも無くなる"""
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        head = _scan_head(f)
        if not head:
            raise RuntimeError("not a TS or no PMT")
        sync, cpid, start = head["sync"], head["caption_pid"], head["start"]
        out = []
        kinds = {}
        if captions and cpid is not None:
            kinds[cpid] = "cap"
        if audio_sink and head["audio_pid"] is not None and head["pmt_pid"] is not None:
            kinds[0] = kinds[head["pmt_pid"]] = "psi"
            kinds[head["audio_pid"]] = "aud"
        result = {"start": start, "captions": out, "caption_pid": cpid if captions else None,
                  "audio_pid": head["audio_pid"], "audio_first_pts": head["audio_first_pts"]}
        if not kinds:
            return result
        f.seek(sync)
        dec = Decoder()
        st = {"pes": None, "pts": None, "last_t": 0.0}

        def handle(data, n):
            """data の先頭から n パケット（同期が取れている範囲）を処理する"""
            audio = []
            for i in _find_packets(data, n, kinds):
                off = i * PKT
                pkt = data[off:off + PKT]
                if pkt[1] & 0x80:                      # 壊れたパケット（transport_error）は使わない
                    continue
                kind = kinds.get(((pkt[1] & 0x1F) << 8) | pkt[2])
                if kind != "cap":
                    audio.append(pkt)
                    continue
                afc = (pkt[3] >> 4) & 3
                p = 4
                if afc in (2, 3):
                    p += 1 + pkt[4]
                if afc == 2 or p >= PKT:
                    continue
                payload = pkt[p:]
                if pkt[1] & 0x40:                      # start of a new PES: finish the previous one
                    if st["pes"] is not None:
                        st["last_t"] = _emit(st["pes"], st["pts"], start, dec, out, st["last_t"])
                    st["pes"], st["pts"] = None, None
                    if payload[:3] == b"\x00\x00\x01" and len(payload) >= 9:
                        hlen = payload[8]
                        if payload[7] & 0x80 and len(payload) >= 14:
                            st["pts"] = _pts(payload[9:14])
                        st["pes"] = bytearray(payload[9 + hlen:])
                elif st["pes"] is not None:
                    st["pes"] += payload
            if audio:
                audio_sink(b"".join(audio))

        pos = sync
        chunk_size = PKT * 21845                       # ~4 MB, a whole number of packets
        tail = b""
        eof = False
        while not eof:
            chunk = f.read(chunk_size)
            eof = not chunk
            data = tail + chunk                        # 先頭はいつもパケットの頭（同期を取り直した位置）
            usable = len(data) - (len(data) % PKT)
            n = usable // PKT
            heads = data[0:usable:PKT]
            if heads.count(0x47) == n:
                handle(data, n)
                tail = data[usable:]
            else:
                # 途中で 1 バイト欠けた・増えたなど、同期がずれた: ずれる前までを処理し、次の同期位置から続ける
                k = next(i for i, b in enumerate(heads) if b != 0x47)
                handle(data, k)
                j = k * PKT + 1
                while True:
                    j = data.find(b"\x47", j)
                    if j < 0 or j + 2 * PKT >= len(data):
                        break
                    if data[j + PKT] == 0x47 and data[j + 2 * PKT] == 0x47:
                        break
                    j += 1
                # 見つからなければ、末尾の少しだけ残して次の読み込みで探す
                tail = data[j:] if j >= 0 and j + 2 * PKT < len(data) else data[max(len(data) - 3 * PKT, k * PKT + 1):]
                if eof and len(tail) >= PKT:
                    eof = False                        # 残りにまだ処理できる分がある（もう読むものは無い）
                    if tail == data:                   # 進まないなら終わり
                        break
            pos += len(chunk)
            if progress:
                progress(min(pos / size, 0.99))
        if st["pes"] is not None:
            _emit(st["pes"], st["pts"], start, dec, out, st["last_t"])
    return result


def _emit(pes, pts, start, dec, out, last_t):
    text = _caption_statement(pes, dec)
    if pts is not None and start is not None:
        t = ((pts - start) % WRAP) / 90000.0
        if t > 12 * 3600:                              # caption a little before the first audio/video PTS
            t = 0.0
    else:
        t = last_t
    if text:
        line = clean(text)
        if line and not (out and out[-1][1] == line):
            out.append([round(t, 2), line])
    return t


if __name__ == "__main__":
    r = extract(sys.argv[1], progress=None)
    print(f"caption pid: {r['caption_pid']}  lines: {len(r['captions'])}", file=sys.stderr)
    for t, line in r["captions"]:
        print(f"{int(t // 60):3d}:{t % 60:05.2f}  {line}")
