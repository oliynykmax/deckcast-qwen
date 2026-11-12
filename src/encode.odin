package main

// The composite + encode pipeline, with just-in-time webcam decode.
//
// Three kinds of work overlap:
//   * webcam decode (ffmpeg children) turns each recording into raw circle
//     frames on tmpfs;
//   * compositing (a small worker-thread pool) blends those frames onto the
//     static slide, writing raw STRIP chunk files (only the webcam band);
//   * encoding (x264 children) reads the strip files, then h264.odin splices
//     each into a full 1080p segment: the static rows above the strip become
//     P-skips, so only the pixels that change are actually coded.
//
// All children are spawned from the main thread (os.process_start is not
// thread-safe). Compositing runs in workers because it must outrun the encoder.
// A bounded in-flight count keeps tmpfs under quota; long slides are split into
// fixed-size chunks so no single raw file grows too large. Decoding a slide is
// overlapped with encoding earlier slides, hiding its cost.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

CHUNK_MAX :: 600 // frames per raw file (~600 MB for the 1920x360 strip)
COMP_WORKERS :: 4
CAM_PAR :: 6 // concurrent webcam decoders

Chunk :: struct {
	slide_idx: int,
	start:     int,
	n:         int,
	id:        int,
}

build_chunks :: proc(slides: []Slide) -> []Chunk {
	chunks: [dynamic]Chunk
	id := 0
	for si in 0 ..< len(slides) {
		total := slides[si].out_frames
		for start := 0; start < total; start += CHUNK_MAX {
			n := CHUNK_MAX
			if start+n > total {
				n = total - start
			}
			append(&chunks, Chunk{slide_idx = si, start = start, n = n, id = id})
			id += 1
		}
	}
	return chunks[:]
}

// chunk states
ST_PENDING :: 0
ST_COMPOSING :: 1
ST_READY :: 2
ST_ENCODING :: 3
ST_DONE :: 4

// cam states
CAM_PENDING :: 0
CAM_RUNNING :: 1
CAM_READY :: 2

// Audio_Ctl lets the encode pipeline start the audio pass as soon as the
// loudness measurement finishes, so the audio render hides inside the encode.
Audio_Ctl :: struct {
	loud_proc:  os.Process,
	loud_job:   Job,
	audio_proc: os.Process,
	audio_job:  Job,
	done_loud:  bool,
	started:    bool,
	gain_db:    f64,
	work:       string,
	speed:      f64,
	target:     f64,
	gain_mode:  string,
	slides:     []Slide,
	audio_out:  string,
}

audio_ctl_tick :: proc(ac: ^Audio_Ctl) {
	if ac.done_loud {
		return
	}
	state, err := os.process_wait(ac.loud_proc, timeout = 0)
	if err != nil || !state.exited {
		return
	}
	ac.done_loud = true
	if state.exit_code != 0 {
		fmt.eprintf("deckcast: loudness measurement failed\n")
		return
	}
	if ac.gain_mode == "auto" {
		lufs, ok := parse_lufs(read_log(hprintf("%s/logs/loudness.err", ac.work)))
		if !ok {
			fmt.eprintf("deckcast: cannot measure loudness\n")
			return
		}
		ac.gain_db = math.round((ac.target-lufs)*10) / 10
	} else {
		v, ok := strconv.parse_f64(ac.gain_mode)
		if !ok {
			fmt.eprintf("deckcast: bad --gain %s\n", ac.gain_mode)
			return
		}
		ac.gain_db = v
	}
	ac.audio_job = job_make("audio", ac.work, audio_pass_cmd(ac.slides, ac.audio_out, ac.speed, ac.gain_db))
	p, ok := job_start_bg(&ac.audio_job)
	if ok {
		ac.audio_proc = p
		ac.started = true
	}
}

Pipe_Shared :: struct {
	mu:           sync.Mutex,
	slides:       []Slide,
	chunks:       []Chunk,
	work:         string,
	shm:          string,
	speed:        f64,
	fps:          int,
	vaapi_device: string,
	mask_paths:   map[[2]int]string,
	state:        []int,
	next:         int,
	inflight:     int,
	max_inflight: int,
	failed:       bool,
	comp_dur:     time.Duration,
	// webcam decode state (per slide)
	cam_state:  []int,
	cam_procs:  []os.Process,
	cam_jarr:   []Job,
	cam_next:   int,
	cam_running: int,
	is_last:    []bool, // chunk is the last of its slide
	comp_done:  []int,  // per-slide count of chunks finished compositing
	nchunks:    []int,  // per-slide total chunk count
}

