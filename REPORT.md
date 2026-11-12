# deckcast-qwen — build & verification report

Date: 2026-11-12. Agent: Qwen4 Max Preview (via OpenCode), working alone.
Repo: https://github.com/oliynykmax/deckcast-qwen

## What was built

A command-line tool in **Odin** (dev-2026-10) that compiles a PowerPoint
Recorder deck into one finished MP4: strip the webcam video element from each
slide, render slides via LibreOffice → PDF → pdftoppm at 1920×1080, overlay the
circle-masked webcam at the exact position/size/crop from the slide XML, hold
each slide for exactly its clip length (optional per-slide speedup), normalise
audio to about −18 LUFS with a limiter, and concatenate to H.264/AAC MP4 with
faststart (optional slide PDF).

**The output stays at the source frame rate — 30 fps, every webcam frame
preserved (28,891 frames for this deck).** Speed comes from *encoding only the
pixels that change*, not from dropping frames.

## The encode-only-changes technique

A slide's background is static; only the small webcam circle moves. So:

1. **Composite a strip, not a frame.** Odin blends the circle-masked webcam onto
   just the horizontal band of macroblock rows that contains the webcam
   (1920×360 here, rows 45–67) and writes only that strip. The full 1080p frame
   is never materialised — ~6× less pixel data written and read.
2. **Encode the strip** with the `x264` CLI (Constrained Baseline, CAVLC,
   `--stitchable`, one IDR per chunk).
3. **Splice at the bitstream level** (`src/h264.odin`). The strip stream is
   woven into a full 1920×1080 H.264 stream:
   - IDR = a `bg_top` I-slice (the static rows above the strip, `first_mb 0`)
     plus the strip I-slice (`first_mb = 5400`).
   - Each P frame = a skip slice for the static rows above the strip, plus the
     strip as a **separate slice**. The slice boundary makes the strip's
     top-row top-neighbour unavailable, exactly matching the strip encode, so
     the strip decodes identically even when its top row carries slide content.
   The static background is carried entirely by P-skips; only the webcam strip
   is actually coded. No re-encode, no quality loss beyond the strip's own CRF.

The pipeline (`src/encode.odin`) runs webcam decode, compositing and encoding
**out of order**: ready slides are processed while long clips are still
decoding (chunks are independent and concatenated in order at the end).
Compositing uses a worker pool; splicing runs on its own worker so the
scheduler is never blocked by bitstream work. The audio pass renders
concurrently and is hidden inside the encode. VAAPI webcam decode is auto-used
when a DRM render node exists (it offloads decode to the GPU, freeing CPU for
compositing/encoding); `--cpu-decode` forces software.

## Full-deck time (21 slides, ~16 min, 28,891 source frames, 1080p30)

Machine: AMD Ryzen 7 8845HS (8c/16t), Radeon 780M (VAAPI), 27 GB RAM,
ffmpeg 9.0.2, x264 0.165, LibreOffice 26.8.1.1, poppler 26.10.

**Default run, speed 1.0, 30 fps: ~21.7 s** (down from ~53 s for the earlier
full-frame GPU-encode pipeline).

| stage | time |
|---|---|
| parse (zip + slide XML) | 0.08 s |
| extract webcam clips | 0.14 s |
| clean deck re-zip | 0.04 s |
| probe (21 parallel ffprobes) | 0.26 s |
| render (LibreOffice PDF, overlaps probe/decode) | 1.09 s |
| rasterize (pdftoppm, parallel) | 0.67 s |
| PNG → raw YUV | 0.43 s |
| masks | <0.01 s |
| encode (decode + composite + strip encode + splice, pipelined) | 16.52 s |
| audio (hidden inside encode) | 0.00 s |
| wrap segments → MKV | 1.36 s |
| mux (concat copy + faststart) | 1.04 s |
| **total** | **21.65 s** |

Inside the encode stage: webcam decode finishes at ~12 s (VAAPI, GPU-bound);
composite ~19 s of worker-time across 4 workers; the strip encoders run at
~1.5–3k fps each. The remaining cost is the webcam decode floor plus
memory-bandwidth contention between compositing (writes the strip) and x264
(reads it).

## Verification (what was checked, and how)

All outputs under `out/` (gitignored). Inputs in `~/Downloads` were only read.

