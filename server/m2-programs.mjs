// m2-programs — 2 台目の Mirakurun（korean-tv-bridge、:36196）の番組情報を、局で絞って返す小さな中継。
//
//   GET /api/programs?networkId=&serviceId=   -> その局の番組だけ（絞り込み指定なしは全局ぶん）。gzip 対応
//
// なぜ必要か: ブリッジの /api/programs は networkId / serviceId の絞り込みを守らず、どの局を頼んでも全局ぶん
// （約 14MB・3 秒強）を返す。アプリが局ごとに頼むたびにそれが飛んでくるので重かった。
// ブリッジを再起動すると録画中の番組が落ちるため、ブリッジは触らず、横に置いてここで絞る。
// 全局ぶんは 60 秒に 1 回だけ取り直して覚える（同時に取るのは 1 本）。取れなかったときは古いのを返す。
// Tailscale の IP だけで待ち受ける。
import http from 'node:http';
import zlib from 'node:zlib';

const UPSTREAM = process.env.UPSTREAM || 'http://127.0.0.1:36196';
const BIND = process.env.BIND || '100.88.12.26';
const PORT = parseInt(process.env.PORT || '36206', 10);
const TTL = 60_000;

let at = 0, raw = null, byKey = new Map(), inflight = null;

async function refresh() {
  if (inflight) return inflight;
  inflight = (async () => {
    const r = await fetch(`${UPSTREAM}/api/programs`, { signal: AbortSignal.timeout(60_000) });
    if (!r.ok) throw new Error('upstream ' + r.status);
    const text = await r.text();
    const list = JSON.parse(text);
    const m = new Map();
    for (const p of list) {
      const k = `${p.networkId}:${p.serviceId}`;
      (m.get(k) || m.set(k, []).get(k)).push(p);
    }
    raw = text; byKey = m; at = Date.now();
  })().finally(() => { inflight = null; });
  return inflight;
}

async function ensure() {
  if (raw && Date.now() - at < TTL) return;
  try { await refresh(); }
  catch (e) { if (!raw) throw e; console.warn('refresh failed, serving stale:', e.message); }
}

function send(req, res, body) {
  const h = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache', Vary: 'Accept-Encoding' };
  if (/\bgzip\b/.test(req.headers['accept-encoding'] || '')) {
    const z = zlib.gzipSync(body, { level: 4 });
    res.writeHead(200, { ...h, 'Content-Encoding': 'gzip', 'Content-Length': z.length });
    return res.end(z);
  }
  res.writeHead(200, { ...h, 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname !== '/api/programs') { res.writeHead(404); return res.end('not found'); }
  try {
    await ensure();
    const n = u.searchParams.get('networkId'), s = u.searchParams.get('serviceId');
    if (n && s) return send(req, res, JSON.stringify(byKey.get(`${n}:${s}`) || []));
    if (s || n) {
      const out = [];
      for (const [k, v] of byKey) {
        const [kn, ks] = k.split(':');
        if ((!n || kn === n) && (!s || ks === s)) out.push(...v);
      }
      return send(req, res, JSON.stringify(out));
    }
    send(req, res, raw);
  } catch (e) {
    res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end(String(e.message || e));
  }
}).listen(PORT, BIND, () => console.log(`m2-programs on ${BIND}:${PORT} -> ${UPSTREAM}`));
