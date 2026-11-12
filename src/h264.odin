package main

// H.264 bitstream surgery for "encode only what changes".
//
// The webcam lives in a horizontal strip (MB rows strip_top..67). We encode just
// that strip with x264, then splice it into a full 1920x1080 stream:
//   IDR = bg_top I-slice (first_mb 0, static rows above the strip)
//         + strip I-slice (first_mb = skip).
//   P   = strip P-slice with `skip` added to its leading mb_skip_run, so the
//         static rows above the strip become P-skips and only the strip is coded.
// x264 ultrafast --stitchable gives Constrained Baseline / CAVLC / POC type 2,
// which makes this a pure bitstream concatenation (no re-encode).

import "core:fmt"
import "core:os"

// ---- bit reader over a byte slice ----
BR :: struct {
	data: []byte,
	pos:  int, // bit position
}

br_u :: proc(r: ^BR, n: int) -> int {
	v := 0
	for _ in 0 ..< n {
		b := r.data[r.pos>>3]
		bit := (b >> uint(7-(r.pos&7))) & 1
		v = (v << 1) | int(bit)
		r.pos += 1
	}
	return v
}

br_ue :: proc(r: ^BR) -> int {
	z := 0
	for br_u(r, 1) == 0 {
		z += 1
	}
	v := (1 << uint(z)) - 1
	if z > 0 {
		v += br_u(r, z)
	}
	return v
}

br_se :: proc(r: ^BR) -> int {
	k := br_ue(r)
	if k&1 != 0 {
		return (k + 1) / 2
	}
	return -(k / 2)
}

// ---- bit writer (packed bytes) ----
BW :: struct {
	data: [dynamic]byte,
	n:    int, // bits written
}

bw_bit :: proc(w: ^BW, bit: int) {
	if w.n&7 == 0 {
		append(&w.data, 0)
	}
	if bit != 0 {
		w.data[w.n>>3] |= byte(1 << uint(7-(w.n&7)))
	}
	w.n += 1
}

bw_u :: proc(w: ^BW, v, n: int) {
	for i in 0 ..< n {
		bw_bit(w, (v>>uint(n-1-i))&1)
	}
}

bw_ue :: proc(w: ^BW, v: int) {
	x := v + 1
	n := 0
	for t := x; t > 0; t >>= 1 {
		n += 1
	}
	for _ in 0 ..< n-1 {
		bw_bit(w, 0)
	}
	bw_u(w, x, n)
}

// append `count` bits from src starting at bit `start`.
bw_range :: proc(w: ^BW, src: []byte, start, count: int) {
	if count <= 0 {
		return
	}
	// Fast path: src and dst share the same bit offset, so bytes line up and
	// can be copied whole (this is the common case for the large slice copies).
	if start&7 == w.n&7 {
		need := (w.n + count + 7) >> 3
		for len(w.data) < need {
			append(&w.data, 0)
		}
		doff := w.n & 7
		sb := start >> 3
		db := w.n >> 3
		nbytes := ((start + count + 7) >> 3) - sb
		for i in 0 ..< nbytes {
			b := src[sb+i]
			if i == 0 && doff != 0 {
				b &= byte(0xFF >> uint(doff))
			}
			if i == nbytes-1 {
				endbit := (start + count) & 7
				if endbit != 0 {
					b &= byte(0xFF << uint(8-endbit))
				}
			}
			w.data[db+i] |= b
		}
		w.n += count
		return
	}
	for i in 0 ..< count {
		p := start + i
		bit := (src[p>>3] >> uint(7-(p&7))) & 1
		bw_bit(w, int(bit))
	}
}

bw_trailing :: proc(w: ^BW) {
	bw_bit(w, 1)
	for w.n&7 != 0 {
		bw_bit(w, 0)
	}
}

// index of the last 1-bit in stream order (the rbsp trailing stop bit): the
// lowest set bit of the last non-zero byte. payload is [0, result).
last_one_bit :: proc(data: []byte) -> int {
	for i := len(data) - 1; i >= 0; i -= 1 {
		if data[i] != 0 {
			b := data[i]
			for bit := 0; bit < 8; bit += 1 {
				if b&(1<<uint(bit)) != 0 {
					return i*8 + (7 - bit)
				}
			}
		}
	}
	return 0
}

