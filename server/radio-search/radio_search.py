#!/usr/bin/env python3
"""radio-search: fast archive search for the radio programs in radiko.db (VPS2), for MiraTV.

Why: radiko.db holds ~550k program rows. The existing radio-web search is `LIKE '%kw%'` (about 1 s, 60 rows, no paging) and the
phone cannot hold the whole catalog. This service keeps its own sidecar SQLite (read-only on radiko.db) with an FTS5 index over
character-split text, so any query length works (1-2 character Japanese words too, which FTS5's trigram tokenizer cannot match),
and answers small paged queries.

  GET /search?q=&station=A,B&from=YYYY-MM-DD&to=YYYY-MM-DD&playable=1&sort=new|old&limit=50&offset=0
      -> {"ready":bool,"total":n,"totalCapped":bool,"items":[{"id","nzb","station","title","pfm","onair","minutes","playable","thumbnail"}]}
  GET /stations?q=&playable=1       -> {"stations":[{"id","count"}]}   (counts over the first 20000 matches)
  GET /health

Only programs that radio-web would offer as archives are indexed: download_status in (uploaded, nzb-recovered) and a non-empty
usenet_nzb (a "discord-recovered:" prefix is stripped, same as radio-web). `playable` = the nzb file is present in a local nzb
directory, or the program is on/after the playable-from date (file `playable_from.txt` next to the DB, default 2026-07-13: the nzb
files from before that date were lost with the old VPS1 and are being restored).
Bound to the Tailscale address only, no auth, nothing is ever written to radiko.db.
"""
import json
import os
import sqlite3
import sys
import threading
import time
import unicodedata
import urllib.parse
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RADIKO_DB = os.environ.get("RADIKO_DB", "/home/ubuntu/radiko-timefree/cli/radiko.db")
SEARCH_DB = os.environ.get("SEARCH_DB", "/home/ubuntu/radio-search/search.db")
NZB_LOCAL_DIRS = [d for d in os.environ.get("NZB_LOCAL_DIRS", "/home/ubuntu/usenet/nzb").split(":") if d]
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8091"))
SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "300"))        # new rows
RECONCILE_INTERVAL = int(os.environ.get("RECONCILE_INTERVAL", "3600"))  # nzb / status / playable of old rows
DEFAULT_PLAYABLE_FROM = os.environ.get("PLAYABLE_FROM", "20260713")
BATCH = 5000
JST = timezone(timedelta(hours=9))
ARCHIVE_STATUSES = ("uploaded", "nzb-recovered")

_HIRA_TO_KATA = {c: c + 0x60 for c in range(0x3041, 0x3097)}
state = {"ready": False, "last_sync": 0.0, "last_reconcile": 0.0, "rows": 0, "error": ""}
state_lock = threading.Lock()


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ---------- text normalisation ----------

def normalize(s):
    """NFKC, lower case, hiragana -> katakana (so 'ひらがな' and 'ヒラガナ' match)."""
    return unicodedata.normalize("NFKC", s or "").lower().translate(_HIRA_TO_KATA)


def split_chars(s):
    """'荻上チキ Session' -> '荻 上 チ キ s e s s i o n'. Non letter/digit characters act as word breaks."""
    out = []
    for ch in normalize(s):
        out.append(ch if ch.isalnum() else " ")
    text = "".join(out)
    return " ".join(" ".join(w) for w in text.split())


def fts_query(q):
    """User words -> FTS5 expression: every space separated word becomes a phrase of single characters, ANDed."""
    phrases = []
    for word in normalize(q).split():
        chars = [c for c in word if c.isalnum()]
        if chars:
            phrases.append('"' + " ".join(chars) + '"')
    return " AND ".join(phrases[:8])


# ---------- sidecar database ----------

def open_search_db():
    os.makedirs(os.path.dirname(SEARCH_DB), exist_ok=True)
    c = sqlite3.connect(f"file:{SEARCH_DB}?mode=rwc", uri=True, timeout=60)
    c.create_function("basename", 1, lambda p: os.path.basename(p or ""), deterministic=True)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA synchronous=NORMAL")
    c.executescript("""
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS docs(
            id INTEGER PRIMARY KEY, station TEXT, ft TEXT, onair INTEGER, minutes INTEGER,
            title TEXT, pfm TEXT, nzb TEXT, playable INTEGER, thumb TEXT);
        CREATE INDEX IF NOT EXISTS docs_ft ON docs(ft);
        CREATE INDEX IF NOT EXISTS docs_station_ft ON docs(station, ft);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(body, tokenize='unicode61 remove_diacritics 0');
    """)
    return c


