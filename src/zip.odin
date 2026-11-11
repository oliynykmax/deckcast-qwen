package main

// Minimal ZIP reader/writer, data-oriented: the whole archive is one byte
// slice, entries are a flat array of offsets into it. PowerPoint stores the
// big webcam clips uncompressed (method 0), so extraction is a plain copy;
// XML parts are usually deflated (method 8) and go through core:compress/zlib.
// The writer emits stored entries only, which is all LibreOffice needs.

import "core:bytes"
import "core:compress/zlib"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

Zip_Entry :: struct {
	name:         string,
	method:       u16,
	crc:          u32,
	comp_size:    u32,
	uncomp_size:  u32,
	local_offset: u32,
}

Zip_Archive :: struct {
	raw:     []byte,
	entries: []Zip_Entry,
}

rd_u16 :: proc(b: []byte, off: int) -> u16 {
	return u16(b[off]) | u16(b[off + 1]) << 8
}

rd_u32 :: proc(b: []byte, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}

zip_open :: proc(path: string) -> (zip: Zip_Archive, ok: bool) {
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintf("deckcast: cannot read %s: %v\n", path, err)
		return
	}
	zip.raw = raw

	// End of central directory: scan backwards over the possible comment span.
	eocd := -1
	lo := max(0, len(raw)-22-65535)
	for i := len(raw) - 22; i >= lo; i -= 1 {
		if rd_u32(raw, i) == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 {
		fmt.eprintf("deckcast: %s is not a zip file (no EOCD)\n", path)
		return
	}
	count := int(rd_u16(raw, eocd + 10))
	cd_off := int(rd_u32(raw, eocd + 16))
	if rd_u32(raw, eocd + 16) == 0xFFFFFFFF {
		fmt.eprintf("deckcast: zip64 archives are not supported\n")
		return
	}

	zip.entries = make([]Zip_Entry, count)
	p := cd_off
	for i in 0 ..< count {
		if p + 46 > len(raw) || rd_u32(raw, p) != 0x02014b50 {
			fmt.eprintf("deckcast: corrupt central directory at %d\n", p)
			return
		}
		e := &zip.entries[i]
		e.method = rd_u16(raw, p + 10)
		e.crc = rd_u32(raw, p + 16)
		e.comp_size = rd_u32(raw, p + 20)
		e.uncomp_size = rd_u32(raw, p + 24)
		name_len := int(rd_u16(raw, p + 28))
		extra_len := int(rd_u16(raw, p + 30))
		comment_len := int(rd_u16(raw, p + 32))
		e.local_offset = rd_u32(raw, p + 42)
		e.name = string(raw[p + 46 : p + 46 + name_len])
		p += 46 + name_len + extra_len + comment_len
	}
	ok = true
	return
}

zip_find :: proc(zip: ^Zip_Archive, name: string) -> (entry: ^Zip_Entry, found: bool) {
	for &e in zip.entries {
		if e.name == name {
			return &e, true
		}
	}
	return nil, false
}

// Offset of the entry's payload inside the raw archive (local header size varies).
zip_data_offset :: proc(zip: ^Zip_Archive, e: ^Zip_Entry) -> int {
	off := int(e.local_offset)
	name_len := int(rd_u16(zip.raw, off + 26))
	extra_len := int(rd_u16(zip.raw, off + 28))
	return off + 30 + name_len + extra_len
}

// Returns the uncompressed bytes. Stored entries alias the archive memory;
// deflated entries are freshly allocated and must be delete[]d by the caller.
zip_entry_data :: proc(zip: ^Zip_Archive, e: ^Zip_Entry) -> (data: []byte, allocated: bool, ok: bool) {
	start := zip_data_offset(zip, e)
	comp := zip.raw[start : start + int(e.comp_size)]
	if e.method == 0 {
		return comp, false, true
	}
	if e.method != 8 {
		fmt.eprintf("deckcast: unsupported zip method %d for %s\n", e.method, e.name)
		return
	}
	buf: bytes.Buffer
	if err := zlib.inflate_from_byte_array(comp, &buf, raw = true, expected_output_size = int(e.uncomp_size)); err != nil {
		fmt.eprintf("deckcast: inflate failed for %s: %v\n", e.name, err)
		return
	}
	return bytes.buffer_to_bytes(&buf), true, true
}

