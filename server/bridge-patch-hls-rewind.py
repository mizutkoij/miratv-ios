import re, sys, shutil, time

P = sys.argv[1]
t = open(P, encoding='utf-8').read()
if 'BEGIN hls-rewind' in t:
    print('already patched'); sys.exit(0)
shutil.copy(P, P + '.bak-hls-rewind-' + time.strftime('%Y%m%d%H%M%S'))

BLOCK = r'''
// BEGIN hls-rewind
// ?back=<seconds> on /api/services/<id>/stream for live HLS channels (J-Sports, Tora-tele).
// - If the origin playlist already lists enough segments (Tora-tele keeps ~17 h) -> ffmpeg -live_start_index -N.
// - Else if segments are numbered (J-Sports: index_<k>_<seq>.ts, the CDN keeps ~20 h) -> serve a bridge-local
//   playlist [seq-N .. origin window] (same idea as tver-rewind) and let ffmpeg catch up and follow live.
const HLS_REWIND_MAX_SEC = 20 * 3600;
const hlsRewindState = new Map();

function hlsRewindCapable(v) {
  return /^(jsports-\d+|toratele-(02|03|backnet|main))$/.test(v.vid || '');
}

function requestedBackSeconds(req) {
  try {
    const b = parseInt(new URL(req.url, 'http://localhost').searchParams.get('back') || '0', 10);
    return Number.isFinite(b) && b > 0 ? Math.min(b, HLS_REWIND_MAX_SEC) : 0;
  } catch { return 0; }
}

function hlsFetchHeaders(v) {
  const h = { 'User-Agent': 'Mozilla/5.0' };
  if (v.referer) h['Referer'] = v.referer;
  return h;
}

async function hlsMediaPlaylist(v, url) {
  const H = hlsFetchHeaders(v);
  let r = await fetch(url, { headers: H, signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error('playlist ' + r.status);
  let text = await r.text();
  let vurl = url;
  if (/#EXT-X-STREAM-INF/.test(text)) {
    const ml = text.split(/\r?\n/).map(x => x.trim());
    let best = null, bw = -1;
    for (let i = 0; i < ml.length - 1; i++) {
      if (!ml[i].startsWith('#EXT-X-STREAM-INF')) continue;
      const b = parseInt((ml[i].match(/BANDWIDTH=(\d+)/) || [])[1], 10) || 0;
      if (b > bw && ml[i + 1] && !ml[i + 1].startsWith('#')) { bw = b; best = ml[i + 1]; }
    }
    if (!best) throw new Error('no variant');
    vurl = new URL(best, url).href;
    r = await fetch(vurl, { headers: H, signal: AbortSignal.timeout(15000) });
    if (!r.ok) throw new Error('variant ' + r.status);
    text = await r.text();
  }
  return { vurl, text, pl: tverParseVariant(text) };
}

function hlsSegUrl(refUrl, refSeq, seq) {
  return refUrl.replace('_' + refSeq + '.ts', '_' + seq + '.ts');
}

async function hlsProbe(v, url) {
  for (let i = 0; i < 4; i++) {
    try {
      const r = await fetch(url, { headers: Object.assign({ Range: 'bytes=0-0' }, hlsFetchHeaders(v)), signal: AbortSignal.timeout(10000) });
      if (r.ok) return true;
    } catch (e) { /* retry */ }
    await new Promise(res => setTimeout(res, 300));
  }
  return false;
}

// Returns { liveIdx, input? } or null (no rewind possible -> play live as before).
async function hlsRewindStart(v, masterUrl, backSec, port) {
  const { vurl, pl } = await hlsMediaPlaylist(v, masterUrl);
  if (!pl.segs.length) return null;
  const avg = pl.segs.reduce((a, s) => a + s.dur, 0) / pl.segs.length || 6;
  let n = Math.ceil(backSec / avg);
  if (n <= pl.segs.length - 1) {
    console.log('  hls-rewind [' + v.vid + '] native window: -live_start_index -' + n + ' (' + Math.round(n * avg) + 's)');
    return { liveIdx: String(-n) };
  }
  const ref = pl.segs[0];
  if (!new RegExp('_' + ref.seq + '\\.ts(\\?|$)').test(ref.url)) {
    if (pl.segs.length > 2) {
      const k = pl.segs.length - 1;
      console.log('  hls-rewind [' + v.vid + '] not numbered; limited to ' + k + ' segs');
      return { liveIdx: String(-k) };
    }
    return null;
  }
  const firstSeq = ref.seq;
  let start = null;
  for (let i = 0; i < 6; i++) {
    const cand = Math.max(1, firstSeq - n);
    if (await hlsProbe(v, hlsSegUrl(ref.url, ref.seq, cand))) { start = cand; break; }
    n = Math.floor(n / 2);
    if (n < 2) break;
  }
  if (start === null || start >= firstSeq - 1) return null;
  const id = Math.random().toString(16).slice(2, 14).padEnd(12, '0');
  for (const [k, s] of hlsRewindState) if (Date.now() - s.at > 12 * 3600 * 1000) hlsRewindState.delete(k);
  hlsRewindState.set(id, { v, vurl, startSeq: start, refUrl: ref.url, refSeq: ref.seq, dur: avg, at: Date.now(), memo: null });
  console.log('  hls-rewind [' + v.vid + '] seq ' + start + ' .. ' + firstSeq + ' (' + (firstSeq - start) + ' segs, ~' + Math.round((firstSeq - start) * avg) + 's back) then live');
  return { liveIdx: '0', input: 'http://127.0.0.1:' + port + '/hls-rewind-pl/' + id + '.m3u8' };
}

async function hlsRewindPlaylist(id) {
  const st = hlsRewindState.get(id);
  if (!st) return null;
  if (st.memo && Date.now() - st.memo.at < 1500) return st.memo.text;
  const r = await fetch(st.vurl, { headers: hlsFetchHeaders(st.v), signal: AbortSignal.timeout(15000) });
  if (!r.ok) { if (st.memo) return st.memo.text; throw new Error('origin playlist ' + r.status); }
  const text = await r.text();
  const pl = tverParseVariant(text);
  const out = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:' + pl.td, '#EXT-X-MEDIA-SEQUENCE:' + st.startSeq];
  const firstSeq = pl.segs.length ? pl.segs[0].seq : st.startSeq;
  for (let n = st.startSeq; n < firstSeq; n++) out.push('#EXTINF:' + st.dur.toFixed(3) + ',', hlsSegUrl(st.refUrl, st.refSeq, n));
  for (const l of text.split(/\r?\n/)) {
    if (!l || /^#EXTM3U|^#EXT-X-VERSION|^#EXT-X-TARGETDURATION|^#EXT-X-MEDIA-SEQUENCE|^#EXT-X-ENDLIST/.test(l)) continue;
    out.push(l);
  }
  const body = out.join('\n') + '\n';
  st.memo = { at: Date.now(), text: body };
  return body;
}
// END hls-rewind
'''

