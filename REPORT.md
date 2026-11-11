# deckcast-qwen — build & verification report

Date: 2026-11-12. Agent: Qwen4 Max Preview (via OpenCode), working alone.
Repo: https://github.com/oliynykmax/deckcast-qwen

## What was built

A command-line tool in **Odin** (dev-2026-10) that compiles a PowerPoint
Recorder deck into one finished MP4, matching the behaviour of the reference
`compile_recording.py`: strip the webcam video element from each slide, render
slides via LibreOffice → PDF → pdftoppm at 1920×1080, overlay the circle-masked
webcam at the exact position/size/crop from the slide XML, hold each slide for
exactly its clip length (optional per-slide speedup), normalise audio to about
−18 LUFS with a limiter, concatenate to H.264/AAC MP4 with faststart, and
optionally emit the slide PDF.

Odin does the zip reading/writing, slide-XML parsing/cleaning, mask generation,
process scheduling and timing (flat arrays, no per-frame object churn);
ffmpeg/LibreOffice/pdftoppm do rendering and encoding. With VAAPI the static
slide is uploaded to the GPU once per segment, the circle is composited with
`overlay_vaapi`, and `h264_vaapi` encodes — per-frame CPU work is only webcam
decode plus crop/scale/mask of the 324×324 circle.

## Full-deck time (21 slides, ~16 min, 28,891 source frames, 1080p30)

Machine: AMD Ryzen 7 8845HS (8c/16t), Radeon 780M (VAAPI), 27 GB RAM,
ffmpeg 9.0.2, LibreOffice 26.8.1.1, poppler 26.10.

**Run 1 — `--speed 1.035` (matches the reference ha8.mp4 settings): 53.1 s**

| stage | time |
|---|---|
| parse (zip + slide XML) | 0.06 s |
| extract webcam clips (400 MB, stored) | 0.15 s |
| clean deck re-zip | 0.04 s |
| render+probe (LibreOffice PDF + loudness + 21 ffprobes, parallel) | 1.98 s |
| rasterize (pdftoppm, 4 parallel chunks) | 0.80 s |
| PNG → raw YUV (21 parallel one-shots) | 0.29 s |
| masks (Odin, supersampled) | <0.01 s |
| encode (21 segments, 3 parallel VAAPI jobs) | 41.84 s |
| mux (concat copy + AAC 160k + faststart) | 7.82 s |
| **total** | **53.07 s** |

**Run 2 — default `--speed 1.0`: 57.0 s** (encode 44.80 s, mux 8.08 s,
render+probe 2.14 s, rasterize 0.84 s, yuv 0.86 s, rest <0.3 s).

Small runs: slides 1–2 in 6.4 s (VAAPI); slides 1–3 with `--encoder x264` in
11.8 s (fallback path works).

### Why not under 10 s

Measured hardware ceilings on this machine:

- `h264_vaapi` 1080p, `-bf 0`: ~640–660 fps aggregate. Three parallel sessions
  give the same aggregate as one (single VCN encode engine); `-low_power` is
  not supported for H.264 on this GPU; profile/async_depth changes don't help.
- libx264 veryfast with an optimised graph: ~400 fps aggregate (CPU-bound);
  mixing x264 + VAAPI sessions was *slower* than pure VAAPI (CPU contention).
- The reference's per-frame PNG decode + RGB→YUV + CPU overlay graph was the
  first bottleneck found (~4.6 ms/frame); converting slides to raw YUV once
  and moving overlay+encode to the GPU removed it.

28,900 frames ÷ ~660 fps ≈ **44 s of encoding is a hard floor** here, before
LibreOffice, rasterising and muxing. The 10 s goal is unreachable on this
hardware; 53 s is ~3× faster than the reference pipeline (which encodes
sequentially with libx264 medium) and ~25× faster than real time.

## Verification (what was checked, and how)

All outputs under `out/` (gitignored). Inputs in `~/Downloads` were only read.