// ---- Annex-B NAL handling ----
rbsp_of :: proc(nal: []byte) -> []byte {
	out: [dynamic]byte
	z := 0
	for i in 0 ..< len(nal) {
		if z >= 2 && nal[i] == 3 {
			z = 0
			continue
		}
		append(&out, nal[i])
		if nal[i] == 0 {
			z += 1
		} else {
			z = 0
		}
	}
	return out[:]
}

add_ep :: proc(data: []byte) -> []byte {
	out: [dynamic]byte
	z := 0
	for i in 0 ..< len(data) {
		if z >= 2 && data[i] <= 3 {
			append(&out, 3)
			z = 0
		}
		append(&out, data[i])
		if data[i] == 0 {
			z += 1
		} else {
			z = 0
		}
	}
	return out[:]
}

nal_split :: proc(data: []byte) -> [][]byte {
	starts: [dynamic]int
	j := 0
	for j < len(data)-3 {
		if data[j] == 0 && data[j+1] == 0 && data[j+2] == 1 {
			append(&starts, j+3)
			j += 3
		} else if j < len(data)-4 && data[j] == 0 && data[j+1] == 0 && data[j+2] == 0 && data[j+3] == 1 {
			append(&starts, j+4)
			j += 4
		} else {
			j += 1
		}
	}
	out: [dynamic][]byte
	for k in 0 ..< len(starts) {
		s := starts[k]
		e := len(data)
		if k+1 < len(starts) {
			e = starts[k+1] - 3
		}
		for e > s && data[e-1] == 0 {
			e -= 1
		}
		append(&out, data[s:e])
	}
	return out[:]
}

// ---- SPS / PPS / slice header ----
SPS :: struct {
	profile, level:            int,
	log2_max_frame_num:        int,
	poc_type, log2_max_poc_lsb: int,
	pic_width, pic_height:     int,
	ph_start, ph_len:          int, // bit offset/length of pic_height_in_map_units_minus1
	frame_mbs_only, max_ref:   int,
}

parse_sps :: proc(r: ^BR) -> SPS {
	s: SPS
	s.profile = br_u(r, 8)
	br_u(r, 8) // constraints
	s.level = br_u(r, 8)
	br_ue(r)   // sps_id
	if s.profile == 100 || s.profile == 110 || s.profile == 122 || s.profile == 244 ||
		s.profile == 44 || s.profile == 83 || s.profile == 86 || s.profile == 118 ||
		s.profile == 128 || s.profile == 138 || s.profile == 139 || s.profile == 134 || s.profile == 135 {
		chroma := br_ue(r)
		if chroma == 3 {
			br_u(r, 1)
		}
		br_ue(r) // bit_depth_luma
		br_ue(r) // bit_depth_chroma
		br_u(r, 1)
		if br_u(r, 1) != 0 {
			fmt.eprintf("deckcast: scaling matrices unsupported\n")
			os.exit(1)
		}
	}
	s.log2_max_frame_num = br_ue(r) + 4
	s.poc_type = br_ue(r)
	if s.poc_type == 0 {
		s.log2_max_poc_lsb = br_ue(r) + 4
	}
	s.max_ref = br_ue(r)
	br_u(r, 1) // gaps
	s.pic_width = br_ue(r) + 1
	s.ph_start = r.pos
	s.pic_height = br_ue(r) + 1
	s.ph_len = r.pos - s.ph_start
	s.frame_mbs_only = br_u(r, 1)
	if s.frame_mbs_only == 0 {
		br_u(r, 1)
	}
	br_u(r, 1) // direct_8x8
	if br_u(r, 1) != 0 { // frame_cropping
		br_ue(r)
		br_ue(r)
		br_ue(r)
		br_ue(r)
	}
	br_u(r, 1) // vui present (rest left untouched)
	return s
}

PPS :: struct {
	cabac, bottom_field_poc, num_slice_groups:      int,
	num_ref_l0, num_ref_l1:                         int,
	weighted_pred, weighted_bipred:                 int,
	deblock, constrained_intra, redundant_pic:      int,
}