Zip_Write_Entry :: struct {
	name: string,
	data: []byte,
}

wr_u16 :: proc(b: []byte, off: int, v: u16) {
	b[off] = byte(v)
	b[off + 1] = byte(v >> 8)
}

wr_u32 :: proc(b: []byte, off: int, v: u32) {
	b[off] = byte(v)
	b[off + 1] = byte(v >> 8)
	b[off + 2] = byte(v >> 16)
	b[off + 3] = byte(v >> 24)
}

// Writes a zip with stored (uncompressed) entries. Fast, and LibreOffice
// reads it fine. All sizes fit u32 for a media-less deck.
zip_write_stored :: proc(path: string, entries: []Zip_Write_Entry) -> bool {
	total := 22
	for &e in entries {
		total += 30 + len(e.name) + len(e.data) + 46 + len(e.name)
	}
	out := make([]byte, total)
	p := 0
	cd_start := 0
	_ = cd_start

	// Local headers + payloads.
	for &e in entries {
		wr_u32(out, p, 0x04034b50)
		wr_u16(out, p + 4, 20) // version needed
		wr_u16(out, p + 6, 0) // flags
		wr_u16(out, p + 8, 0) // method: stored
		wr_u16(out, p + 10, 0) // mod time
		wr_u16(out, p + 12, 0x0021) // mod date: 1980-01-01
		wr_u32(out, p + 14, hash.crc32(e.data))
		wr_u32(out, p + 18, u32(len(e.data)))
		wr_u32(out, p + 22, u32(len(e.data)))
		wr_u16(out, p + 26, u16(len(e.name)))
		wr_u16(out, p + 28, 0)
		copy(out[p+30:], e.name)
		copy(out[p+30+len(e.name):], e.data)
		p += 30 + len(e.name) + len(e.data)
	}

	// Central directory.
	cd_start = p
	for &e in entries {
		wr_u32(out, p, 0x02014b50)
		wr_u16(out, p + 4, 20) // version made by
		wr_u16(out, p + 6, 20) // version needed
		wr_u16(out, p + 8, 0)
		wr_u16(out, p + 10, 0)
		wr_u16(out, p + 12, 0)
		wr_u16(out, p + 14, 0x0021)
		wr_u32(out, p + 16, hash.crc32(e.data))
		wr_u32(out, p + 20, u32(len(e.data)))
		wr_u32(out, p + 24, u32(len(e.data)))
		wr_u16(out, p + 28, u16(len(e.name)))
		// extra/comment/disk/attrs stay zero
		wr_u32(out, p + 42, 0) // local offset, patched below
		copy(out[p+46:], e.name)
		p += 46 + len(e.name)
	}

	// Patch local offsets (second pass over the entries, same order).
	lp := 0
	cp := cd_start
	for &e in entries {
		wr_u32(out, cp + 42, u32(lp))
		lp += 30 + len(e.name) + len(e.data)
		cp += 46 + len(e.name)
	}

	// EOCD.
	wr_u32(out, p, 0x06054b50)
	wr_u16(out, p + 8, u16(len(entries)))
	wr_u16(out, p + 10, u16(len(entries)))
	wr_u32(out, p + 12, u32(p - cd_start))
	wr_u32(out, p + 16, u32(cd_start))

	if err := os.write_entire_file(path, out); err != nil {
		fmt.eprintf("deckcast: cannot write %s: %v\n", path, err)
		return false
	}
	delete(out)
	return true
}

// Normalizes a zip-internal path: resolves "." and ".." segments.
path_normalize :: proc(path: string) -> string {
	parts := strings.split(path, "/")
	defer delete(parts)
	out: [dynamic]string
	for part in parts {
		switch part {
		case "", ".":
			continue
		case "..":
			if len(out) > 0 {
				pop(&out)
			}
		case:
			append(&out, part)
		}
	}
	return strings.join(out[:], "/")
}
