package main

// ffmpeg/ffprobe/LibreOffice command builders and output parsers.
// The heavy pixel work (decode, crop, scale, circle mask, overlay, encode)
// stays in ffmpeg; with VAAPI the overlay and encode run on the GPU and the
// static slide is uploaded exactly once per segment.

import "core:fmt"
import "core:strconv"
import "core:strings"

FPS :: 30

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

Segment_Params :: struct {
	slide_png_yuv: string, // raw yuv420p 1920x1080, single frame
	video:         string,
	mask_raw:      string, // raw gray w*h, single frame ("" when no ellipse)
	out:           string,
	s:             ^Slide,
	speed:         f64,
	gain_db:       f64,
	vaapi:         bool,
	vaapi_device:  string,
}

segment_cmd :: proc(p: Segment_Params) -> []string {
	s := p.s
	cw := int(f64(s.src_w)*(1-s.crop_l-s.crop_r) + 0.5)
	cx := int(f64(s.src_w)*s.crop_l + 0.5)

	cam := hprintf("[1:v]fps=%d,crop=%d:%d:%d:0,scale=%d:%d,setpts=PTS/%f,format=yuva420p[cam]",
		FPS, cw, s.src_h, cx, s.w, s.h, p.speed)

	mask_fc := ""
	if s.ellipse {
		if p.vaapi {
			mask_fc = ";[2:v]loop=loop=-1:size=1[m];[cam][m]alphamerge[c];[c]hwupload[camhw]"
		} else {
			mask_fc = ";[2:v]loop=loop=-1:size=1[m];[cam][m]alphamerge[c]"
		}
	} else {
		if p.vaapi {
			mask_fc = ";[cam]hwupload[camhw]"
		} else {
			mask_fc = ";[cam]null[c]"
		}
	}

	audio := hprintf("[1:a]%svolume=%.1fdB,alimiter=limit=0.89:level=false,aresample=48000,apad,atrim=0:%f,aformat=channel_layouts=mono[a]",
		atempo_chain(p.speed), p.gain_db, s.dur)

	fc: string
	vcodec: []string
	if p.vaapi {
		fc = hprintf("[0:v]format=nv12,hwupload,loop=loop=-1:size=1[bg];%s%s;[bg][camhw]overlay_vaapi=x=%d:y=%d[v];%s",
			cam, mask_fc, s.x, s.y, audio)
		vcodec = {"-c:v", "h264_vaapi", "-qp", "19", "-bf", "0", "-refs", "1", "-async_depth", "8", "-g", "300"}
	} else {
		fc = hprintf("[0:v]loop=loop=-1:size=1[bg];%s%s;[bg][c]overlay=%d:%d,format=yuv420p[v];%s",
			cam, mask_fc, s.x, s.y, audio)
		vcodec = {"-c:v", "libx264", "-preset", "veryfast", "-crf", "18"}
	}

	cmd: [dynamic]string
	append(&cmd, "ffmpeg", "-nostdin", "-y", "-v", "error")
	if p.vaapi {
		append(&cmd, "-vaapi_device", p.vaapi_device)
	}
	append(&cmd, "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "1920x1080", "-framerate", hprintf("%d", FPS), "-i", p.slide_png_yuv)
	append(&cmd, "-i", p.video)
	if s.ellipse {
		append(&cmd, "-f", "rawvideo", "-pix_fmt", "gray", "-s", hprintf("%dx%d", s.w, s.h), "-framerate", hprintf("%d", FPS), "-i", p.mask_raw)
	}
	append(&cmd, "-filter_complex", fc, "-map", "[v]", "-map", "[a]")
	append(&cmd, "-frames:v", hprintf("%d", s.out_frames))
	append(&cmd, ..vcodec)
	append(&cmd, "-r", hprintf("%d", FPS), "-c:a", "pcm_s16le", p.out)
	return cmd[:]
}

concat_cmd :: proc(list_path, out: string) -> []string {
	return cmd_of(
		"ffmpeg", "-nostdin", "-y", "-v", "error", "-f", "concat", "-safe", "0",
		"-i", list_path, "-c:v", "copy", "-c:a", "aac", "-b:a", "160k",
		"-movflags", "+faststart", out,
	)
}

duration_cmd :: proc(path: string) -> []string {
	return cmd_of("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path)
}

vaapi_test_cmd :: proc(device: string) -> []string {
	return cmd_of(
		"ffmpeg", "-nostdin", "-v", "error", "-vaapi_device", device,
		"-f", "lavfi", "-i", "color=black:s=256x256:r=30", "-frames:v", "1",
		"-vf", "format=nv12,hwupload", "-c:v", "h264_vaapi", "-f", "null", "-",
	)
}
