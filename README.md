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
| `--encoder E` | `auto` (default), `vaapi`, or `x264` |
| `--jobs N` | parallel encode jobs (default 3 for VAAPI, 4 for x264) |
| `--vaapi-device P` | DRM render node (default: first `/dev/dri/renderD*`) |
| `--check` | also measure the finished file's loudness |

Runtime dependencies: `ffmpeg`/`ffprobe`, `soffice` (LibreOffice), `pdftoppm`
(poppler). VAAPI encoding additionally needs a DRM render node and a GPU with
an H.264 encode engine; without one, `auto` falls back to libx264.

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
5. **Encoding** (`src/media.odin`) — one ffmpeg per slide. Each slide PNG is
   converted to raw YUV **once**; the segment graph uploads it to the GPU
   once and loops the hardware surface, so per-frame CPU work is only webcam
   decode + crop/scale/alphamerge of the small circle. `overlay_vaapi`
   composites on the GPU and `h264_vaapi` encodes (`-bf 0`, which is ~40%
   faster on AMD VCN). Audio gets `atempo` (speed), gain, `alimiter`,
   `apad`/`atrim` to the exact segment length, mono 48 kHz. Segments are
   concatenated with stream copy and AAC 160k.

## Performance

On the test deck (21 slides, ~16 min, 28,900 source frames, 1080p30) on a
Ryzen 7 8845HS / Radeon 780M: **~53 s total**, of which ~42 s is GPU encoding
(~660 fps aggregate — the VCN engine's measured ceiling for 1080p H.264).
The 10 s stretch goal is not reachable on this hardware: encoding alone needs
28,900 / 660 ≈ 44 s. See `REPORT.md` for the full stage breakdown and the
measurements behind these numbers.

## Layout

```
src/main.odin    CLI, orchestration, stage timing
src/zip.odin     zip reader (stored+deflate) / stored writer
src/deck.odin    slide XML parsing and cleaning
src/mask.odin    supersampled ellipse mask
src/proc.odin    process scheduler, heap printf, command helpers
src/media.odin   ffmpeg/ffprobe/LibreOffice command builders
```
