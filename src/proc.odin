package main

// External-tool plumbing. All children are spawned from the main thread
// (os.process_start is not thread-safe); a flat job array is polled with
// non-blocking waits, keeping up to `max_parallel` children running.
// stdout/stderr of every job go to log files so results can be read back
// and failures diagnosed.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Job :: struct {
	label:       string,
	cmd:         []string,
	stdout_path: string,
	stderr_path: string,
	ok:          bool,
	exit_code:   int,
}

job_make :: proc(label: string, work: string, cmd: []string) -> Job {
	return Job{
		label = label,
		cmd = cmd,
		stdout_path = hprintf("%s/logs/%s.out", work, label),
		stderr_path = hprintf("%s/logs/%s.err", work, label),
	}
}

// cmd_of copies a command line onto the heap (slice literals are stack-bound).
cmd_of :: proc(args: ..string) -> []string {
	c := make([]string, len(args))
	copy(c, args)
	return c
}

// hprintf is hprintf on the heap allocator: safe to keep and delete.
// (hprintf uses the temp allocator, whose strings must not be freed
// with delete() and can be invalidated by later temp-allocator scopes.)
hprintf :: proc(format: string, args: ..any) -> string {
	b := strings.builder_make(context.allocator)
	fmt.sbprintf(&b, format, ..args)
	return strings.to_string(b)
}

tail_of_file :: proc(path: string, max_bytes := 2000) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return "(no log)"
	}
	defer delete(data)
	s := string(data)
	if len(s) > max_bytes {
		s = s[len(s)-max_bytes:]
	}
	return strings.clone(s)
}

// run_batch runs jobs with at most max_parallel children at once.
// Returns false if any job failed (all jobs still run to completion).
run_batch :: proc(jobs: []Job, max_parallel: int) -> bool {
	procs := make([]os.Process, len(jobs))
	files := make([]^os.File, 2 * len(jobs))
	started := make([]bool, len(jobs))
	finished := make([]bool, len(jobs))
	defer {
		delete(procs)
		delete(files)
		delete(started)
		delete(finished)
	}

	next := 0
	running := 0
	all_ok := true

	for next < len(jobs) || running > 0 {
		for running < max_parallel && next < len(jobs) {
			j := &jobs[next]
			out, oerr := os.open(j.stdout_path, {.Write, .Create, .Trunc})
			errf, eerr := os.open(j.stderr_path, {.Write, .Create, .Trunc})
			if oerr != nil || eerr != nil {
				fmt.eprintf("deckcast: cannot open logs for %s\n", j.label)
				j.ok = false
				j.exit_code = -1
				finished[next] = true
				all_ok = false
				next += 1
				continue
			}
			files[2 * next] = out
			files[2 * next + 1] = errf
			desc := os.Process_Desc{
				command = j.cmd,
				stdout = out,
				stderr = errf,
			}
			p, perr := os.process_start(desc)
			// The child dup'd the fds; our copies are no longer needed.
			os.close(out)
			os.close(errf)
			if perr != nil {
				fmt.eprintf("deckcast: cannot start %s: %v\n", j.label, perr)
				j.ok = false
				j.exit_code = -1
				finished[next] = true
				all_ok = false
				next += 1
				continue
			}
			procs[next] = p
			started[next] = true
			next += 1
			running += 1
		}

		for i in 0 ..< next {
			if !started[i] || finished[i] {
				continue
			}
			state, err := os.process_wait(procs[i], timeout = 0)
			if err != nil || !state.exited {
				continue // .Timeout: still running
			}
			finished[i] = true
			running -= 1
			jobs[i].exit_code = state.exit_code
			jobs[i].ok = state.exit_code == 0
			if !jobs[i].ok {
				all_ok = false
				fmt.eprintf("deckcast: %s failed (exit %d)\n", jobs[i].label, state.exit_code)
				fmt.eprintf("%s\n", tail_of_file(jobs[i].stderr_path))
			}
		}

		if running > 0 {
			time.sleep(2 * time.Millisecond)
		}
	}
	return all_ok
}

// must_batch runs a batch and aborts the program on any failure.
must_batch :: proc(jobs: []Job, max_parallel: int) {
	if !run_batch(jobs, max_parallel) {
		os.exit(1)
	}
}

read_log :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

write_text :: proc(path, text: string) {
	if err := os.write_entire_file(path, text); err != nil {
		fmt.eprintf("deckcast: cannot write %s: %v\n", path, err)
		os.exit(1)
	}
}