parse_pps :: proc(r: ^BR) -> PPS {
	p: PPS
	br_ue(r) // pps_id
	br_ue(r) // sps_id
	p.cabac = br_u(r, 1)
	p.bottom_field_poc = br_u(r, 1)
	p.num_slice_groups = br_ue(r) + 1
	p.num_ref_l0 = br_ue(r) + 1
	p.num_ref_l1 = br_ue(r) + 1
	p.weighted_pred = br_u(r, 1)
	p.weighted_bipred = br_u(r, 2)
	br_se(r) // pic_init_qp
	br_se(r) // pic_init_qs
	br_se(r) // chroma_qp_offset
	p.deblock = br_u(r, 1)
	p.constrained_intra = br_u(r, 1)
	p.redundant_pic = br_u(r, 1)
	return p
}

// returns the bit offset where slice_data begins.
parse_slice_header :: proc(r: ^BR, nal_type: int, s: SPS, p: PPS) -> int {
	br_ue(r) // first_mb_in_slice
	st := br_ue(r) % 5 // slice_type
	br_ue(r) // pps_id
	br_u(r, s.log2_max_frame_num) // frame_num
	if s.frame_mbs_only == 0 {
		if br_u(r, 1) != 0 {
			br_u(r, 1)
		}
	}
	if nal_type == 5 {
		br_ue(r) // idr_pic_id
	}
	if s.poc_type == 0 {
		br_u(r, s.log2_max_poc_lsb)
		if p.bottom_field_poc != 0 {
			br_se(r)
		}
	}
	if p.redundant_pic != 0 {
		br_ue(r)
	}
	if st == 1 {
		br_u(r, 1) // direct_spatial_mv_pred
	}
	if st == 0 || st == 1 || st == 3 {
		if br_u(r, 1) != 0 { // num_ref_idx_active_override
			br_ue(r)
			if st == 1 {
				br_ue(r)
			}
		}
	}
	if st != 2 && st != 4 { // ref_pic_list_modification
		if br_u(r, 1) != 0 {
			for {
				op := br_ue(r)
				if op == 0 {
					break
				}
				br_ue(r)
				if op == 3 {
					br_ue(r)
				}
			}
		}
		if st == 1 {
			if br_u(r, 1) != 0 {
				for {
					op := br_ue(r)
					if op == 0 {
						break
					}
					br_ue(r)
				}
			}
		}
	}
	// dec_ref_pic_marking (nal_ref_idc != 0)
	if nal_type == 5 {
		br_u(r, 1)
		br_u(r, 1)
	} else {
		if br_u(r, 1) != 0 {
			for {
				op := br_ue(r)
				if op == 0 {
					break
				}
				if op == 1 || op == 3 {
					br_ue(r)
				}
				if op == 2 {
					br_ue(r)
				}
				if op == 3 || op == 6 {
					br_ue(r)
				}
				if op == 4 {
					br_ue(r)
				}
			}
		}
	}
	if p.cabac != 0 && st != 2 {
		br_ue(r)
	}
	br_se(r) // slice_qp_delta
	if p.deblock != 0 {
		dd := br_ue(r)
		if dd != 1 {
			br_se(r)
			br_se(r)
		}
	}
	return r.pos
}

// read a ue(v) directly from a bit offset in a byte slice; returns value+bitlen.
read_ue_at :: proc(data: []byte, start: int) -> (val, bits: int) {
	r := BR{data = data, pos = start}
	val = br_ue(&r)
	bits = r.pos - start
	return
}

emit_nal :: proc(out: ^[dynamic]byte, ref_idc, nal_type: int, rbsp: []byte) {
	append(out, 0, 0, 0, 1)
	append(out, byte((ref_idc<<5)|nal_type))
	ep := add_ep(rbsp)
	append(out, ..ep)
	delete(ep)
}

emit_raw_nal :: proc(out: ^[dynamic]byte, nal: []byte) {
	append(out, 0, 0, 0, 1)
	append(out, ..nal)
}

