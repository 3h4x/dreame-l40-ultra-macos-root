#!/usr/bin/env python3
"""DRAM parameters of an Allwinner MR813 fsbl (boot0 in FEL mode), and which set it actually used.

The header holds a default parameter block (32 words at 0x38: clk, type, ...); the DRAM.ext block holds board-ID
GPIO descriptors and more sets. The fsbl picks a set ("vaild para:%d select dram para%d" / "dram para%d invalid use
default para"), initialises DRAM and writes the parameters it used back into SRAM ("dram return write ok"): as seen
on this robot on 2026-09-25, a block "DRAM" + u32 1 + the 32 words, at 0x340 (over the start of DRAM.ext), where
`sunxi-fel read 0x28000` can fetch it.

  fsblparams.py FSBL                 print the header default and the DRAM.ext sets
  fsblparams.py FSBL READBACK        compare what the robot wrote back; last line: verdict=ext<N>|default|other
  fsblparams.py --header-only A B    exit 0 if A and B differ only inside the header default block
"""
import struct
import sys

TYPES = {3: "DDR3", 4: "DDR4", 7: "LPDDR3", 8: "LPDDR4"}
HDR = 0x38          # default dram_para in the header
WORDS = 32          # 0x80 bytes per parameter set
# Filled in by DRAM init itself (size/rank/width autoscan, training), so not usable to tell sets apart.
SCANNED = {6, 7, 28, 29, 30}   # dram_para1, dram_para2, dram_tpr11, dram_tpr12, dram_tpr13
RETURN_MAGIC = b"DRAM\x01\x00\x00\x00"   # the write-back block; "DRAM.ext" in the file does not match it


def words(data, off):
    return list(struct.unpack_from(f"<{WORDS}I", data, off))


def ext_sets(data):
    i = data.find(b"DRAM.ext")
    if i < 0:
        return []
    base = i + 8 + 4 + 4 * 8    # magic, ext header word, 4 GPIO descriptors of 8 bytes
    sets = []
    while base + WORDS * 4 <= len(data):
        w = words(data, base)
        if w[0] == 0 and w[1] == 0:
            break
        sets.append((base, w))
        base += WORDS * 4
    return sets


def describe(w):
    return f"clk={w[0]} MHz type={w[1]} ({TYPES.get(w[1], '?')}) mr0={w[8]:#x}"


def same(a, b):
    return all(a[k] == b[k] for k in range(WORDS) if k not in SCANNED)


def main(argv):
    if len(argv) == 4 and argv[1] == "--header-only":
        a, b = open(argv[2], "rb").read(), open(argv[3], "rb").read()
        diff = [i for i in range(max(len(a), len(b))) if i >= len(a) or i >= len(b) or a[i] != b[i]]
        ok = len(a) == len(b) and all(HDR <= i < HDR + WORDS * 4 for i in diff)
        print(f"{len(diff)} differing bytes, {'all inside' if ok else 'NOT only inside'} the header default block")
        return 0 if ok else 1
    if len(argv) not in (2, 3):
        print(__doc__)
        return 2
    fsbl = open(argv[1], "rb").read()
    default = words(fsbl, HDR)
    sets = ext_sets(fsbl)
    print(f"header default: {describe(default)}")
    for n, (off, w) in enumerate(sets):
        print(f"DRAM.ext set {n} @{off:#x}: {describe(w)}")
    if len(argv) == 2:
        return 0
    back = open(argv[2], "rb").read()
    wb = back.find(RETURN_MAGIC)
    if wb < 0 or fsbl.find(RETURN_MAGIC) == wb:
        print("no DRAM write-back block in the read-back: the fsbl did not report what it used")
        print("type=unknown")
        print("verdict=none")
        return 0
    used = words(back, wb + len(RETURN_MAGIC))
    print(f"robot used (write-back @{wb:#x}): {describe(used)}  para1={used[6]:#x} para2={used[7]:#x} "
          f"tpr13={used[30]:#x}")
    verdict = "other"
    for n, (_, w) in enumerate(sets):
        if same(used, w) and not same(used, default):
            verdict = f"ext{n}"
    if verdict == "other" and same(used, default):
        verdict = "default"
    print(f"type={used[1]}")
    print(f"verdict={verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