def open_radiko_ro():
    return sqlite3.connect(f"file:{RADIKO_DB}?mode=ro", uri=True, timeout=60)


def meta_get(c, k, default=None):
    r = c.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return r[0] if r else default


def meta_set(c, k, v):
    c.execute("INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))


def strip_nzb(val):
    val = val or ""
    return val[len("discord-recovered:"):] if val.startswith("discord-recovered:") else val


def ft_epoch(ft):
    try:
        return int(datetime.strptime(ft, "%Y%m%d%H%M%S").replace(tzinfo=JST).timestamp())
    except Exception:
        return 0


def playable_from():
    p = os.path.join(os.path.dirname(SEARCH_DB), "playable_from.txt")
    try:
        with open(p, encoding="utf-8") as f:
            v = f.read().strip()
        if len(v) == 8 and v.isdigit():
            return v
    except OSError:
        pass
    return DEFAULT_PLAYABLE_FROM


def local_nzb_names():
    names = set()
    for d in NZB_LOCAL_DIRS:
        try:
            names.update(os.listdir(d))
        except OSError:
            pass
    return names


def is_playable(nzb, ft, local, floor):
    if not nzb:
        return 0
    base = os.path.basename(nzb)
    if base in local:
        return 1
    return 1 if ft[:8] >= floor else 0


ROW_SQL = ("SELECT rowid, station_id, title, pfm, ft, to_time, usenet_nzb, thumbnail, description, download_status "
           "FROM radiko_programs WHERE rowid > ? AND download_status IN ('uploaded','nzb-recovered') "
           "AND usenet_nzb != '' ORDER BY rowid LIMIT ?")


def minutes_between(ft, to):
    try:
        a = datetime.strptime(ft, "%Y%m%d%H%M%S")
        b = datetime.strptime(to, "%Y%m%d%H%M%S")
        return max(int((b - a).total_seconds() // 60), 0)
    except Exception:
        return 0


def sync_new(sc, rc):
    """Append rows with rowid > last seen (new programs). Returns how many were added."""
    last = int(meta_get(sc, "last_rowid", 0))
    local, floor = local_nzb_names(), playable_from()
    added = 0
    while True:
        rows = rc.execute(ROW_SQL, (last, BATCH)).fetchall()
        if not rows:
            break
        docs, fts = [], []
        for rid, station, title, pfm, ft, to, nzb, thumb, desc, _st in rows:
            ft = ft or ""
            n = strip_nzb(nzb)
            docs.append((rid, station, ft, ft_epoch(ft), minutes_between(ft, to or ""), title or "", pfm or "", n,
                         is_playable(n, ft, local, floor), thumb or ""))
            fts.append((rid, split_chars(f"{title or ''} {pfm or ''} {(desc or '')[:200]}")))
            last = rid
        sc.executemany("INSERT OR REPLACE INTO docs VALUES(?,?,?,?,?,?,?,?,?,?)", docs)
        sc.executemany("INSERT OR REPLACE INTO fts(rowid, body) VALUES(?,?)", fts)
        meta_set(sc, "last_rowid", last)
        sc.commit()
        added += len(rows)
        with state_lock:
            state["rows"] = sc.execute("SELECT count(*) FROM docs").fetchone()[0]
        time.sleep(0.05)   # stay polite on a small box
    return added


PLAY_EXPR = ("CASE WHEN nzb = '' THEN 0 WHEN basename(nzb) IN (SELECT name FROM temp.local_names) THEN 1 "
             "WHEN substr(ft, 1, 8) >= ? THEN 1 ELSE 0 END")


def reconcile(sc, rc):
    """Old rows change later (pending -> uploaded, nzb restored, files appear): refresh nzb + playable, add missing rows.
    Set-based inside SQLite (radiko.db attached read-only) so the Python process never holds 550k rows in memory."""
    floor = playable_from()
    sc.execute("CREATE TEMP TABLE IF NOT EXISTS local_names(name TEXT PRIMARY KEY)")
    sc.execute("DELETE FROM temp.local_names")
    sc.executemany("INSERT OR IGNORE INTO temp.local_names VALUES(?)", ((n,) for n in local_nzb_names()))
    sc.execute("ATTACH DATABASE ? AS r", (f"file:{RADIKO_DB}?mode=ro",))
    try:
        before = sc.total_changes
        nzb_expr = ("(SELECT CASE WHEN p.usenet_nzb LIKE 'discord-recovered:%' THEN substr(p.usenet_nzb, 19) ELSE p.usenet_nzb END "
                    "FROM r.radiko_programs p WHERE p.rowid = docs.id)")
        sc.execute(f"UPDATE docs SET nzb = {nzb_expr} WHERE nzb != {nzb_expr} AND {nzb_expr} IS NOT NULL AND {nzb_expr} != ''")
        sc.execute(f"UPDATE docs SET playable = {PLAY_EXPR} WHERE playable != {PLAY_EXPR}", (floor, floor))
        changed = sc.total_changes - before
        sc.commit()
        missing = [r[0] for r in sc.execute(
            "SELECT p.rowid FROM r.radiko_programs p WHERE p.download_status IN ('uploaded','nzb-recovered') "
            "AND p.usenet_nzb != '' AND p.rowid NOT IN (SELECT id FROM docs)")]
    finally:
        sc.execute("DETACH DATABASE r")
    added = 0
    local = local_nzb_names()
    for i in range(0, len(missing), 1000):
        ids = missing[i:i + 1000]
        q = ("SELECT rowid, station_id, title, pfm, ft, to_time, usenet_nzb, thumbnail, description, download_status "
             "FROM radiko_programs WHERE rowid IN (" + ",".join("?" * len(ids)) + ")")
        docs, fts = [], []
        for rid, station, title, pfm, ft, to, nzb, thumb, desc, _st in rc.execute(q, ids):
            ft = ft or ""
            n = strip_nzb(nzb)
            docs.append((rid, station, ft, ft_epoch(ft), minutes_between(ft, to or ""), title or "", pfm or "", n,
                         is_playable(n, ft, local, floor), thumb or ""))
            fts.append((rid, split_chars(f"{title or ''} {pfm or ''} {(desc or '')[:200]}")))
        sc.executemany("INSERT OR REPLACE INTO docs VALUES(?,?,?,?,?,?,?,?,?,?)", docs)
        sc.executemany("INSERT OR REPLACE INTO fts(rowid, body) VALUES(?,?)", fts)
        added += len(docs)
    sc.commit()
    return changed, added


def sync_loop():
    try:
        os.nice(10)
    except OSError:
        pass
    sc = open_search_db()
    first = True
    while True:
        try:
            rc = open_radiko_ro()
            try:
                t0 = time.time()
                n = sync_new(sc, rc)
                with state_lock:
                    state["last_sync"] = time.time()
                    state["error"] = ""
                if n or first:
                    log(f"sync: +{n} rows in {time.time() - t0:.1f}s (total {state['rows']})")
                if time.time() - state["last_reconcile"] > RECONCILE_INTERVAL:
                    t0 = time.time()
                    changed, missing = reconcile(sc, rc)
                    with state_lock:
                        state["last_reconcile"] = time.time()
                    log(f"reconcile: {changed} changed, {missing} missing added in {time.time() - t0:.1f}s")
                with state_lock:
                    state["ready"] = True
                first = False
            finally:
                rc.close()
        except Exception as e:  # noqa: BLE001
            with state_lock:
                state["error"] = str(e)
            log("sync failed:", e)
        time.sleep(SYNC_INTERVAL)


# ---------- queries ----------

def where_clause(station, dfrom, dto, playable):
    conds, args = [], []
    if station:
        sts = [s for s in station.split(",") if s][:30]
        conds.append("d.station IN (" + ",".join("?" * len(sts)) + ")")
        args += sts
    if dfrom and len(dfrom) == 10:
        conds.append("d.ft >= ?")
        args.append(dfrom.replace("-", "") + "000000")
    if dto and len(dto) == 10:
        conds.append("d.ft <= ?")
        args.append(dto.replace("-", "") + "235959")
    if playable:
        conds.append("d.playable = 1")
    return conds, args


def run_search(q, station, dfrom, dto, playable, sort, limit, offset):
    c = sqlite3.connect(f"file:{SEARCH_DB}?mode=ro", uri=True, timeout=30)
    try:
        conds, args = where_clause(station, dfrom, dto, playable)
        match = fts_query(q)
        order = "d.ft ASC" if sort == "old" else "d.ft DESC"
        if match:
            frm = "fts JOIN docs d ON d.id = fts.rowid"
            conds = ["fts MATCH ?"] + conds
            args = [match] + args
        else:
            frm = "docs d"
        where = (" WHERE " + " AND ".join(conds)) if conds else ""
        cap = 10000
        total = c.execute(f"SELECT count(*) FROM (SELECT 1 FROM {frm}{where} LIMIT {cap + 1})", args).fetchone()[0]
        rows = c.execute(
            f"SELECT d.id, d.nzb, d.station, d.title, d.pfm, d.ft, d.minutes, d.playable, d.thumb FROM {frm}{where} "
            f"ORDER BY {order} LIMIT ? OFFSET ?", args + [limit, offset]).fetchall()
        items = []
        for rid, nzb, st, title, pfm, ft, minutes, play, thumb in rows:
            items.append({"id": rid, "nzb": nzb, "station": st, "title": title, "pfm": pfm,
                          "onair": f"{ft[0:4]}-{ft[4:6]}-{ft[6:8]}T{ft[8:10]}:{ft[10:12]}:{ft[12:14]}+09:00" if len(ft) >= 14 else ft,
                          "minutes": minutes, "playable": bool(play), "thumbnail": thumb or None})
        return {"total": min(total, cap), "totalCapped": total > cap, "items": items}
    finally:
        c.close()


def run_stations(q, playable):
    c = sqlite3.connect(f"file:{SEARCH_DB}?mode=ro", uri=True, timeout=30)
    try:
        conds, args = where_clause(None, None, None, playable)
        match = fts_query(q)
        if match:
            frm = "fts JOIN docs d ON d.id = fts.rowid"
            conds = ["fts MATCH ?"] + conds
            args = [match] + args
        else:
            frm = "docs d"
        where = (" WHERE " + " AND ".join(conds)) if conds else ""
        rows = c.execute(f"SELECT station, count(*) FROM (SELECT d.station FROM {frm}{where} LIMIT 20000) "
                         "GROUP BY station ORDER BY 2 DESC LIMIT 200", args).fetchall()
        return {"stations": [{"id": s, "count": n} for s, n in rows]}
    finally:
        c.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "radio-search/1"

    def log_message(self, fmt, *args):
        pass

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        try:
            if u.path == "/health":
                with state_lock:
                    st = dict(state)
                st["playableFrom"] = playable_from()
                try:
                    c = sqlite3.connect(f"file:{SEARCH_DB}?mode=ro", uri=True, timeout=5)
                    st["rows"] = c.execute("SELECT count(*) FROM docs").fetchone()[0]
                    st["playableRows"] = c.execute("SELECT count(*) FROM docs WHERE playable=1").fetchone()[0]
                    c.close()
                except sqlite3.Error:
                    pass
                return self._json(st)
            if u.path == "/search":
                limit = max(1, min(int(q.get("limit", "50") or 50), 100))
                offset = max(0, int(q.get("offset", "0") or 0))
                res = run_search(q.get("q", ""), q.get("station"), q.get("from"), q.get("to"),
                                 q.get("playable") == "1", q.get("sort", "new"), limit, offset)
                res["ready"] = state["ready"]
                return self._json(res)
            if u.path == "/stations":
                return self._json(run_stations(q.get("q", ""), q.get("playable") == "1"))
            return self._json({"error": "not found"}, 404)
        except sqlite3.OperationalError as e:
            # the index file does not exist yet (first build still running)
            return self._json({"ready": False, "total": 0, "totalCapped": False, "items": [], "error": str(e)}, 200)
        except (ValueError, TypeError) as e:
            return self._json({"error": f"bad request: {e}"}, 400)


def main():
    threading.Thread(target=sync_loop, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    log(f"listening on {HOST}:{PORT}  radiko={RADIKO_DB}  index={SEARCH_DB}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
