#!/usr/bin/env python3
"""Live bridge for radio-web (VPS2): FMぷらぷら (Ogg) and JCBA (WebSocket + Ogg/Opus) -> MP3 over plain HTTP.

Why: iPhone's AVPlayer cannot open Ogg/Opus or a WebSocket stream, and the app has no Ogg path for live radio.
This turns both into a progressive MP3 (audio/mpeg), the same shape as an Icecast stream, which AVPlayer plays natively
(background audio and lock-screen controls included). ffmpeg does the decoding/encoding; one ffmpeg per listener,
killed as soon as the client goes away. At most MAX_STREAMS at the same time (VPS2 has 3 cores / 2.9 GB).

JCBA protocol (verified 2026-09-20, see dev/notes/snippets/2026-09-20-community-fm-capture/jcba_capture.py):
  GET https://www.jcbasimul.com/api/select_stream?station=<slug>&channel=0&quality=high&burst=5
      -> {location: wss://..., token: JWT (15 s lifetime)}
  WebSocket, subprotocol listener.fmplapla.com, Origin https://www.jcbasimul.com, first message = token,
  then binary frames of Ogg/Opus.

Stdlib + `websockets` (already installed on VPS2, only JCBA needs it).
"""
import asyncio
import json
import re
import subprocess
import threading
import time
import urllib.request

MAX_STREAMS = 4
MAX_SECONDS = 6 * 3600          # safety net: a forgotten stream cannot run forever
IDLE_SECONDS = 20               # JCBA: no audio frame for this long -> end (the app reconnects)
SLUG_RE = re.compile(r"^[A-Za-z0-9_\-]{1,64}$")

_slots = threading.BoundedSemaphore(MAX_STREAMS)

JCBA_API = "https://www.jcbasimul.com/api/select_stream"
JCBA_SUBPROTOCOL = "listener.fmplapla.com"
JCBA_ORIGIN = "https://www.jcbasimul.com"

_OUT = ["-vn", "-map", "0:a:0", "-c:a", "libmp3lame", "-b:a", "96k", "-ar", "44100", "-f", "mp3", "pipe:1"]


def valid_slug(slug):
    return bool(slug and SLUG_RE.match(slug))


def _jcba_select(slug):
    url = f"{JCBA_API}?station={slug}&channel=0&quality=high&burst=5"
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0", "Referer": f"{JCBA_ORIGIN}/{slug}/rawplayer"})
    return json.load(urllib.request.urlopen(req, timeout=15))


def _jcba_pump(slug, proc, stop, state):
    """WebSocket -> ffmpeg stdin. Runs in its own thread (own event loop)."""
    import websockets

    async def run():
        info = _jcba_select(slug)
        async with websockets.connect(info["location"], subprotocols=[JCBA_SUBPROTOCOL], origin=JCBA_ORIGIN,
                                      open_timeout=10, ping_interval=None) as ws:
            await ws.send(info["token"])
            last = time.time()
            while not stop.is_set():
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=1.0)
                except asyncio.TimeoutError:
                    if time.time() - last > IDLE_SECONDS:
                        return
                    continue
                if isinstance(msg, bytes):
                    last = time.time()
                    proc.stdin.write(msg)
                    proc.stdin.flush()

    try:
        asyncio.run(run())
    except Exception as e:  # noqa: BLE001 - any failure just ends the stream; the app retries
        state["error"] = str(e)
    finally:
        try:
            proc.stdin.close()
        except Exception:  # noqa: BLE001
            pass


def serve(handler, kind, slug, fmplapla_url=None):
    """Stream to `handler` (BaseHTTPRequestHandler) until the client leaves. kind: 'fmplapla' | 'jcba'.
    Returns an error string (before any bytes were sent) or None."""
    if not _slots.acquire(blocking=False):
        return "busy"
    proc = None
    stop = threading.Event()
    state = {}
    try:
        if kind == "fmplapla":
            cmd = ["ffmpeg", "-loglevel", "error", "-nostdin", "-rw_timeout", "15000000",
                   "-i", fmplapla_url] + _OUT
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        else:
            cmd = ["ffmpeg", "-loglevel", "error", "-fflags", "+nobuffer", "-probesize", "65536",
                   "-analyzeduration", "500000", "-f", "ogg", "-i", "pipe:0"] + _OUT
            proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            threading.Thread(target=_jcba_pump, args=(slug, proc, stop, state), daemon=True).start()

        first = proc.stdout.read(4096)      # wait for the first audio before promising 200
        if not first:
            return state.get("error") or "no audio"
        handler.send_response(200)
        handler.send_header("Content-Type", "audio/mpeg")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Connection", "close")
        handler.end_headers()
        deadline = time.time() + MAX_SECONDS
        chunk = first
        while chunk:
            handler.wfile.write(chunk)
            handler.wfile.flush()
            if time.time() > deadline:
                break
            chunk = proc.stdout.read(4096)
        return None
    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
        return None
    finally:
        stop.set()
        if proc is not None:
            try:
                proc.kill()
            except Exception:  # noqa: BLE001
                pass
            try:
                proc.wait(timeout=5)
            except Exception:  # noqa: BLE001
                pass
        _slots.release()
