#!/usr/bin/env python3
"""Checks what stage 3 wrote, before the reboot, from the payload's own flash read-back.

`fbtool upload` after `flash` returns the first 399 MiB of the eMMC (stage 0), `oem stage1` + `upload` the next
399 MiB, XOR-encrypted like the stage 1 samples (tools/dustdecrypt.py). This decrypts only the ranges stage 3 wrote
and compares them with the images. Offsets are this robot's GPT (README, "Stage 1 samples decrypted").

  verifyflash.py IMAGEDIR STAGE0 [STAGE1]    exit 0 if every range present matches, 1 on any mismatch
  verifyflash.py --stock PARTSDIR IMAGEDIR STAGE0 [STAGE1]
                                            after `flash.sh restore`: boot1, rootfs1, boot2, rootfs2 must equal the
                                            whole stock partitions PARTSDIR/<part>.img (toc1 still IMAGEDIR/toc1.img)
  --only a,b,...                            check only these partitions (e.g. a partial restore)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dustdecrypt import BLOCK, key_table, xor_blocks  # noqa: E402

STAGE = 418381824   # bytes per upload stage (0x18f00000)
PARTS = [("toc1", 0x00c00000, "toc1.img"), ("boot1", 0x015c0000, "boot.img"), ("rootfs1", 0x033c0000, "rootfs.img"),
         ("boot2", 0x0fbc0000, "boot.img"), ("rootfs2", 0x119c0000, "rootfs.img")]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    args = sys.argv[1:]
    stock, only = None, None
    while args and args[0] in ("--stock", "--only"):
        if args[0] == "--stock":
            stock = args[1]
        else:
            only = set(args[1].split(","))
        args = args[2:]
    imgdir, stages = args[0], args[1:]
    key = key_table()
    bad = 0
    for name, off, img in PARTS:
        if only and name not in only:
            continue
        path = os.path.join(stock, name + ".img") if stock and name != "toc1" else os.path.join(imgdir, img)
        want = open(path, "rb").read()
        checked, part_bad = 0, False
        for n, path in enumerate(stages):
            base = n * STAGE
            lo, hi = max(off, base), min(off + len(want), base + STAGE)
            if lo >= hi:
                continue
            if os.path.getsize(path) < STAGE:
                print(f"{name}: stage {n} file is short ({os.path.getsize(path)} B)")
                bad, part_bad = 1, True
                continue
            # decrypt whole 512-byte blocks covering [lo, hi)
            blo, bhi = (lo - base) // BLOCK * BLOCK, -(-(hi - base) // BLOCK) * BLOCK
            with open(path, "rb") as f:
                f.seek(blo)
                plain = xor_blocks(f.read(bhi - blo), key, blo // BLOCK)
            got = plain[lo - base - blo: hi - base - blo]
            exp = want[lo - off: hi - off]
            if got != exp:
                first = next(i for i in range(len(got)) if got[i] != exp[i])
                print(f"{name}: MISMATCH at partition offset {lo - off + first:#x}")
                bad, part_bad = 1, True
            checked += hi - lo
        if part_bad:
            print(f"{name}: BAD")
        elif checked == len(want):
            print(f"{name}: OK")
        else:
            print(f"{name}: OK so far, partial ({checked}/{len(want)} B checked)")
    print("verify=" + ("mismatch" if bad else "ok"))
    return bad


if __name__ == "__main__":
    sys.exit(main())
