package main

// ffmpeg/ffprobe/LibreOffice/x264 command builders and output parsers.
//
// Speed strategy: a slide's background is static, only the small webcam circle
// moves. We composite in Odin (rewriting just the webcam rect) into a raw frame
// file on tmpfs, then let x264 read that file. ~95% of each frame's macroblocks
// are bit-identical to the previous frame, so x264 emits cheap P-skips: it
// effectively encodes only the pixels that change. The output stays at the
// source rate (30 fps, every webcam frame preserved); throughput comes from
// running several x264 encoders in parallel over fixed-size chunks.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

FPS_DEFAULT :: 30
SRC_FPS :: 30

probe_cmd :: proc(path: string) -> []string {
	return cmd_of(
		"ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0",
		"-show_entries", "stream=width,height,nb_read_packets", "-of", "csv=p=0", path,
	)
}

// parse_probe reads "960,540,917".
parse_probe :: proc(csv: string) -> (w, h, frames: int, ok: bool) {
	line := strings.trim_space(csv)
	parts := strings.split(line, ",")
	defer delete(parts)
	if len(parts) < 3 {
		return
	}
	w, ok = strconv.parse_int(strings.trim_space(parts[0]), 10)
	if !ok {
		return
	}
	h, ok = strconv.parse_int(strings.trim_space(parts[1]), 10)
	if !ok {
		return
	}
	frames, ok = strconv.parse_int(strings.trim_space(parts[2]), 10)
	return
}

loudness_cmd :: proc(list_path: string) -> []string {
	return cmd_of(
		"ffmpeg", "-nostdin", "-v", "info", "-f", "concat", "-safe", "0",
		"-i", list_path, "-vn", "-af", "ebur128=peak=true", "-f", "null", "-",
	)
}

loudness_file_cmd :: proc(path: string) -> []string {
	return cmd_of(
		"ffmpeg", "-nostdin", "-v", "info", "-i", path,
		"-vn", "-af", "ebur128=peak=true", "-f", "null", "-",
	)
}

// parse_lufs pulls the last integrated loudness value from ebur128 output.
parse_lufs :: proc(log: string) -> (lufs: f64, ok: bool) {
	i := strings.last_index(log, "I:")
	if i < 0 {
		return
	}
	rest := strings.trim_left(log[i+2:], " \t")
	end := strings.index(rest, " LUFS")
	if end < 0 {
		return
	}
	v, ok2 := strconv.parse_f64(rest[:end])
	if !ok2 {
		return
	}
	return v, true
}

soffice_cmd :: proc(clean_pptx, outdir: string) -> []string {
	return cmd_of("soffice", "--headless", "--convert-to", "pdf", "--outdir", outdir, clean_pptx)
}

pdftoppm_cmd :: proc(pdf, prefix: string, lo, hi: int) -> []string {
	return cmd_of(
		"pdftoppm", "-png", "-scale-to-x", "1920", "-scale-to-y", "1080",
		"-f", hprintf("%d", lo), "-l", hprintf("%d", hi), pdf, prefix,
	)
}

yuv_cmd :: proc(png, yuv: string) -> []string {
	return cmd_of("ffmpeg", "-nostdin", "-y", "-v", "error", "-i", png, "-pix_fmt", "yuv420p", "-f", "rawvideo", yuv)
}

// atempo_chain builds a chain of atempo filters for any speed > 0
// (each instance is limited to 0.5..2.0 by ffmpeg).
atempo_chain :: proc(speed: f64) -> string {
	if speed == 1.0 {
		return ""
	}
	b := strings.builder_make()
	s := speed
	for s > 2.0 {
		strings.write_string(&b, "atempo=2.0,")
		s /= 2.0
	}
	for s < 0.5 {
		strings.write_string(&b, "atempo=0.5,")
		s /= 0.5
	}
	strings.write_string(&b, hprintf("atempo=%f,", s))
	return strings.to_string(b)
}

// webcam_raw_cmd decodes a slide's recording, speeds it up, resamples to the
// output frame rate, crops/scales to the webcam rect and writes raw yuv420p
// frames (no alpha — the circle mask is applied during compositing). With a
// VAAPI device the decode+scale run on the GPU, which keeps the CPU free for
// the encoder; the crop is done after downloading the aspect-scaled frame.
webcam_raw_cmd :: proc(video, out: string, s: ^Slide, speed: f64, fps: int, vaapi_device: string) -> []string {
	cw := int(f64(s.src_w)*(1-s.crop_l-s.crop_r) + 0.5)
	cx := int(f64(s.src_w)*s.crop_l + 0.5)
	if vaapi_device != "" {
		sw := int(f64(s.src_w)*f64(s.h)/f64(s.src_h) + 0.5)
		cx2 := int(f64(cx)*f64(s.h)/f64(s.src_h) + 0.5)
		vf := hprintf("setpts=PTS/%f,fps=%d,scale_vaapi=w=%d:h=%d,hwdownload,format=nv12,crop=%d:%d:%d:0,format=yuv420p",
			speed, fps, sw, s.h, s.w, s.h, cx2)
		return cmd_of(
			"ffmpeg", "-nostdin", "-y", "-v", "error",
			"-hwaccel", "vaapi", "-hwaccel_device", vaapi_device, "-hwaccel_output_format", "vaapi",
			"-i", video, "-vf", vf, "-frames:v", hprintf("%d", s.out_frames),
			"-an", "-f", "rawvideo", "-pix_fmt", "yuv420p", out,
		)
	}
	vf := hprintf("setpts=PTS/%f,fps=%d,crop=%d:%d:%d:0,scale=%d:%d,format=yuv420p",
		speed, fps, cw, s.src_h, cx, s.w, s.h)
	return cmd_of(
		"ffmpeg", "-nostdin", "-y", "-v", "error", "-threads", "2", "-i", video,
		"-vf", vf, "-frames:v", hprintf("%d", s.out_frames),
		"-an", "-f", "rawvideo", "-pix_fmt", "yuv420p", out,
	)
}