composite_worker :: proc(data: rawptr) {
	sh := (^Pipe_Shared)(data)
	for {
		// Claim a pending chunk whose slide's webcam is ready. Out-of-order is
		// fine: chunks are independent and concatenated in order at the end, so
		// ready slides are processed while a long clip is still decoding.
		sync.mutex_lock(&sh.mu)
		if sh.failed {
			sync.mutex_unlock(&sh.mu)
			return
		}
		ci := -1
		for k in 0 ..< len(sh.chunks) {
			if sh.state[k] == ST_PENDING && sh.cam_state[sh.chunks[k].slide_idx] == CAM_READY {
				ci = k
				sh.state[k] = ST_COMPOSING
				sh.next += 1
				break
			}
		}
		all_claimed := sh.next >= len(sh.chunks)
		sync.mutex_unlock(&sh.mu)
		if ci < 0 {
			if all_claimed {
				break
			}
			time.sleep(1 * time.Millisecond)
			continue
		}

		c := &sh.chunks[ci]
		s := &sh.slides[c.slide_idx]

		// Reserve an in-flight slot (bounds tmpfs use).
		for {
			sync.mutex_lock(&sh.mu)
			if sh.failed {
				sync.mutex_unlock(&sh.mu)
				return
			}
			if sh.inflight < sh.max_inflight {
				sh.inflight += 1
				sync.mutex_unlock(&sh.mu)
				break
			}
			sync.mutex_unlock(&sh.mu)
			time.sleep(1 * time.Millisecond)
		}

		bg := hprintf("%s/yuv/%02d.yuv", sh.work, s.number)
		cam := hprintf("%s/cam_%02d.yuv", sh.shm, s.number)
		strip := hprintf("%s/strip_%04d.yuv", sh.shm, c.id)
		mask := sh.mask_paths[[2]int{s.w, s.h}]
		strip_top_y := (s.y/16 - 1) * 16
		ct := time.now()
		ok := composite_strip(bg, cam, mask, strip, s.x, s.y, s.w, s.h, strip_top_y, c.start, c.n)
		d := time.since(ct)

		sync.mutex_lock(&sh.mu)
		sh.comp_dur += d
		if !ok {
			sh.failed = true
			sh.inflight -= 1
			sync.mutex_unlock(&sh.mu)
			return
		}
		sh.state[ci] = ST_READY
		sh.comp_done[c.slide_idx] += 1
		if sh.comp_done[c.slide_idx] == sh.nchunks[c.slide_idx] {
			// every chunk of this slide has read the webcam; safe to drop it
			os.remove(hprintf("%s/cam_%02d.yuv", sh.shm, s.number))
		}
		sync.mutex_unlock(&sh.mu)
	}
}

