package main

// Static-background compositing. Each slide's background never changes, so we
// blend the circle-masked webcam onto a pristine strip buffer and write only the
// horizontal band (rows strip_top_y..1079) that contains the webcam. The encoder
// sees just that 1920xSH strip; h264.odin splices it into a full 1080p stream,
// coding only the pixels that change (the static rows above become P-skips).

import "core:fmt"
import "core:os"

BG_W :: 1920
BG_H :: 1080

// fast round-to-nearest division by 255 for a 16-bit numerator.
div255 :: proc(x: int) -> int {
	return (x + 1 + (x >> 8)) >> 8
}

// composite_strip blends the circle-masked webcam onto the static slide and
// writes ONLY the horizontal strip (rows strip_top_y..1079) that contains the
// webcam. The encoder works on this 1920xSH strip; h264.odin splices it back
// into a full 1080p stream with the static rows above as P-skips. Only the
// needed webcam frames are read (pread), and each output frame is one write.
composite_strip :: proc(bg_path, cam_path, mask_path, out_path: string, x, y, w, h, strip_top_y, start_frame, n_frames: int) -> bool {
	sh := BG_H - strip_top_y
	ly := y - strip_top_y // webcam top in strip-local pixels

	bgf, berr := os.open(bg_path, {.Read})
	if berr != nil {
		fmt.eprintf("deckcast: composite: cannot open %s: %v\n", bg_path, berr)
		return false
	}
	defer os.close(bgf)
	strip := make([]byte, BG_W*sh*3/2)
	defer delete(strip)
	uoff := BG_W * sh
	voff := BG_W*sh + BG_W*sh/4
	// background strip: luma rows strip_top_y..1079, chroma rows strip_top_y/2..539
	if _, e := os.read_at(bgf, strip[:BG_W*sh], i64(strip_top_y*BG_W)); e != nil {
		fmt.eprintf("deckcast: composite: bg luma read: %v\n", e)
		return false
	}
	if _, e := os.read_at(bgf, strip[uoff:uoff+BG_W*sh/4], i64(BG_W*BG_H+(strip_top_y/2)*(BG_W/2))); e != nil {
		fmt.eprintf("deckcast: composite: bg U read: %v\n", e)
		return false
	}
	if _, e := os.read_at(bgf, strip[voff:voff+BG_W*sh/4], i64(BG_W*BG_H+BG_W*BG_H/4+(strip_top_y/2)*(BG_W/2))); e != nil {
		fmt.eprintf("deckcast: composite: bg V read: %v\n", e)
		return false
	}

	mask, err2 := os.read_entire_file(mask_path, context.allocator)
	if err2 != nil {
		fmt.eprintf("deckcast: composite: cannot read mask %s: %v\n", mask_path, err2)
		return false
	}
	defer delete(mask)
	if len(mask) != w*h {
		fmt.eprintf("deckcast: composite: bad mask size %d (want %d)\n", len(mask), w*h)
		return false
	}

	frame_bytes := w * h * 3 / 2
	cam := make([]byte, n_frames*frame_bytes)
	defer delete(cam)
	camf, cerr := os.open(cam_path, {.Read})
	if cerr != nil {
		fmt.eprintf("deckcast: composite: cannot open %s: %v\n", cam_path, cerr)
		return false
	}
	defer os.close(camf)
	nread, rerr := os.read_at(camf, cam, i64(start_frame*frame_bytes))
	if rerr != nil || nread != len(cam) {
		fmt.eprintf("deckcast: composite: webcam short read %d/%d: %v\n", nread, len(cam), rerr)
		return false
	}

	cw2 := w / 2
	ch2 := h / 2
	cx0 := x / 2
	cy0 := ly / 2

	// Chroma alpha: average each 2x2 block of the luma mask.
	ca := make([]byte, cw2*ch2)
	defer delete(ca)
	for cy in 0 ..< ch2 {
		for cx in 0 ..< cw2 {
			s := int(mask[(2*cy)*w+2*cx]) + int(mask[(2*cy)*w+2*cx+1]) +
				int(mask[(2*cy+1)*w+2*cx]) + int(mask[(2*cy+1)*w+2*cx+1])
			ca[cy*cw2+cx] = byte((s + 2) / 4)
		}
	}

	// Pristine copy of the strip rect under the webcam.
	pry := make([]byte, w*h)
	pru := make([]byte, cw2*ch2)
	prv := make([]byte, cw2*ch2)
	defer delete(pry)
	defer delete(pru)
	defer delete(prv)
	for yy in 0 ..< h {
		copy(pry[yy*w:(yy+1)*w], strip[(ly+yy)*BG_W+x:(ly+yy)*BG_W+x+w])
	}
	for yy in 0 ..< ch2 {
		copy(pru[yy*cw2:(yy+1)*cw2], strip[uoff+(cy0+yy)*(BG_W/2)+cx0:uoff+(cy0+yy)*(BG_W/2)+cx0+cw2])
		copy(prv[yy*cw2:(yy+1)*cw2], strip[voff+(cy0+yy)*(BG_W/2)+cx0:voff+(cy0+yy)*(BG_W/2)+cx0+cw2])
	}

	of, oerr := os.open(out_path, {.Write, .Create, .Trunc})
	if oerr != nil {
		fmt.eprintf("deckcast: composite: cannot open %s: %v\n", out_path, oerr)
		return false
	}
	defer os.close(of)

	// Per-row spans of the circle (opaque interior = straight copy, thin
	// anti-aliased edge = blend, everything else keeps the slide).
	row_pl := make([]int, h)
	row_ol := make([]int, h)
	row_or := make([]int, h)
	row_pr := make([]int, h)
	defer delete(row_pl)
	defer delete(row_ol)
	defer delete(row_or)
	defer delete(row_pr)
	for yy in 0 ..< h {
		am := mask[yy*w : (yy+1)*w]
		pl, ol, orr, prr := -1, -1, -1, -1
		for xx in 0 ..< w {
			a := am[xx]
			if a > 0 {
				if pl < 0 {
					pl = xx
				}
				prr = xx + 1
			}
			if a == 255 {
				if ol < 0 {
					ol = xx
				}
				orr = xx + 1
			}
		}
		if ol < 0 {
			ol, orr = prr, prr
		}
		row_pl[yy], row_ol[yy], row_or[yy], row_pr[yy] = pl, ol, orr, prr
	}

	// Chroma row spans (same idea as luma: opaque interior is a straight copy).
	c_pl := make([]int, ch2)
	c_ol := make([]int, ch2)
	c_or := make([]int, ch2)
	c_pr := make([]int, ch2)
	defer delete(c_pl)
	defer delete(c_ol)
	defer delete(c_or)
	defer delete(c_pr)
	for yy in 0 ..< ch2 {
		am := ca[yy*cw2 : (yy+1)*cw2]
		pl, ol, orr, prr := -1, -1, -1, -1
		for xx in 0 ..< cw2 {
			a := am[xx]
			if a > 0 {
				if pl < 0 {
					pl = xx
				}
				prr = xx + 1
			}
			if a == 255 {
				if ol < 0 {
					ol = xx
				}
				orr = xx + 1
			}
		}
		if ol < 0 {
			ol, orr = prr, prr
		}
		c_pl[yy], c_ol[yy], c_or[yy], c_pr[yy] = pl, ol, orr, prr
	}

	for i in 0 ..< n_frames {
		off := i * frame_bytes
		frame := cam[off : off+frame_bytes]
		sy := frame[:w*h]
		su := frame[w*h : w*h+cw2*ch2]
		sv := frame[w*h+cw2*ch2 : w*h+2*cw2*ch2]

		for yy in 0 ..< h {
			dst := strip[(ly+yy)*BG_W+x : (ly+yy)*BG_W+x+w]
			prst := pry[yy*w : (yy+1)*w]
			src := sy[yy*w : (yy+1)*w]
			am := mask[yy*w : (yy+1)*w]
			pl, ol, orr, prr := row_pl[yy], row_ol[yy], row_or[yy], row_pr[yy]
			copy(dst, prst)
			if pl < 0 {
				continue
			}
			if orr > ol {
				copy(dst[ol:orr], src[ol:orr])
			}
			for xx in pl ..< ol {
				a := int(am[xx])
				dst[xx] = byte(div255(int(src[xx])*a + int(prst[xx])*(255-a)))
			}
			for xx in orr ..< prr {
				a := int(am[xx])
				dst[xx] = byte(div255(int(src[xx])*a + int(prst[xx])*(255-a)))
			}
		}
		for yy in 0 ..< ch2 {
			du := strip[uoff+(cy0+yy)*(BG_W/2)+cx0 : uoff+(cy0+yy)*(BG_W/2)+cx0+cw2]
			dv := strip[voff+(cy0+yy)*(BG_W/2)+cx0 : voff+(cy0+yy)*(BG_W/2)+cx0+cw2]
			pu := pru[yy*cw2 : (yy+1)*cw2]
			pv := prv[yy*cw2 : (yy+1)*cw2]
			srcu := su[yy*cw2 : (yy+1)*cw2]
			srcv := sv[yy*cw2 : (yy+1)*cw2]
			copy(du, pu)
			copy(dv, pv)
			pl, ol, orr, prr := c_pl[yy], c_ol[yy], c_or[yy], c_pr[yy]
			if pl < 0 {
				continue
			}
			if orr > ol {
				copy(du[ol:orr], srcu[ol:orr])
				copy(dv[ol:orr], srcv[ol:orr])
			}
			for xx in pl ..< ol {
				a := int(ca[yy*cw2+xx])
				du[xx] = byte(div255(int(srcu[xx])*a + int(pu[xx])*(255-a)))
				dv[xx] = byte(div255(int(srcv[xx])*a + int(pv[xx])*(255-a)))
			}
			for xx in orr ..< prr {
				a := int(ca[yy*cw2+xx])
				du[xx] = byte(div255(int(srcu[xx])*a + int(pu[xx])*(255-a)))
				dv[xx] = byte(div255(int(srcv[xx])*a + int(pv[xx])*(255-a)))
			}
		}
		if _, werr := os.write(of, strip); werr != nil {
			fmt.eprintf("deckcast: composite: write failed: %v\n", werr)
			return false
		}
	}
	return true
}
