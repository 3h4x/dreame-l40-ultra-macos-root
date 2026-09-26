"""Simulated eMMC for the tests: partitions written by `flash:` (raw or Android sparse) are kept as files, and an
`upload` stage is rebuilt from them at this robot's GPT offsets and XOR-encrypted like the real payload does."""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
from dustdecrypt import key_table, xor_blocks  # noqa: E402

STAGE = 418381824
OFFSETS = {"toc1": 0x00c00000, "boot1": 0x015c0000, "rootfs1": 0x033c0000, "boot2": 0x0fbc0000, "rootfs2": 0x119c0000}
SIZES = {"toc1": 4 << 20, "boot1": 30 << 20, "boot2": 30 << 20, "rootfs1": 200 << 20, "rootfs2": 200 << 20}
SPARSE_MAGIC = 0xED26FF3A
_key = None


def apply_sparse(img, data):
    _magic, major, _minor, fhdr, chdr, blk, total_blks, total_chunks, _ = struct.unpack_from("<IHHHHIIII", data)
    if major != 1 or fhdr != 28 or chdr != 12:
        return "sparse: incompatible format"
    if total_blks * blk > len(img):
        return "sparse: image larger than partition"
    off, pos = fhdr, 0
    for _ in range(total_chunks):
        ctype, _r, csz, tsz = struct.unpack_from("<HHII", data, off)
        body = data[off + chdr: off + tsz]
        n = csz * blk
        if ctype == 0xCAC1:
            if len(body) != n:
                return "sparse: bad chunk size for chunk, type Raw"
            img[pos:pos + n] = body
        elif ctype == 0xCAC2:
            img[pos:pos + n] = body[:4] * (n // 4)
        elif ctype not in (0xCAC3, 0xCAC4):
            return f"sparse: unknown chunk ID {ctype:x}"
        pos += n
        off += tsz
    return None


def write(partdir, part, data):
    """Applies one flash: to partdir/part.img; returns None or an error string."""
    path = os.path.join(partdir, part + ".img")
    img = bytearray(open(path, "rb").read()) if os.path.exists(path) else bytearray(SIZES[part])
    if len(data) >= 28 and struct.unpack_from("<I", data)[0] == SPARSE_MAGIC:
        err = apply_sparse(img, data)
        if err:
            return err
    elif len(data) > len(img):
        return "image too large"
    else:
        img[:len(data)] = data
    open(path, "wb").write(img)
    return None


def stage(partdir, n):
    """The encrypted bytes `upload` returns for stage n."""
    global _key
    if _key is None:
        _key = key_table()
    buf = bytearray(STAGE)
    base = n * STAGE
    for part, off in OFFSETS.items():
        path = os.path.join(partdir, part + ".img")
        if not os.path.exists(path):
            continue
        data = open(path, "rb").read()
        lo, hi = max(off, base), min(off + len(data), base + STAGE)
        if lo < hi:
            buf[lo - base:hi - base] = data[lo - off:hi - off]
    return xor_blocks(bytes(buf), _key)


if __name__ == "__main__":   # CLI for the shell mock: flashsim.py write DIR PART FILE | stage DIR N OUT
    if sys.argv[1] == "write":
        err = write(sys.argv[2], sys.argv[3], open(sys.argv[4], "rb").read())
        if err:
            sys.exit("FAILED " + err)
    elif sys.argv[1] == "stage":
        open(sys.argv[4], "wb").write(stage(sys.argv[2], int(sys.argv[3])))
