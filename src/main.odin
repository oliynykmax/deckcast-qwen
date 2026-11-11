package main

// deckcast: compile a PowerPoint Recorder deck (.pptx with one narration
// clip per slide) into a finished MP4. Odin owns the package parsing, deck
// cleaning, masking, scheduling and timing; ffmpeg/LibreOffice/pdftoppm do
// the rendering and encoding. See README.md.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Options :: struct {
	input:        string,
	output:       string,
	pdf:          string,
	speed:        f64,
	gain:         string,
	target:       f64,
	work:         string,
	slides_lo:    int,
	slides_hi:    int,
	encoder:      string,
	jobs:         int,
	vaapi_device: string,
	check:        bool,
}

Stage_Time :: struct {
	name: string,
	dur:  time.Duration,
}

usage :: proc() -> ! {
	fmt.eprintf(`deckcast: compile a PowerPoint-recorded deck into one MP4

Usage:
  deckcast <input.pptx> -o <output.mp4> [options]

Options:
  -o, --output PATH      output MP4 (required)
      --pdf PATH         also save the slide PDF (without webcam)
      --speed F          per-slide speedup, e.g. 1.035 (default 1.0)
      --gain auto|DB     audio gain in dB, or auto for target loudness
      --target F         auto-gain target LUFS (default -18)
      --work DIR         work directory (kept; default /tmp/deckcast-<pid>)
      --slides LO-HI     only compile this slide range (quick tests)
      --encoder E        auto | vaapi | x264 (default auto)
      --jobs N           parallel encode jobs (default 3 vaapi / 4 x264)
      --vaapi-device P   render node (default: first /dev/dri/renderD*)
      --check            measure loudness of the finished file too
`)
	os.exit(2)
}

arg_value :: proc(args: []string, i: ^int, flag: string) -> string {
	if i^ + 1 >= len(args) {
		fmt.eprintf("deckcast: %s needs a value\n", flag)
		usage()
	}
	i^ += 1
	return args[i^]
}

stage_record :: proc(stages: ^[dynamic]Stage_Time, name: string, start: time.Time) {
	append(stages, Stage_Time{name, time.since(start)})
}

parse_args :: proc() -> Options {
	o := Options{speed = 1.0, gain = "auto", target = -18.0, encoder = "auto"}
	args := os.args
	i := 1
	for ; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "-o", "--output":
			o.output = arg_value(args, &i, a)
		case "--pdf":
			o.pdf = arg_value(args, &i, a)
		case "--speed":
			v, ok := strconv.parse_f64(arg_value(args, &i, a))
			if !ok || v <= 0 {
				fmt.eprintf("deckcast: bad --speed\n")
				usage()
			}
			o.speed = v
		case "--gain":
			o.gain = arg_value(args, &i, a)
		case "--target":
			v, ok := strconv.parse_f64(arg_value(args, &i, a))
			if !ok {
				fmt.eprintf("deckcast: bad --target\n")
				usage()
			}
			o.target = v
		case "--work":
			o.work = arg_value(args, &i, a)
		case "--slides":
			v := arg_value(args, &i, a)
			if dash := strings.index_byte(v, '-'); dash >= 0 {
				lo, ok1 := strconv.parse_int(v[:dash], 10)
				hi, ok2 := strconv.parse_int(v[dash+1:], 10)
				if !ok1 || !ok2 {
					fmt.eprintf("deckcast: bad --slides (use LO-HI)\n")
					usage()
				}
				o.slides_lo, o.slides_hi = lo, hi
			} else {
				n, ok := strconv.parse_int(v, 10)
				if !ok {
					fmt.eprintf("deckcast: bad --slides\n")
					usage()
				}
				o.slides_lo, o.slides_hi = n, n
			}
		case "--encoder":
			o.encoder = arg_value(args, &i, a)
		case "--jobs":
			n, ok := strconv.parse_int(arg_value(args, &i, a), 10)
			if !ok || n < 1 {
				fmt.eprintf("deckcast: bad --jobs\n")
				usage()
			}
			o.jobs = n
		case "--vaapi-device":
			o.vaapi_device = arg_value(args, &i, a)
		case "--check":
			o.check = true
		case "-h", "--help":
			usage()
		case:
			if strings.has_prefix(a, "-") {
				fmt.eprintf("deckcast: unknown option %s\n", a)
				usage()
			}
			if o.input != "" {
				fmt.eprintf("deckcast: more than one input file\n")
				usage()
			}
			o.input = a
		}
	}
	if o.input == "" || o.output == "" {
		usage()
	}
	return o
}

