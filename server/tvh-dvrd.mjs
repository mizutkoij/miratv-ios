// tvh-dvrd — TVHeadend の録画（DVR）を MiraTV に出す小さな中継。
//
//   GET /list            -> 録画済みの一覧 JSON（新しい順。中身のあるものだけ）
//   GET /file/<uuid>     -> 録画ファイル本体（Range 対応。TVH の /dvrfile/<uuid> をそのまま中継）
//
// なぜ別サービスか: korean-tv-bridge を再起動すると、録画中の番組が落ちる。ブリッジは触らずに足せるようにした。
// 認証情報は korean-tv-bridge/.env の TVH_URL（user:pass@host）を起動時に読むだけで、このファイルにもアプリにも持たない。
// Tailscale の IP だけで待ち受ける（外には出さない）。
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { Readable } from 'node:stream';

const ENV = process.env.BRIDGE_ENV || '/home/mizu/korean-tv-bridge/.env';
const BIND = process.env.BIND || '100.88.12.26';
const PORT = parseInt(process.env.PORT || '36205', 10);

const line = readFileSync(ENV, 'utf8').split('\n').find(l => l.startsWith('TVH_URL='));
if (!line) { console.error('TVH_URL not found'); process.exit(1); }
const tvh = new URL(line.slice('TVH_URL='.length).trim());
const AUTH = 'Basic ' + Buffer.from(decodeURIComponent(tvh.username) + ':' + decodeURIComponent(tvh.password)).toString('base64');
const BASE = tvh.origin;

// TVH は文字列のことも {言語: 文字列} のこともある
const str = x => typeof x === 'string' ? x : (x && typeof x === 'object' ? String(Object.values(x)[0] || '') : '');

let cache = { at: 0, body: null };
async function list() {
  if (cache.body && Date.now() - cache.at < 60_000) return cache.body;
  const r = await fetch(BASE + '/api/dvr/entry/grid?limit=2000', { headers: { Authorization: AUTH }, signal: AbortSignal.timeout(30_000) });
  if (!r.ok) throw new Error('TVH ' + r.status);
  const d = await r.json();
  const done = new Set(['completed', 'completedWarning', 'completedError']);
  const items = (d.entries || [])
    .filter(e => done.has(e.sched_status) && e.filesize > 0)
    .map(e => ({
      uuid: e.uuid,
      title: str(e.disp_title) || str(e.title),
      subtitle: str(e.disp_subtitle),
      summary: str(e.disp_summary),
      channel: e.channelname || '',
      start: e.start_real || e.start,
      stop: e.stop_real || e.stop,
      size: e.filesize,
      status: e.sched_status,
    }))
    .sort((a, b) => b.start - a.start);
  cache = { at: Date.now(), body: JSON.stringify({ total: items.length, items }) };
  return cache.body;
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  try {
    if (u.pathname === '/list') {
      const body = await list();
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache' });
      return res.end(body);
    }
    const m = u.pathname.match(/^\/file\/([0-9a-f]{32})$/);
    if (m) {
      const ctl = new AbortController();
      req.on('close', () => ctl.abort());
      const h = { Authorization: AUTH };
      if (req.headers.range) h.Range = req.headers.range;
      const up = await fetch(`${BASE}/dvrfile/${m[1]}`, { headers: h, signal: ctl.signal });
      const out = { 'Content-Type': 'video/mp2t', 'Accept-Ranges': 'bytes' };
      for (const k of ['content-length', 'content-range']) if (up.headers.get(k)) out[k] = up.headers.get(k);
      res.writeHead(up.status, out);
      if (!up.body) return res.end();
      const s = Readable.fromWeb(up.body);
      s.on('error', () => res.destroy());
      return s.pipe(res);
    }
    res.writeHead(404); res.end('not found');
  } catch (e) {
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end(String(e.message || e));
  }
});
server.listen(PORT, BIND, () => console.log(`tvh-dvrd on ${BIND}:${PORT}`));
