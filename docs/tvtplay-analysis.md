# TvtPlay (TVTest plugin) — structure analysis and how MiraTV borrows it

Source: https://github.com/xtne6f/TvtPlay (src/TsSender.cpp 1,178 lines, BufferedFileReader.cpp, ChapterMap.cpp, CaptionAnalyzer.cpp, PsiArchiveReader.cpp). Read 2026-10-17 for the recorded-TS player.

## What TvtPlay is
It does **not decode**. `CTsSender` reads a TS file and pushes it to TVTest through a UDP/named-pipe "virtual tuner" (BonDriver_UDP / BonDriver_Pipe), pacing the output by the stream's own **PCR** (program clock reference, 45 kHz truncated to 32 bit) against a tick counter. TVTest then decodes/plays it as if it were a live channel. Seeking, pausing, speed, chapters and the seek bar all live in the sender.

## Time model (the part we reuse)
- **Position** = `(currentPCR - initialPCR) / 45` ms, wrap-aware (`DiffPcr` treats a small negative difference across the 32-bit wrap as 0).
- **initialPCR**: first PCR after `SeekToBegin()`.
- **Duration** (`Open`): seek to `fileEnd - 2 MB/s * sec` for sec = 1,2,4,8 (stop at the first that lands on valid TS), read forward to the last PCR; `duration = lastPCR - initialPCR`. No index file needed.
- **Rate** = `fileSize * 1000 / duration` bytes/s, clamped to [16 KB/s, 24 MB/s]; falls back to a supposed 2 MB/s if unknown.
- **PCR PID choice**: a PID becomes the reference after 3 PCRs while none is chosen; switches if the chosen PID is absent for 5 PCRs of another PID (up to 8 candidate PIDs). Needed because multi-service TS carries several PCR PIDs.
- **Packet unit**: detected from the first 8 KB (188/192/204/…); resync = look for `0x47` at 1 and 2 unit offsets.
- **TOT ↔ PCR** pairing gives wall-clock broadcast time of any position (used for "放送時刻" display).

## Seek (`CTsSender::Seek(int msec)`) — iterative byte jump + PCR correction
1. Flush buffers, measure current byte `pos`, `rate`.
2. Aim for a landing window of `msec - 3000` within ±3000 ms (i.e. land up to ~3 s *before* the target so the receiver has data to start with). Up to **6 iterations**: `approx = pos + rate * msec / 1000` (clamped to `[0, size - 2*rate]`), jump there, resync to the next PCR, compute the real PCR travel; if it overshot (more than half) lower `rate` to 2/3, if it barely moved raise it to 3/2.
3. Then read forward **without sending** (`ReadToPcr(false)`) until `nextMsec <= 500` ms from the target.
4. Failure → restore the previous position. Seeking past either end clamps to ~2 s before the end / the start.
`SeekToBoundary` is only used for files still being recorded (binary-searches the boundary of valid TS data).

## Pause / speed
- Pause purges the receiver's buffer (or sends `PAUSE 1/0` if the receiver supports it); resuming resets the base tick/PCR pair and restores a 500 ms initial store.
- Speed is a numerator/denominator applied to the PCR-vs-tick pacing (`SetSpeed(num, den)`); the initial store shrinks with speed. Audio pitch correction is a separate DirectShow filter (`TvtAudioStretchFilter`).

## Other features (not needed now)
Chapters (`ChapterMap`, `.chapter` files, CM skip), playlists, `ReadOnlyMpeg4File` (mp4 with time-based seek), file-being-recorded "following" mode (`FILE_ST_*EXTENDING`), timestamp shifting (`CTsTimestampShifter`) to avoid PCR/PTS wrap, caption analysis for skip points.

## How MiraTV maps it (we DO decode, so pacing differs)
| TvtPlay | MiraTV (FFmpeg + AVSampleBuffer*) |
|---|---|
| PCR pacing against a tick counter | not needed: frames carry PTS and `AVSampleBufferRenderSynchronizer` is the clock; `PlayerEngine.throttle` keeps decode <= 2 s ahead (replaces the sender's pacing/backpressure) |
| position from PCR | position = `synchronizer.currentTime() - startTime` (PTS of the first frame); seconds |
| duration from last PCR | `AVFormatContext.duration` (libavformat estimates it from the tail of a seekable HTTP file); fallback = EPGStation `endAt - startAt` |
| rate = size/duration | same, from `avio_size(pb)` and duration |
| iterative byte-jump seek, 6 loops, +-3 s window | same algorithm via `av_seek_frame(AVSEEK_FLAG_BYTE)` over HTTP Range; measure by the PTS of the next packet instead of the PCR |
| read-forward without sending to the exact spot | decode from the landing point and drop frames with PTS < target |
| PURGE the receiver | flush both sample-buffer renderers, decoders, filter graph and resampler; restart the clock on the first audio PTS |
| speed num/den + stretch filter | `synchronizer.rate` + `AVSampleBufferAudioRenderer.audioTimePitchAlgorithm` |
| SeekToEnd = 2 s before the end | same clamp |
