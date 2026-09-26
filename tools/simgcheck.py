#!/usr/bin/env python3
"""Independent check of the sparse pieces made by fbsparse (no libsparse involved).

Parses every Android sparse image strictly (magic, version, header sizes, chunk sizes, block counts), checks each
piece fits in MAX bytes and covers the whole image, then replays all pieces onto one buffer in order, the way the
robot applies consecutive `flash:` calls, and compares the result with the original image.

usage: simgcheck.py MAX IMAGE PIECE...
"""
import hashlib
import struct
import sys

MAGIC = 0xED26FF3A
RAW, FILL, DONT_CARE, CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4


def fail(msg):
    sys.exit(f"FAILED {msg}")


def apply_piece(path, out, max_len):
    data = open(path, "rb").read()
    if len(data) > max_len:
        fail(f"{path}: {len(data)} B > max {max_len}")
    magic, major, minor, fhdr, chdr, blk, total_blks, total_chunks, _crc = struct.unpack_from("<IHHHHIIII", data)
    if magic != MAGIC or major != 1 or fhdr != 28 or chdr != 12 or blk != 4096:
        fail(f"{path}: bad header magic={magic:#x} v{major}.{minor} fhdr={fhdr} chdr={chdr} blk={blk}")
    if total_blks * blk != len(out):
        fail(f"{path}: covers {total_blks * blk} B, image is {len(out)} B")
    off, blocks, written = fhdr, 0, 0
    for i in range(total_chunks):
        ctype, _res, csz, tsz = struct.unpack_from("<HHII", data, off)
        body = data[off + chdr: off + tsz]
        pos = blocks * blk
        if ctype == RAW:
            if tsz != chdr + csz * blk:
                fail(f"{path}: chunk {i} raw size mismatch")
            out[pos: pos + csz * blk] = body
            written += csz
        elif ctype == FILL:
            if tsz != chdr + 4:
                fail(f"{path}: chunk {i} fill size mismatch")
            out[pos: pos + csz * blk] = body * (csz * blk // 4)
            written += csz
        elif ctype == DONT_CARE:
            if tsz != chdr:
                fail(f"{path}: chunk {i} dont-care size mismatch")
        elif ctype == CRC32:
            fail(f"{path}: chunk {i} is CRC32, fastboot sends none")
        else:
            fail(f"{path}: chunk {i} unknown type {ctype:#x}")
        blocks += csz
        off += tsz
    if blocks != total_blks or off != len(data):
        fail(f"{path}: chunks cover {blocks}/{total_blks} blocks, parsed {off}/{len(data)} B")
    return written * blk


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    max_len = int(sys.argv[1], 0)
    image = open(sys.argv[2], "rb").read()
    out = bytearray(len(image))
    total = 0
    for piece in sys.argv[3:]:
        n = apply_piece(piece, out, max_len)
        total += n
        print(f"{piece}: OK, writes {n} B")
    if total != len(image):
        fail(f"pieces write {total} B in total, image is {len(image)} B (overlap or gap)")
    if bytes(out) != image:
        fail("replayed pieces differ from the image")
    print(f"IDENTICAL {sys.argv[2]} sha256 {hashlib.sha256(image).hexdigest()}")


if __name__ == "__main__":
    main()