m = '// END tver-rewind\n'
assert t.count(m) == 1
t = t.replace(m, m + BLOCK, 1)

old = """      // Per-channel DVR rewind (toratele 02/03/backnet: -450 = 15min back)
      if (typeof v.liveStartIndex === 'number') ffArgs.push('-live_start_index', String(v.liveStartIndex));
      ffArgs.push(
        '-i', targetUrl,"""
new = """      // Per-channel DVR rewind (toratele 02/03/backnet: -450 = 15min back)
      let liveIdx = (typeof v.liveStartIndex === 'number') ? String(v.liveStartIndex) : null;
      let inputUrl = targetUrl;
      // ?back=<seconds>: start that far behind live (see hls-rewind block)
      const backSec = requestedBackSeconds(req);
      if (backSec > 0 && hlsRewindCapable(v)) {
        try {
          const rw = await hlsRewindStart(v, targetUrl, backSec, PORT);
          if (rw) {
            liveIdx = rw.liveIdx;
            if (rw.input) { inputUrl = rw.input; ffArgs.push('-http_persistent', '0', '-seg_max_retry', '8'); }
          }
        } catch (e) {
          console.warn('  hls-rewind [' + v.vid + '] skipped: ' + e.message);
        }
      }
      if (liveIdx !== null) ffArgs.push('-live_start_index', liveIdx);
      ffArgs.push(
        '-i', inputUrl,"""
assert t.count(old) == 1
t = t.replace(old, new, 1)

old = """  const tvpl = path.match(/^\\/tver-event-pl\\/([0-9a-f]+)\\.m3u8$/);"""
new = """  const hlpl = path.match(/^\\/hls-rewind-pl\\/([0-9a-f]+)\\.m3u8$/);
  if (hlpl) {
    try {
      const body = await hlsRewindPlaylist(hlpl[1]);
      if (!body) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl', 'Cache-Control': 'no-store' });
      res.end(body);
    } catch (e) {
      if (!res.headersSent) { res.writeHead(502); res.end(); }
    }
    return;
  }
""" + old
assert t.count(old) == 1
t = t.replace(old, new, 1)
open(P, 'w', encoding='utf-8').write(t)
print('patched')