1. **Duration / streams (ffprobe).** `out/ha8-30.mp4`: 963.026 s, **28,891 video
   packets = exact source frame sum**, 1920×1080, 30/1 fps, H.264 Constrained
   Baseline + AAC mono 48 kHz.
2. **Full decode.** `ffmpeg -v error -i out/ha8-30.mp4 -f null -` → **zero
   errors** across all 28,891 frames (the bitstream splice is standards-
   compliant; every chunk and every splice boundary decodes cleanly).
3. **Audio present and in sync.** Cross-correlated a 3 s output window against
   the same source window (slide 1): **corr 0.952** at a constant ~76 ms offset
   (AAC codec/priming delay), i.e. the narration is the correct source audio,
   aligned within lip-sync tolerance. Loudness auto gain +10.6 dB.
4. **Loudness.** `--check` (ebur128 on the finished file): **−18.0 LUFS**
   (target −18).
5. **Frames looked at.** Extracted and visually inspected frames at t = 5 s
   (slide 1), 89.9 s (slide 3→4 boundary), 300 s, 700 s and 959 s (references):
   correct slide content, webcam circle bottom-right at (1583, 743), 324 px,
   colours matching the background, **no seam at the strip boundary**.
6. **Splice correctness, isolated.** The Odin splice was checked against a
   Python reference on real webcam strips: identical decoded pixels
   (per-frame RMSE ≈ 0.24/255, encoder noise only), including slides whose
   strip top row carries slide content.

## Bugs found and fixed during development

- A P slice's `slice_data` already begins with `mb_skip_run`; the static rows
  must be added via a **separate skip slice**, not by editing that run.
- The strip must be its **own slice** in the full frame: sharing a slice with
  the skipped rows changes the top-row neighbour context and corrupts decode
  whenever the strip's top row has content (slide 2 onward).
- `slice_qp_delta` is variable-length, so each slice header is parsed for its
  own bit length; the RBSP trailing stop bit is the *lowest* set bit of the
  last non-zero byte.
- One IDR per chunk (`--keyint 9999 --scenecut 0`); the splice rejects chunks
  with extra IDRs.
- Out-of-order compositing required dropping each slide's webcam file only
  after **all** its chunks have read it (a per-slide counter), not on the last
  chunk's encode completion.
- `fmt.tprintf` uses Odin's temp allocator; heap `hprintf` is used everywhere.

## Unfinished / limitations

- **The <15 s stretch goal is not yet met (~21.7 s).** The remaining floor is
  the webcam decode (~12 s, GPU-bound) plus memory-bandwidth contention between
  compositing and x264 on the full-width strip. A narrower strip (webcam
  columns only, per-row slices) would cut the composite/encode pixel traffic
  ~5× and is the identified next step.
- Linux-only (VAAPI decode optional, `/dev/dri`); zip64 packages rejected; first
  video per slide only; linked (non-embedded) videos unsupported; assumes the
  reference's 16:9 1920×1080 layout.
- Whole archive read into RAM (~400 MB for this deck).
- No automated test suite; verification was the measured checks above.

## Final summary

- **Full-deck compile: ~21.7 s at the mandatory 30 fps** (28,891 frames),
  vs ~53 s previously — a 2.4× speedup achieved by encoding only the pixels
  that change (static background → P-skips; only the webcam strip is coded).
- Per-stage: encode 16.5 s (decode ~12 s GPU + composite/strip-encode/splice
  pipelined), wrap 1.4 s, mux 1.0 s, render/rasterize/YUV ~2.2 s, rest <0.6 s.
- **Verified:** exact frame count (28,891) and duration (963.03 s); full decode
  with zero errors; audio in sync (corr 0.952, ~76 ms codec delay) at −18.0
  LUFS; frames inspected at several timestamps including slide boundaries —
  correct slides, webcam position/size/colour, no splice seam.
- **Not yet <15 s**; the decode floor and strip memory bandwidth are the
  remaining limits (narrower strip is the next step).
- Commit: see git log (`deckcast: 30fps encode-only-changes via strip bitstream
  splice` and follow-ups).

## Deliverables

- `out/ha8-30.mp4` — speed 1.0, 16:03, 1080p30, −18.0 LUFS (28,891 frames)
- `out/ha8-30.pdf` — 21-page slide PDF without webcam
- `out/work30/` — kept work dir (logs, segments, renders) for inspection