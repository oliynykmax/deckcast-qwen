package main

// Slide deck parsing: finds the recorded webcam picture on each slide,
// reads its position/size/crop from the DrawingML, and strips the video
// (and timing tree) so LibreOffice renders the slide without it.
// Everything is flat data: one []Slide, string slices into the XML.

import "core:fmt"
import "core:os"
import "core:sort"
import "core:strconv"
import "core:strings"

EMU_PER_PX :: 12192000.0 / 1920.0 // 16:9 deck rendered 1920 px wide

Slide :: struct {
	number:     int,
	media_name: string, // zip-internal path, e.g. ppt/media/media1.mp4
	video_path: string, // extracted file on disk
	x, y, w, h: int, // webcam rect in 1920x1080 pixel space
	crop_l:     f64, // srcRect fractions
	crop_r:     f64,
	ellipse:    bool,
	src_w:      int, // probed source dimensions
	src_h:      int,
	src_frames: int, // video packet count
	out_frames: int, // after speed change
	dur:        f64, // out_frames / 30
}

Range :: struct {
	lo, hi: int,
}

// attr reads `key="value"` from a tag substring.
attr :: proc(s, key: string) -> (val: string, found: bool) {
	k := hprintf("%s=\"", key)
	i := strings.index(s, k)
	if i < 0 {
		return
	}
	start := i + len(k)
	end := strings.index_byte(s[start:], '"')
	if end < 0 {
		return
	}
	return s[start : start + end], true
}

attr_int :: proc(s, key: string) -> (val: int, found: bool) {
	v, ok := attr(s, key)
	if !ok {
		return
	}
	n, ok2 := strconv.parse_int(v, 10)
	if !ok2 {
		return
	}
	return n, true
}

// find_tag_ranges locates every <name ...>...</name> span, including
// self-closing <name .../> tags. The elements we scan (p:pic, p:timing,
// a:ext, Relationship) never nest, so the first closing tag wins.
find_tag_ranges :: proc(s, name: string) -> []Range {
	open_tag := hprintf("<%s", name)
	close_tag := hprintf("</%s>", name)

	ranges: [dynamic]Range
	i := 0
	for {
		j := strings.index(s[i:], open_tag)
		if j < 0 {
			break
		}
		start := i + j
		after := start + len(open_tag)
		if after >= len(s) || (s[after] != '>' && s[after] != ' ' && s[after] != '\t' && s[after] != '\r' && s[after] != '\n') {
			i = after
			continue
		}
		gt := strings.index_byte(s[after:], '>')
		if gt < 0 {
			break
		}
		tag_end := after + gt
		if s[tag_end-1] == '/' { // self-closing
			append(&ranges, Range{start, tag_end + 1})
			i = tag_end + 1
			continue
		}
		k := strings.index(s[tag_end+1:], close_tag)
		if k < 0 {
			break
		}
		end := tag_end + 1 + k + len(close_tag)
		append(&ranges, Range{start, end})
		i = end
	}
	return ranges[:]
}

// video_pic_range finds the first p:pic that carries an a:videoFile.
video_pic_range :: proc(xml: string) -> (r: Range, found: bool) {
	pics := find_tag_ranges(xml, "p:pic")
	defer delete(pics)
	for pr in pics {
		if strings.contains(xml[pr.lo:pr.hi], "videoFile") {
			return pr, true
		}
	}
	return
}

parse_webcam :: proc(xml: string) -> (s: Slide, found: bool) {
	pr, ok := video_pic_range(xml)
	if !ok {
		return
	}
	pic := xml[pr.lo:pr.hi]

	rid, ok2 := attr(pic, "r:link")
	if !ok2 {
		return
	}
	s.number = -1 // filled by caller; rid stored temporarily in media_name
	s.media_name = rid

	// Geometry: first a:off, and the a:ext that has cx (a:extLst also uses
	// <a:ext uri=...>, so pick the one with a cx attribute).
	off_i := strings.index(pic, "<a:off")
	if off_i < 0 {
		return
	}
	off_tag := pic[off_i:]
	x, okx := attr_int(off_tag, "x")
	y, oky := attr_int(off_tag, "y")
	if !okx || !oky {
		return
	}
	cx, cy: int
	found_ext := false
	exts := find_tag_ranges(pic, "a:ext")
	defer delete(exts)
	for er in exts {
		tag := pic[er.lo:er.hi]
		if w, ok := attr_int(tag, "cx"); ok {
			h, ok2 := attr_int(tag, "cy")
			if ok2 {
				cx, cy = w, h
				found_ext = true
			}
			break
		}
	}
	if !found_ext {
		return
	}
	s.x = int(f64(x) / EMU_PER_PX + 0.5)
	s.y = int(f64(y) / EMU_PER_PX + 0.5)
	s.w = int(f64(cx) / EMU_PER_PX + 0.5)
	s.h = int(f64(cy) / EMU_PER_PX + 0.5)

	if sr_i := strings.index(pic, "<a:srcRect"); sr_i >= 0 {
		tag := pic[sr_i:]
		if v, ok := attr_int(tag, "l"); ok {
			s.crop_l = f64(v) / 100000
		}
		if v, ok := attr_int(tag, "r"); ok {
			s.crop_r = f64(v) / 100000
		}
	}
	s.ellipse = strings.contains(pic, "prst=\"ellipse\"")
	found = true
	return
}

