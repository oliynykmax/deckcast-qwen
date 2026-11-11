package main

// Circular webcam mask, generated directly as raw gray bytes (no PNG, no
// ImageMagick). 4x4 supersampling per pixel gives the same soft edge the
// reference gets from drawing at 4x and downscaling. The ellipse is
// inscribed in the w x h rect PowerPoint gave the video shape.

make_ellipse_mask :: proc(w, h: int) -> []byte {
	data := make([]byte, w*h)
	cx := f64(w) / 2
	cy := f64(h) / 2
	rx := f64(w) / 2
	ry := f64(h) / 2
	for py in 0 ..< h {
		for px in 0 ..< w {
			count := 0
			for sy in 0 ..< 4 {
				dy := (f64(py) + (f64(sy) + 0.5) / 4 - cy) / ry
				dy2 := dy * dy
				for sx in 0 ..< 4 {
					dx := (f64(px) + (f64(sx) + 0.5) / 4 - cx) / rx
					if dx*dx+dy2 <= 1.0 {
						count += 1
					}
				}
			}
			data[py*w + px] = byte(count * 255 / 16)
		}
	}
	return data
}