1. **Duration / streams (ffprobe).**
   - `out/ha8.mp4` (1.035×): 930.426 s, 27,913 video packets = exactly
     `sum(round(src_frames/1.035))`; 1920×1080, 30 fps, h264 + AAC mono 48 kHz.
   - `out/ha8-speed1.mp4` (1.0×): 963.027 s, 28,891 packets = exact source
     frame sum (16:03, matching the known recording length).
   - Reference `ha8.mp4` is 930.035 s / 27,901 packets — 12 frames fewer.
     Investigation: the reference file's audio correlates only **0.19** with
     the current pptx's clips, while ours correlates **1.001** with the
     speed-adjusted source. The reference was compiled from an earlier
     recording take; our duration is exactly correct for the current input.
2. **Audio present and in sync.** Cross-correlated a 2 s output window against
   the speed-mapped source window for **all 21 slides**: best lag within
   −57…+11 ms (AAC priming/codec delay), i.e. well inside lip-sync tolerance.
   Whole-slide-1 correlation against `atempo=1.035` source: **1.001** at
   +26 ms. (An earlier ±500 ms "lag" reading was a bug in my check script's
   lag indexing, confirmed by running the same check on the known-good
   reference; fixed and re-run.)
3. **Loudness.** `ffmpeg -af ebur128=peak=true` on `out/ha8.mp4`:
   **I = −18.1 LUFS** (target −18; reference measured −18.0). Auto gain
   computed +10.6 dB — identical to the reference script's gain.
4. **Frames looked at.** Extracted and visually inspected frames at t = 5, 40,
   75 s (slides 1–2), 890 s (takeaways) and 928 s (references): correct slide
   content, webcam circle bottom-right at (1583, 743), 324 px, matching
   colours. PDF page 1 inspected: no webcam box.
5. **Quantitative frame checks.**
   - Every slide's output frame vs its pdftoppm PNG, webcam region excluded:
     RMSE 1.9–3.2 / 255 (encoder noise only).
   - Webcam circle content vs correctly cropped/scaled source frames
     (slides 1, 4, 10, 14, 21): RMSE 3.7–4.7 / 255.
   - Our slides-1–2 output vs a fresh reference-script compile at speed 1.0:
     RMSE ≈ 1.5 %, PSNR ≈ 37 dB (VAAPI qp19 vs x264 crf18 medium).
6. **Both encoder paths** exercised end-to-end (VAAPI default, x264 fallback).

## Bugs found and fixed during development

- `fmt.tprintf` allocates from Odin's **temp allocator**: results must not be
  `delete`d or stored long-term. Replaced with a heap `hprintf` everywhere
  (crashed with `free(): invalid pointer` before the fix).
- Self-closing `<a:ext cx=…/>` tags were missed by the tag scanner → webcam
  geometry parsed as 0; scanner now handles self-closing tags.
- VAAPI self-test used 64×64, below the GPU's 128×128 minimum → false fallback
  to x264; test now 256×256.
- `--check` fed the MP4 to the concat demuxer; added a proper file-loudness
  command.
- Odin has no implicit closures and no Go-style parameter grouping; code
  restructured accordingly.

## Unfinished / limitations

- **10 s goal not met** — hardware-bound (see above); 53 s achieved.
- VAAPI output is CQP qp19: ~600 kb/s vs the reference's ~330 kb/s (x264 medium
  is more efficient on static slides). Visually equivalent at inspection and
  RMSE; file is ~90 MB vs ~58 MB. `--encoder x264` trades speed for size.
- Linux-only (VAAPI, `/dev/dri`); zip64 packages rejected (not needed here);
  first video per slide only; linked (non-embedded) videos unsupported;
  assumes the reference's 16:9 1920×1080 layout.
- Whole archive is read into RAM (~400 MB for this deck).
- Mux stage (8 s) is AAC encode + faststart; not optimised further.
- No automated test suite; verification was the manual/measured checks above.

## Deliverables

- `out/ha8.mp4` — 1.035×, 15:30, −18.1 LUFS (submission-ready, matches reference settings)
- `out/ha8.pdf` — 21-page slide PDF without webcam
- `out/ha8-speed1.mp4` — default-speed verification run, 16:03
- `out/work/` — kept work dir (logs, segments, renders) for inspection