// find_vaapi_device returns the first DRM render node, or "" if none.
find_vaapi_device :: proc() -> string {
	for n in 128 ..< 136 {
		p := hprintf("/dev/dri/renderD%d", n)
		if os.exists(p) {
			return p
		}
	}
	return ""
}

// x264_cmd encodes a raw YUV frame file with the x264 CLI (faster than ffmpeg's
// libx264 wrapper for this read-bound, mostly-static content). w/h select the
// strip (1920xSH) or the static bg_top (1920xstrip_top_y). --stitchable keeps
// SPS/PPS identical across encodes so h264.odin can splice them.
x264_cmd :: proc(raw_in, out_264: string, fps, threads, w, h: int) -> []string {
	return cmd_of(
		"x264", "--preset", "ultrafast", "--crf", "18",
		"--threads", hprintf("%d", threads),
		"--fps", hprintf("%d", fps), "--input-res", hprintf("%dx%d", w, h),
		"--keyint", "9999", "--scenecut", "0", "--stitchable",
		"-o", out_264, raw_in,
	)
}

// write_bgtop extracts the static rows above the strip (0..bgtop_h-1) from a
// slide's full YUV into a one-frame raw file for the bg_top I-slice encode.
write_bgtop :: proc(yuv_path, out_path: string, bgtop_h: int) -> bool {
	data, err := os.read_entire_file(yuv_path, context.allocator)
	if err != nil {
		fmt.eprintf("deckcast: bgtop: read %s: %v\n", yuv_path, err)
		return false
	}
	defer delete(data)
	out: [dynamic]byte
	defer delete(out)
	append(&out, ..data[:bgtop_h*BG_W])
	u := BG_W * BG_H
	append(&out, ..data[u:u+(bgtop_h/2)*(BG_W/2)])
	v := BG_W*BG_H + BG_W*BG_H/4
	append(&out, ..data[v:v+(bgtop_h/2)*(BG_W/2)])
	return os.write_entire_file(out_path, out[:]) == nil
}

// audio_pass_cmd renders the whole narration in one pass: per-clip speed +
// exact trim, concat, gain, limiter, 48 kHz mono AAC. Runs concurrently with
// the video encode so its cost is hidden.
audio_pass_cmd :: proc(slides: []Slide, out: string, speed, gain_db: f64) -> []string {
	cmd: [dynamic]string
	append(&cmd, "ffmpeg", "-nostdin", "-y", "-v", "error")
	for &s in slides {
		append(&cmd, "-i", s.video_path)
	}
	b := strings.builder_make()
	for i in 0 ..< len(slides) {
		s := &slides[i]
		strings.write_string(&b, hprintf("[%d:a]%satrim=0:%f,asetpts=PTS-STARTPTS[a%d];",
			i, atempo_chain(speed), s.dur, i))
	}
	for i in 0 ..< len(slides) {
		strings.write_string(&b, hprintf("[a%d]", i))
	}
	strings.write_string(&b, hprintf("concat=n=%d:v=0:a=1[ac];[ac]volume=%.1fdB,alimiter=limit=0.89:level=false,aformat=channel_layouts=mono[a]",
		len(slides), gain_db))
	append(&cmd, "-filter_complex", strings.to_string(b))
	append(&cmd, "-map", "[a]", "-c:a", "aac", "-aac_coder", "fast", "-b:a", "160k", out)
	return cmd[:]
}

// mux_cmd muxes the concatenated raw H.264 stream (stitchable segments) with
// the finished AAC track and writes a faststart MP4 at the given frame rate.
mux_cmd :: proc(video_264, audio, out: string, fps: int) -> []string {
	return cmd_of(
		"ffmpeg", "-nostdin", "-y", "-v", "error",
		"-r", hprintf("%d", fps), "-i", video_264,
		"-i", audio, "-map", "0:v", "-map", "1:a",
		"-c:v", "copy", "-c:a", "copy", "-movflags", "+faststart", out,
	)
}

duration_cmd :: proc(path: string) -> []string {
	return cmd_of("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path)
}