// splice_chunk builds a full 1080p .264 from a strip .264 and a bg_top .264.
// skip = number of leading macroblocks (static rows) before the strip.
splice_chunk :: proc(strip_path, bgtop_path, out_path: string, skip: int) -> bool {
	sdata, serr := os.read_entire_file(strip_path, context.allocator)
	if serr != nil {
		fmt.eprintf("deckcast: splice: read %s: %v\n", strip_path, serr)
		return false
	}
	defer delete(sdata)
	bdata, berr := os.read_entire_file(bgtop_path, context.allocator)
	if berr != nil {
		fmt.eprintf("deckcast: splice: read %s: %v\n", bgtop_path, berr)
		return false
	}
	defer delete(bdata)

	snals := nal_split(sdata)
	defer delete(snals)
	bnals := nal_split(bdata)
	defer delete(bnals)

	ssps_nal, spps_nal, sidr_nal, bidr_nal: []byte
	ps: [dynamic][]byte
	defer delete(ps)
	idr_count := 0
	for n in snals {
		switch n[0] & 31 {
		case 7:
			ssps_nal = n
		case 8:
			spps_nal = n
		case 5:
			sidr_nal = n
			idr_count += 1
		case 1:
			append(&ps, n)
		}
	}
	if idr_count != 1 {
		fmt.eprintf("deckcast: splice: expected 1 IDR per chunk, got %d (keyint/scenecut?)\n", idr_count)
		return false
	}
	for n in bnals {
		if n[0]&31 == 5 {
			bidr_nal = n
		}
	}
	if ssps_nal == nil || spps_nal == nil || sidr_nal == nil || bidr_nal == nil {
		fmt.eprintf("deckcast: splice: missing NALs\n")
		return false
	}

	ssps_r := rbsp_of(ssps_nal[1:])
	defer delete(ssps_r)
	spps_r := rbsp_of(spps_nal[1:])
	defer delete(spps_r)
	sidr_r := rbsp_of(sidr_nal[1:])
	defer delete(sidr_r)

	sr := BR{data = ssps_r}
	ss := parse_sps(&sr)
	pr := BR{data = spps_r}
	sp := parse_pps(&pr)

	out: [dynamic]byte
	defer delete(out)

	// Full SPS: strip SPS with pic_height -> 68 MB rows (1080p) and level 40.
	payload := last_one_bit(ssps_r)
	w: BW
	bw_range(&w, ssps_r, 0, 16)
	bw_u(&w, 40, 8) // level_idc
	bw_range(&w, ssps_r, 24, ss.ph_start-24)
	bw_ue(&w, 67) // pic_height_in_map_units_minus1 (68 rows)
	bw_range(&w, ssps_r, ss.ph_start+ss.ph_len, payload-(ss.ph_start+ss.ph_len))
	bw_trailing(&w)
	emit_nal(&out, 3, 7, w.data[:])
	delete(w.data)

	// PPS verbatim.
	emit_raw_nal(&out, spps_nal)
	// IDR slice 1: bg_top verbatim (first_mb 0).
	emit_raw_nal(&out, bidr_nal)
	// IDR slice 2: strip IDR with first_mb 0 -> skip.
	ipayload := last_one_bit(sidr_r)
	w = BW{}
	bw_ue(&w, skip)
	bw_range(&w, sidr_r, 1, ipayload-1)
	bw_trailing(&w)
	emit_nal(&out, 3, 5, w.data[:])
	delete(w.data)

	// P frames: TWO slices. Slice A skips the static rows above the strip;
	// slice B is the strip verbatim with first_mb -> skip. The slice boundary
	// makes the strip's top-row top-neighbour unavailable, exactly matching the
	// strip encode (so it decodes identically even when the top row has content).
	for pn in ps {
		r := rbsp_of(pn[1:])
		hr := BR{data = r}
		he := parse_slice_header(&hr, 1, ss, sp)
		pay := last_one_bit(r)
		// slice A: strip header (first_mb 0) + mb_skip_run(skip) only
		w = BW{}
		bw_range(&w, r, 0, he)
		bw_ue(&w, skip)
		bw_trailing(&w)
		emit_nal(&out, 2, 1, w.data[:])
		delete(w.data)
		// slice B: strip with first_mb 0 -> skip
		w = BW{}
		bw_ue(&w, skip)
		bw_range(&w, r, 1, pay-1)
		bw_trailing(&w)
		emit_nal(&out, 2, 1, w.data[:])
		delete(w.data)
		delete(r)
	}

	if werr := os.write_entire_file(out_path, out[:]); werr != nil {
		fmt.eprintf("deckcast: splice: write %s: %v\n", out_path, werr)
		return false
	}
	return true
}