// rels_target resolves a relationship id to a zip-internal path.
rels_target :: proc(rels_xml, rid, base_dir: string) -> (path: string, found: bool) {
	for r in find_tag_ranges(rels_xml, "Relationship") {
		tag := rels_xml[r.lo:r.hi]
		id, ok := attr(tag, "Id")
		if !ok || id != rid {
			continue
		}
		target, ok2 := attr(tag, "Target")
		if !ok2 {
			return
		}
		if strings.contains(target, "://") {
			return // external link: not an embedded recording
		}
		joined := hprintf("%s/%s", base_dir, target)
		return path_normalize(joined), true
	}
	return
}

// clean_slide_xml removes every video p:pic and the p:timing tree.
clean_slide_xml :: proc(xml: string) -> string {
	cuts: [dynamic]Range
	for r in find_tag_ranges(xml, "p:pic") {
		if strings.contains(xml[r.lo:r.hi], "videoFile") {
			append(&cuts, r)
		}
	}
	timings := find_tag_ranges(xml, "p:timing")
	append(&cuts, ..timings)
	delete(timings)
	defer delete(cuts)
	sort.quick_sort_proc(cuts[:], proc(a, b: Range) -> int {
		return a.lo - b.lo
	})

	b := strings.builder_make()
	pos := 0
	for r in cuts {
		if r.lo < pos {
			continue
		}
		strings.write_string(&b, xml[pos:r.lo])
		pos = r.hi
	}
	strings.write_string(&b, xml[pos:])
	return strings.to_string(b)
}

// load_deck reads every ppt/slides/slideN.xml, in slide-number order, and
// returns the slides that carry a recording plus the cleaned XML for all.
load_deck :: proc(zip: ^Zip_Archive, work: string) -> (slides: []Slide, cleaned: map[string]string, ok: bool) {
	cleaned = make(map[string]string)
	names: [dynamic]string
	for &e in zip.entries {
		if strings.has_prefix(e.name, "ppt/slides/slide") && strings.has_suffix(e.name, ".xml") &&
		   !strings.contains(e.name, "_rels") {
			append(&names, e.name)
		}
	}
	defer delete(names)
	sort.quick_sort_proc(names[:], proc(a, b: string) -> int {
		na, _ := strconv.parse_int(a[len("ppt/slides/slide") : len(a)-len(".xml")], 10)
		nb, _ := strconv.parse_int(b[len("ppt/slides/slide") : len(b)-len(".xml")], 10)
		return na - nb
	})

	tmp: [dynamic]Slide
	for name in names {
		e, _ := zip_find(zip, name)
		data, alloc, dok := zip_entry_data(zip, e)
		if !dok {
			return
		}
		xml := string(data)

		num, _ := strconv.parse_int(name[len("ppt/slides/slide") : len(name)-len(".xml")], 10)
		cleaned[name] = clean_slide_xml(xml)

		s, found := parse_webcam(xml)
		if found {
			rels_name := hprintf("ppt/slides/_rels/slide%d.xml.rels", num)
			re, rok := zip_find(zip, rels_name)
			if !rok {
				fmt.eprintf("deckcast: missing rels for %s\n", name)
				return
			}
			rdata, ralloc, rok2 := zip_entry_data(zip, re)
			if !rok2 {
				return
			}
			target, tok := rels_target(string(rdata), s.media_name, "ppt/slides")
			if ralloc {
				delete(rdata)
			}
			if !tok {
				fmt.eprintf("deckcast: slide %d: cannot resolve video relationship %s\n", num, s.media_name)
				return
			}
			s.number = num
			s.media_name = target
			s.video_path = hprintf("%s/media/%s", work, target[strings.last_index_byte(target, '/')+1:])
			append(&tmp, s)
		}
		if alloc {
			delete(data)
		}
	}
	slides = tmp[:]
	ok = true
	return
}
