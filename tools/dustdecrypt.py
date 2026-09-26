#!/usr/bin/env python3
"""Decrypts the stage 1 samples (dustx100-102.bin): XOR-encrypted dumps of the start of the robot's eMMC.

Per Max Ammann's reversing of the dustbuilder payload (maxammann.org/posts/2025/06/dreame-fel-mode/): the key table
is 0x20000 bytes, seeded with MD5 of the 4 bytes c9 ac bc c6, then 0x2000 rounds each writing
MD5(table[0:0x20000]) to table[16*i:16*i+16]; every 512-byte block b of a dump is XORed with
table[(b & 0xff) * 0x200 : +0x200]. The key does not depend on the serial number.

  dustdecrypt.py IN OUT [--check]   decrypt IN to OUT; --check only decrypts the first 64 KiB and looks for GPT
"""
import hashlib
import sys

BLOCK = 0x200


def key_table(seed=bytes.fromhex("c9acbcc6")):
    table = bytearray(0x20000)
    table[0:16] = hashlib.md5(seed).digest()
    for i in range(0x2000):
        table[16 * i:16 * i + 16] = hashlib.md5(table).digest()
    return bytes(table)


def xor_blocks(data, key, first_block=0):
    out = bytearray(len(data))
    for off in range(0, len(data), BLOCK):
        b = first_block + off // BLOCK
        k = key[(b & 0xff) * BLOCK:(b & 0xff) * BLOCK + BLOCK]
        chunk = data[off:off + BLOCK]
        out[off:off + len(chunk)] = (int.from_bytes(chunk, "little") ^ int.from_bytes(k[:len(chunk)], "little")
                                     ).to_bytes(len(chunk), "little")
    return bytes(out)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    key = key_table()
    src, dst = sys.argv[1], sys.argv[2]
    if "--check" in sys.argv:
        head = xor_blocks(open(src, "rb").read(0x10000), key)
        open(dst, "wb").write(head)
        print("GPT header at 0x200:", head[0x200:0x208] == b"EFI PART", head[0x200:0x208])
        return
    with open(src, "rb") as f, open(dst, "wb") as o:
        b = 0
        while True:
            chunk = f.read(0x100000)
            if not chunk:
                break
            o.write(xor_blocks(chunk, key, b))
            b += len(chunk) // BLOCK


if __name__ == "__main__":
    main()