encode_pipeline :: proc(slides: []Slide, chunks: []Chunk, work: string, shm: string, fps: int, jobs: int, threads: int, speed: f64, vaapi_device: string, mask_paths: map[[2]int]string, cam_procs: []os.Process, cam_jarr: []Job, cam_state: []int, ac: ^Audio_Ctl) -> bool {
	n := len(chunks)
	ns := len(slides)
	is_last := make([]bool, n)
	nchunks := make([]int, ns)
	for i in 0 ..< n {
		is_last[i] = i == n-1 || chunks[i+1].slide_idx != chunks[i].slide_idx
		nchunks[chunks[i].slide_idx] += 1
	}
	comp_done := make([]int, ns)
	sh := Pipe_Shared{
		slides = slides, chunks = chunks, work = work, shm = shm,
		speed = speed, fps = fps, vaapi_device = vaapi_device, mask_paths = mask_paths,
		state = make([]int, n), max_inflight = jobs + COMP_WORKERS + 2,
		cam_state = cam_state, cam_procs = cam_procs,
		cam_jarr = cam_jarr, is_last = is_last,
		comp_done = comp_done, nchunks = nchunks,
		cam_next = CAM_PAR, cam_running = CAM_PAR, // first CAM_PAR pre-started by caller
	}
	if CAM_PAR > ns {
		sh.cam_next = ns
		sh.cam_running = ns
	}
	defer {
		delete(sh.state)
		delete(is_last)
		delete(nchunks)
		delete(comp_done)
	}

	// Static bg_top I-slice source per slide: extract the rows above the strip
	// and encode once (1 frame each). SPS/PPS match the strip encodes (--stitchable).
	{
		bt_jobs: [dynamic]Job
		for &s in slides {
			top := (s.y/16 - 1) * 16
			bt_yuv := hprintf("%s/bgtop_%02d.yuv", shm, s.number)
			if !write_bgtop(hprintf("%s/yuv/%02d.yuv", work, s.number), bt_yuv, top) {
				return false
			}
			bt_264 := hprintf("%s/seg/bgtop_%02d.264", work, s.number)
			append(&bt_jobs, job_make(hprintf("bgtop-%02d", s.number), work, x264_cmd(bt_yuv, bt_264, fps, threads, BG_W, top)))
		}
		if !run_batch(bt_jobs[:], 4) {
			return false
		}
		delete(bt_jobs)
		for &s in slides {
			os.remove(hprintf("%s/bgtop_%02d.yuv", shm, s.number))
		}
	}

	for w in 0 ..< COMP_WORKERS {
		thread.run_with_data(&sh, composite_worker, context)
	}

	procs := make([]os.Process, n)
	jarr := make([]Job, n)
	full_paths := make([]string, n)
	defer {
		delete(procs)
		delete(jarr)
		delete(full_paths)
	}

	running := 0
	encoded := 0
	all_ok := true
	pipe_start := time.now()
	splice_dur := time.Duration(0)
	cam_done_logged := false

	for encoded < n {
		sync.mutex_lock(&sh.mu)
		// Spawn webcam decoders (in slide order), up to CAM_PAR concurrent.
		for sh.cam_running < CAM_PAR && sh.cam_next < ns {
			si := sh.cam_next
			s := &slides[si]
			cam := hprintf("%s/cam_%02d.yuv", shm, s.number)
			sh.cam_jarr[si] = job_make(hprintf("cam-%02d", s.number), work, webcam_raw_cmd(s.video_path, cam, s, speed, fps, sh.vaapi_device))
			p, sok := job_start_bg(&sh.cam_jarr[si])
			if !sok {
				sh.failed = true
			} else {
				sh.cam_procs[si] = p
				sh.cam_state[si] = CAM_RUNNING
			}
			sh.cam_next += 1
			sh.cam_running += 1
		}
		// Spawn encoders for ready chunks.
		for ci in 0 ..< n {
			if running >= jobs {
				break
			}
			if sh.state[ci] != ST_READY {
				continue
			}
			c := &chunks[ci]
			s := &slides[c.slide_idx]
			strip := hprintf("%s/strip_%04d.yuv", shm, c.id)
			strip264 := hprintf("%s/seg/strip_%04d.264", work, c.id)
			strip_h := BG_H - (s.y/16-1)*16
			jarr[ci] = job_make(hprintf("x264-%04d", c.id), work, x264_cmd(strip, strip264, fps, threads, BG_W, strip_h))
			p, sok := job_start_bg(&jarr[ci])
			if !sok {
				sh.failed = true
				all_ok = false
				sync.mutex_unlock(&sh.mu)
				return false
			}
			procs[ci] = p
			full_paths[ci] = strip
			sh.state[ci] = ST_ENCODING
			running += 1
		}
		failed := sh.failed
		sync.mutex_unlock(&sh.mu)
		if failed {
			all_ok = false
			break
		}

		// Reap webcam decoders.
		for si in 0 ..< sh.cam_next {
			if sh.cam_state[si] != CAM_RUNNING {
				continue
			}
			state, err := os.process_wait(sh.cam_procs[si], timeout = 0)
			if err != nil || !state.exited {
				continue
			}
			sh.cam_running -= 1
			if state.exit_code != 0 {
				sh.cam_state[si] = CAM_PENDING
				sh.failed = true
				all_ok = false
				fmt.eprintf("deckcast: cam-%02d failed (exit %d)\n", slides[si].number, state.exit_code)
			} else {
				sh.cam_state[si] = CAM_READY
			}
		}

		// Start the audio pass as soon as loudness is ready (hides in encode).
		audio_ctl_tick(ac)

		// Reap finished encoders.
		if !cam_done_logged && sh.cam_next == ns && sh.cam_running == 0 {
			cam_done_logged = true
			fmt.eprintf("[profile] all cam decoded at %.2f s\n", time.duration_seconds(time.since(pipe_start)))
		}
		for ci in 0 ..< n {
			if sh.state[ci] != ST_ENCODING {
				continue
			}
			state, err := os.process_wait(procs[ci], timeout = 0)
			if err != nil || !state.exited {
				continue
			}
			running -= 1
			encoded += 1
			jarr[ci].exit_code = state.exit_code
			jarr[ci].ok = state.exit_code == 0
			if !jarr[ci].ok {
				all_ok = false
				fmt.eprintf("deckcast: %s failed (exit %d)\n", jarr[ci].label, state.exit_code)
				fmt.eprintf("%s\n", tail_of_file(jarr[ci].stderr_path))
			} else {
				// Splice the strip into a full 1080p segment (static rows -> skips).
				c := &chunks[ci]
				s := &slides[c.slide_idx]
				skip := (s.y/16 - 1) * (BG_W / 16)
				strip264 := hprintf("%s/seg/strip_%04d.264", work, c.id)
				bgtop264 := hprintf("%s/seg/bgtop_%02d.264", work, s.number)
				out264 := hprintf("%s/seg/%04d.264", work, c.id)
				st := time.now()
				if !splice_chunk(strip264, bgtop264, out264, skip) {
					all_ok = false
				}
				splice_dur += time.since(st)
				os.remove(strip264)
			}
			os.remove(full_paths[ci])
			sync.mutex_lock(&sh.mu)
			sh.inflight -= 1
			sh.state[ci] = ST_DONE
			sync.mutex_unlock(&sh.mu)
		}

		if encoded < n {
			time.sleep(1 * time.Millisecond)
		}
	}

	fmt.eprintf("[profile] composite total: %.2f s across %d workers (%d chunks)\n",
		time.duration_seconds(sh.comp_dur), COMP_WORKERS, n)
	fmt.eprintf("[profile] splice total: %.2f s (main thread)\n", time.duration_seconds(splice_dur))
	return all_ok
}