find_vaapi_device :: proc() -> string {
	for n in 128 ..< 136 {
		p := hprintf("/dev/dri/renderD%d", n)
		if os.exists(p) {
			return p
		}
	}
	return ""
}

abs_path :: proc(path: string) -> string {
	if strings.has_prefix(path, "/") {
		return path
	}
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil {
		fmt.eprintf("deckcast: cannot get working directory: %v\n", err)
		os.exit(1)
	}
	return hprintf("%s/%s", cwd, path)
}

pad_int :: proc(n, width: int) -> string {
	s := hprintf("%d", n)
	for len(s) < width {
		s = hprintf("0%s", s)
	}
	return s
}

main :: proc() {
	o := parse_args()
	t_start := time.now()
	stages: [dynamic]Stage_Time

	// --- work dirs ---
	if o.work == "" {
		o.work = hprintf("/tmp/deckcast-%d", os.get_pid())
	}
	o.work = abs_path(o.work)
	for dir in ([]string{"", "/media", "/logs", "/png", "/yuv", "/seg"}) {
		p := hprintf("%s%s", o.work, dir)
		if os.exists(p) {
			continue
		}
		if err := os.make_directory_all(p); err != nil {
			fmt.eprintf("deckcast: cannot create work dir: %v\n", err)
			os.exit(1)
		}
	}

	// --- open package, parse slides ---
	t := time.now()
	zip, ok := zip_open(o.input)
	if !ok {
		os.exit(1)
	}
	all_slides, cleaned, ok2 := load_deck(&zip, o.work)
	if !ok2 {
		os.exit(1)
	}
	page_count := len(cleaned)

	// Slide range selection.
	lo, hi := 1, page_count
	if o.slides_lo > 0 {
		lo, hi = o.slides_lo, o.slides_hi
	}
	slides: [dynamic]Slide
	for &s in all_slides {
		if s.number >= lo && s.number <= hi {
			append(&slides, s)
		}
	}
	for n in lo ..= hi {
		found := false
		for &s in slides {
			if s.number == n {
				found = true
				break
			}
		}
		if !found {
			fmt.eprintf("deckcast: slide %d has no recording (re-record it or pass --slides)\n", n)
			os.exit(1)
		}
	}
	stage_record(&stages, "parse", t)

	// --- extract webcam clips (stored in the zip: plain copies) ---
	t = time.now()
	for &s in slides {
		e, found := zip_find(&zip, s.media_name)
		if !found {
			fmt.eprintf("deckcast: missing media %s\n", s.media_name)
			os.exit(1)
		}
		data, alloc, dok := zip_entry_data(&zip, e)
		if !dok {
			os.exit(1)
		}
		if err := os.write_entire_file(s.video_path, data); err != nil {
			fmt.eprintf("deckcast: cannot extract %s: %v\n", s.video_path, err)
			os.exit(1)
		}
		if alloc {
			delete(data)
		}
	}
	stage_record(&stages, "extract", t)

	// --- clean deck for LibreOffice: no video shapes, no timing, no media ---
	t = time.now()
	wentries: [dynamic]Zip_Write_Entry
	for &e in zip.entries {
		if strings.has_suffix(e.name, ".mp4") || strings.has_suffix(e.name, ".m4a") || strings.has_suffix(e.name, ".wav") {
			continue
		}
		if cleaned_xml, is_slide := cleaned[e.name]; is_slide {
			append(&wentries, Zip_Write_Entry{e.name, transmute([]byte)cleaned_xml})
			continue
		}
		data, alloc, dok := zip_entry_data(&zip, &e)
		if !dok {
			os.exit(1)
		}
		// Stored data aliases the archive (alive until exit); inflated
		// data is heap-owned. Both stay valid until the zip is written.
		_ = alloc
		append(&wentries, Zip_Write_Entry{e.name, data})
	}
	clean_pptx := hprintf("%s/clean.pptx", o.work)
	if !zip_write_stored(clean_pptx, wentries[:]) {
		os.exit(1)
	}
	stage_record(&stages, "clean", t)

	// --- encoder choice ---
	use_vaapi := false
	vaapi_device := o.vaapi_device
	switch o.encoder {
	case "vaapi":
		use_vaapi = true
	case "x264":
		use_vaapi = false
	case "auto":
		if vaapi_device == "" {
			vaapi_device = find_vaapi_device()
		}
		if vaapi_device != "" {
			test := job_make("vaapi-test", o.work, vaapi_test_cmd(vaapi_device))
			use_vaapi = run_batch([]Job{test}, 1)
		}
	case:
		fmt.eprintf("deckcast: unknown encoder %s\n", o.encoder)
		os.exit(1)
	}
	if use_vaapi && vaapi_device == "" {
		vaapi_device = find_vaapi_device()
	}
	enc_jobs := o.jobs
	if enc_jobs == 0 {
		enc_jobs = 3 if use_vaapi else 4
	}

	// --- parallel: PDF render, loudness probe, per-clip frame counts ---
	t = time.now()
	audio_list := hprintf("%s/audio.txt", o.work)
	{
		b := strings.builder_make()
		for &s in slides {
			strings.write_string(&b, hprintf("file '%s'\n", s.video_path))
		}
		write_text(audio_list, strings.to_string(b))
	}

	batch: [dynamic]Job
	append(&batch, job_make("soffice", o.work, soffice_cmd(clean_pptx, o.work)))
	append(&batch, job_make("loudness", o.work, loudness_cmd(audio_list)))
	for &s in slides {
		append(&batch, job_make(hprintf("probe-%02d", s.number), o.work, probe_cmd(s.video_path)))
	}
	must_batch(batch[:], 8)

	pdf := hprintf("%s/clean.pdf", o.work)
	if !os.exists(pdf) {
		fmt.eprintf("deckcast: LibreOffice did not produce %s\n", pdf)
		os.exit(1)
	}

	gain_db: f64
	if o.gain == "auto" {
		lufs, ok := parse_lufs(read_log(hprintf("%s/logs/loudness.err", o.work)))
		if !ok {
			fmt.eprintf("deckcast: cannot measure loudness (see logs/loudness.err)\n")
			os.exit(1)
		}
		gain_db = math.round((o.target-lufs)*10) / 10
	} else {
		v, ok := strconv.parse_f64(o.gain)
		if !ok {
			fmt.eprintf("deckcast: bad --gain %s\n", o.gain)
			os.exit(1)
		}
		gain_db = v
	}

	for &s in slides {
		log := read_log(hprintf("%s/logs/probe-%02d.out", o.work, s.number))
		w, h, frames, ok := parse_probe(log)
		if !ok {
			fmt.eprintf("deckcast: cannot probe %s\n", s.video_path)
			os.exit(1)
		}
		s.src_w, s.src_h, s.src_frames = w, h, frames
		s.out_frames = int(math.round(f64(frames) / o.speed))
		s.dur = f64(s.out_frames) / FPS
	}
	stage_record(&stages, "render+probe", t)

	// --- rasterize PDF pages (parallel chunks) ---
	t = time.now()
	png_prefix := hprintf("%s/png/s", o.work)
	{
		chunks := 4
		ppm_jobs: [dynamic]Job
		for c in 0 ..< chunks {
			cl := page_count*c/chunks + 1
			ch := page_count * (c + 1) / chunks
			if cl > ch {
				continue
			}
			append(&ppm_jobs, job_make(hprintf("ppm-%d", c), o.work, pdftoppm_cmd(pdf, png_prefix, cl, ch)))
		}
		must_batch(ppm_jobs[:], chunks)
	}
	stage_record(&stages, "rasterize", t)

	// --- slide PNGs -> raw YUV (once per slide, not per frame) ---
	t = time.now()
	digits := len(hprintf("%d", page_count))
	yuv_jobs: [dynamic]Job
	for &s in slides {
		png := hprintf("%s-%s.png", png_prefix, pad_int(s.number, digits))
		s_yuv := hprintf("%s/yuv/%02d.yuv", o.work, s.number)
		append(&yuv_jobs, job_make(hprintf("yuv-%02d", s.number), o.work, yuv_cmd(png, s_yuv)))
	}
	must_batch(yuv_jobs[:], 8)
	stage_record(&stages, "yuv", t)

	// --- circle masks (one per distinct size) ---
	t = time.now()
	mask_paths := make(map[[2]int]string)
	for &s in slides {
		if !s.ellipse {
			continue
		}
		key := [2]int{s.w, s.h}
		if _, seen := mask_paths[key]; seen {
			continue
		}
		path := hprintf("%s/mask-%dx%d.raw", o.work, s.w, s.h)
		mask := make_ellipse_mask(s.w, s.h)
		if err := os.write_entire_file(path, mask); err != nil {
			fmt.eprintf("deckcast: cannot write mask: %v\n", err)
			os.exit(1)
		}
		delete(mask)
		mask_paths[key] = path
	}
	stage_record(&stages, "masks", t)

	// --- encode segments ---
	t = time.now()
	seg_jobs: [dynamic]Job
	for &s in slides {
		out := hprintf("%s/seg/%02d.mkv", o.work, s.number)
		params := Segment_Params{
			slide_png_yuv = hprintf("%s/yuv/%02d.yuv", o.work, s.number),
			video = s.video_path,
			mask_raw = mask_paths[[2]int{s.w, s.h}],
			out = out,
			s = &s,
			speed = o.speed,
			gain_db = gain_db,
			vaapi = use_vaapi,
			vaapi_device = vaapi_device,
		}
		append(&seg_jobs, job_make(hprintf("seg-%02d", s.number), o.work, segment_cmd(params)))
		fmt.eprintf("slide %d: %.1f s (%d frames)\n", s.number, s.dur, s.out_frames)
	}
	must_batch(seg_jobs[:], enc_jobs)
	stage_record(&stages, "encode", t)

	// --- concatenate + AAC + faststart ---
	t = time.now()
	seg_list := hprintf("%s/segments.txt", o.work)
	{
		b := strings.builder_make()
		for &s in slides {
			strings.write_string(&b, hprintf("file '%s/seg/%02d.mkv'\n", o.work, s.number))
		}
		write_text(seg_list, strings.to_string(b))
	}
	out_abs := abs_path(o.output)
	os.make_directory_all(os.dir(out_abs))
	must_batch([]Job{job_make("concat", o.work, concat_cmd(seg_list, out_abs))}, 1)
	stage_record(&stages, "mux", t)

	// --- PDF deliverable ---
	if o.pdf != "" {
		pdf_abs := abs_path(o.pdf)
		os.make_directory_all(os.dir(pdf_abs))
		if err := os.copy_file(pdf_abs, pdf); err != nil {
			fmt.eprintf("deckcast: cannot copy PDF: %v\n", err)
			os.exit(1)
		}
	}

	// --- summary ---
	total := time.since(t_start)
	djob := job_make("duration", o.work, duration_cmd(out_abs))
	run_batch([]Job{djob}, 1)
	dur_str := strings.trim_space(read_log(djob.stdout_path))
	out_dur, _ := strconv.parse_f64(dur_str)

	fmt.printf("%s: %d:%04.1f, gain %+.1f dB, encoder %s\n",
		out_abs, int(out_dur) / 60, math.mod(out_dur, 60), gain_db, "vaapi" if use_vaapi else "x264")
	if o.check {
		cjob := job_make("check-loudness", o.work, loudness_file_cmd(out_abs))
		run_batch([]Job{cjob}, 1)
		if lufs, ok := parse_lufs(read_log(cjob.stderr_path)); ok {
			fmt.printf("loudness: %.1f LUFS\n", lufs)
		}
	}
	fmt.printf("work dir: %s\n", o.work)
	fmt.println("stage times:")
	for &st in stages {
		fmt.printf("  %-14s %7s s\n", st.name, hprintf("%.2f", time.duration_seconds(st.dur)))
	}
	fmt.printf("  %-14s %7s s\n", "TOTAL", hprintf("%.2f", time.duration_seconds(total)))
}
