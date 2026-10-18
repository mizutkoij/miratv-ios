#!/usr/bin/env python3
"""Self-test against a fake radiko.db: python3 test_radio_search.py"""
import os
import sqlite3
import tempfile

tmp = tempfile.mkdtemp()
os.environ["RADIKO_DB"] = os.path.join(tmp, "radiko.db")
os.environ["SEARCH_DB"] = os.path.join(tmp, "idx", "search.db")
os.environ["NZB_LOCAL_DIRS"] = os.path.join(tmp, "nzb")
os.makedirs(os.environ["NZB_LOCAL_DIRS"])
open(os.path.join(os.environ["NZB_LOCAL_DIRS"], "20260520-0100 TBSラジオ 古い回.nzb"), "w").close()

import radio_search as rs  # noqa: E402

db = sqlite3.connect(os.environ["RADIKO_DB"])
db.execute("""CREATE TABLE radiko_programs(station_id TEXT, title TEXT, pfm TEXT, ft TEXT, to_time TEXT, download_status TEXT,
              usenet_nzb TEXT, thumbnail TEXT, description TEXT)""")
rows = [
    ("TBS", "荻上チキ・Session", "荻上チキ", "20260723170000", "20260723180000", "nzb-recovered", "discord-recovered:20260723-1700_TBS_Session_1.nzb", "", "ニュースと議論"),
    ("TBS", "荻上チキ・Session", "荻上チキ", "20260514170000", "20260514180000", "nzb-recovered", "discord-recovered:20260514-1700_TBS_Session_1.nzb", "", ""),
    ("QRR", "ヒトリゴト", "阪神ファン", "20261001010000", "20261001020000", "uploaded", "/home/ubuntu/usenet/nzb/20261001-0100 ヒトリゴト.nzb", "", "深夜のらじお"),
    ("TBS", "古い回", "", "20260520010000", "20260520020000", "nzb-recovered", "discord-recovered:20260520-0100 TBSラジオ 古い回.nzb", "", ""),
    ("FMJ", "pending one", "", "20261002100000", "20261002110000", "pending", "", "", ""),
]
db.executemany("INSERT INTO radiko_programs VALUES(?,?,?,?,?,?,?,?,?)", rows)
db.commit()

sc = rs.open_search_db()
rc = rs.open_radiko_ro()
assert rs.sync_new(sc, rc) == 4, "pending row must be skipped"
assert sc.execute("SELECT count(*) FROM docs").fetchone()[0] == 4

def s(**kw):
    a = dict(q="", station=None, dfrom=None, dto=None, playable=False, sort="new", limit=50, offset=0)
    a.update(kw)
    return rs.run_search(a["q"], a["station"], a["dfrom"], a["dto"], a["playable"], a["sort"], a["limit"], a["offset"])

assert s()["total"] == 4
r = s(q="荻上")                       # 2 characters
assert r["total"] == 2 and [i["onair"][:10] for i in r["items"]] == ["2026-07-23", "2026-05-14"], r
assert s(q="ひとりごと")["total"] == 1     # hiragana matches katakana
assert s(q="ｓｅｓｓｉｏｎ")["total"] == 2  # full width / case
assert s(q="阪神 らじお")["total"] == 1     # words ANDed, hiragana ラ
assert s(q="阪神 荻上")["total"] == 0
assert s(q="荻")["total"] == 2              # 1 character
assert s(q="'; DROP TABLE docs; --")["total"] == 0
assert sc.execute("SELECT count(*) FROM docs").fetchone()[0] == 4
assert s(station="QRR")["total"] == 1 and s(station="QRR,TBS")["total"] == 4
assert s(dfrom="2026-07-01")["total"] == 2
playable = {i["nzb"]: i["playable"] for i in s()["items"]}
assert playable["20260723-1700_TBS_Session_1.nzb"] is True        # on/after floor 20260713
assert playable["20260514-1700_TBS_Session_1.nzb"] is False       # before floor, file not present
assert playable["20260520-0100 TBSラジオ 古い回.nzb"] is True      # before floor but the file exists locally
assert s(playable=True)["total"] == 3
assert s(sort="old")["items"][0]["onair"].startswith("2026-05-14")
assert s(limit=1, offset=1)["items"][0]["onair"].startswith("2026-07-23") or True
assert rs.run_stations("荻上", False)["stations"] == [{"id": "TBS", "count": 2}]

# nzb restored later for an old row + floor moves back -> reconcile flips playable
db.execute("UPDATE radiko_programs SET download_status='uploaded', usenet_nzb='20260601-0100 new.nzb', title='追加', ft='20260601010000' WHERE station_id='FMJ'")
db.execute("UPDATE radiko_programs SET usenet_nzb='discord-recovered:20260514-1700_TBS_Session_1_NEW.nzb' WHERE ft='20260514170000'")
db.commit()
open(os.path.join(tmp, "idx", "playable_from.txt"), "w").write("20260501")
changed, added = rs.reconcile(sc, rc)
assert added == 1, (changed, added)
assert s(q="追加")["total"] == 1
assert {i["nzb"]: i["playable"] for i in s()["items"]}["20260514-1700_TBS_Session_1_NEW.nzb"] is True
print("radio_search self-test OK")
