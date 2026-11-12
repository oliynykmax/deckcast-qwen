# deckcast-qwen

> ## ⚠️ DISCLAIMER — AI-WRITTEN CODE, NO CRAFT
>
> **This entire repository was written by an AI agent (Qwen4 Max Preview, running
> in OpenCode), autonomously, in one session. There is no human craft here: no
> hand-tuned code, no careful review, no artisanal care. It was made by agents,
> for agents.** It works because it was measured against a reference
> implementation, not because anyone loved it. Treat it as a machine artifact:
> read it, fork it, rewrite it, or throw it away. If it breaks, you get to keep
> both pieces.

`deckcast` compiles a PowerPoint deck recorded with PowerPoint's **Recorder**
(one narration/webcam clip embedded per slide) into a single finished MP4:

- slides rendered without the webcam video element (LibreOffice → PDF → PNG),
- the recorded webcam cropped, scaled and circle-masked exactly where
  PowerPoint shows it, overlaid on every slide,
- each slide held for exactly its clip's length (per-slide speedup keeps lip
  sync exact),
- audio loudness-normalised to about **−18 LUFS** with a limiter,
- everything concatenated into one H.264/AAC MP4 (faststart), plus an optional
  PDF of the slides.

It is a fast Odin port of the workflow in
`~/.agents/skills/max-oliinyk-presentation/scripts/compile_recording.py`.

## Usage

```sh
./build.sh                     # needs Odin (dev-2026-10 or later)

./deckcast ~/Downloads/HA8-Continuous-Integration.pptx \
    -o out/ha8.mp4 --pdf out/ha8.pdf --speed 1.035
```

Options:

| flag | meaning |
|---|---|
| `-o, --output PATH` | output MP4 (required) |
| `--pdf PATH` | also save the slide PDF (without webcam) |
| `--speed F` | per-slide speedup, e.g. `1.035` (default `1.0`) |
| `--gain auto\|DB` | audio gain in dB, or `auto` to hit the target (default `auto`) |
| `--target F` | auto-gain target LUFS (default `-18`) |
| `--work DIR` | work directory, kept for inspection (default `/tmp/deckcast-<pid>`) |
| `--slides LO-HI` | compile only a slide range (quick tests) |
| `--fps N` | output frame rate (default `30`, the source rate — every webcam frame is kept) |
| `--jobs N` | parallel x264 strip encoders (default `2`) |
| `--cpu-decode` | force CPU webcam decode (GPU/VAAPI decode is auto-used when available) |
| `--check` | also measure the finished file's loudness |

Runtime dependencies: `ffmpeg`/`ffprobe`, `soffice` (LibreOffice), `pdftoppm`
(poppler), and the `x264` CLI. VAAPI webcam decode additionally needs a DRM
render node; without one it falls back to CPU decode automatically.

## How it works

Odin owns everything except the pixel pushing:

1. **ZIP** (`src/zip.odin`) — the `.pptx` is read as one byte slice with a flat
   entry table. Webcam clips are stored uncompressed in PowerPoint packages,
   so extraction is a plain copy. The cleaned deck is re-zipped with stored
   entries (no media, no video shapes, no timing trees).
2. **Deck parsing** (`src/deck.odin`) — slide XML is scanned for the `p:pic`
   carrying `a:videoFile`; position/size come from `a:off`/`a:ext` (EMU →
   1920 px space), crop from `a:srcRect`, shape from `prst="ellipse"`.
   Relationship ids resolve through the slide `.rels`.
3. **Scheduling** (`src/proc.odin`) — a flat job array of external commands,
   spawned from the main thread and polled with non-blocking waits, keeping N
   children alive. Every job's stdout/stderr goes to a log file under
   `work/logs/`. LibreOffice rendering, loudness analysis and all ffprobe
   frame counts run concurrently; PDF rasterisation is split into parallel
   page ranges.
4. **Mask** (`src/mask.odin`) — the circle mask is generated directly as raw
   gray bytes with 4×4 supersampling (no ImageMagick).
5. **Composite + encode** (`src/composite.odin`, `src/encode.odin`,
   `src/h264.odin`) — the slide background is static; only the small webcam
   circle moves. Each slide PNG is converted to raw YUV once. Odin blends the
   circle-masked webcam onto a **horizontal strip** (the macroblock rows that
   contain the webcam, e.g. 1920×360) and writes only that strip — not the full
   1080p frame. `x264` encodes the strip (CAVLC, `--stitchable`), and
   `src/h264.odin` splices it into a full 1080p H.264 stream at the bitstream
   level: the static rows above the strip become P-skips, so **only the pixels
   that change are actually coded**. The output stays at the source rate
   (30 fps, every webcam frame preserved). Webcam decode, compositing and
   encoding run as an out-of-order pipeline (ready slides are processed while
   long clips still decode); the audio pass renders concurrently and is hidden
   inside the encode. The stitchable H.264 segments are byte-concatenated and
   muxed with the AAC track (stream copy, faststart).

## Performance

On the test deck (21 slides, ~16 min, 28,891 source frames, 1080p30) on a
Ryzen 7 8845HS / Radeon 780M: **~21 s total at the full 30 fps** (every webcam
frame preserved), down from ~53 s for the earlier full-frame GPU-encode
pipeline. The win comes from encoding only the pixels that change: the static
slide background is carried by P-skips and only the webcam strip is coded, so
the encoder reads/writes ~6× less pixel data. See `REPORT.md` for the stage
breakdown, the bitstream-splice design and the verification.

## Layout

```
src/main.odin      CLI, orchestration, stage timing
src/zip.odin       zip reader (stored+deflate) / stored writer
src/deck.odin      slide XML parsing and cleaning
src/mask.odin      supersampled ellipse mask
src/proc.odin      process scheduler, heap printf, command helpers
src/media.odin     ffmpeg/ffprobe/LibreOffice/x264 command builders
src/composite.odin static-background strip compositing (YUV alpha blit)
src/encode.odin    out-of-order decode/composite/encode pipeline
src/h264.odin      H.264 bitstream splice (strip -> full 1080p, P-skips)
```
