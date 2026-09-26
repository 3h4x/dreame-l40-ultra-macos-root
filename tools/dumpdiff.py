#!/usr/bin/env python3
"""Porownuje swiezy zrzut `upload` (okno 0, bez `oem dust`) z pristine `dustx100.bin` i pokazuje, co zmienilo sie
na flashu od etapu 1 -- czysto diagnostycznie, bez dotykania robota.

Szyfrowanie `upload` jest pozycyjne (XOR, klucz z seeda c9acbcc6, okres 128 KiB, patrz tools/dustdecrypt.py), wiec
ten sam plaintext pod tym samym offsetem daje ten sam ciphertext w kazdej sesji BEZ `oem dust`. Dlatego bloki, ktore
sie roznia miedzy dwoma takimi zrzutami, to dokladnie to, co realnie zmienilo sie na eMMC.

  dumpdiff.py FRESH PRISTINE [--env DATA/plain/parts]   mapa roznic + (opcjonalnie) diff zmiennych U-Boot env

Partycje (GPT jak w README): env @0x14c0000, env-redund @0x1540000, boot1 @0x15c0000, rootfs1 @0x33c0000,
boot2 @0xfbc0000, rootfs2 @0x119c0000, toc1 @0xc00000 (backup 0x1004000).
"""
import hashlib
import sys

BLOCK = 0x200
PARTS = [
    (0x00002000, "boot0/toc0"), (0x000c0000, "(gap)"), (0x00c00000, "toc1"),
    (0x01004000, "toc1.backup"), (0x01480000, "boot-resource"), (0x014c0000, "env"),
    (0x01540000, "env-redund"), (0x015c0000, "boot1"), (0x033c0000, "rootfs1"),
    (0x0fbc0000, "boot2"), (0x119c0000, "rootfs2"),
]


def key_table(seed=bytes.fromhex("c9acbcc6")):
    t = bytearray(0x20000)
    t[0:16] = hashlib.md5(seed).digest()
    for i in range(0x2000):
        t[16 * i:16 * i + 16] = hashlib.md5(t).digest()
    return bytes(t)


KEY = key_table()


def xor(data, first_block):
    out = bytearray(len(data))
    for off in range(0, len(data), BLOCK):
        b = first_block + off // BLOCK
        k = KEY[(b & 0xff) * BLOCK:(b & 0xff) * BLOCK + BLOCK]
        c = data[off:off + BLOCK]
        out[off:off + len(c)] = (int.from_bytes(c, "little") ^ int.from_bytes(k[:len(c)], "little")
                                 ).to_bytes(len(c), "little")
    return bytes(out)


def partof(off):
    name = "(pre)"
    for o, n in PARTS:
        if off >= o:
            name = n
    return name


def parse_env(buf):
    for hdr in (4, 5):  # env = crc(4); env-redund = crc(4)+flag(1)
        body = buf[hdr:]
        end = body.find(b"\x00\x00")
        if end <= 0:
            continue
        kv, ok = {}, True
        for p in body[:end].split(b"\x00"):
            if not p:
                continue
            if b"=" not in p:
                ok = False
                break
            k, v = p.split(b"=", 1)
            kv[k.decode("latin1").lstrip("\x00-\x7f")] = v.decode("latin1")
        if ok and kv:
            return hdr, kv
    return None, {}


def blockdiff(fresh, pristine):
    BS = 65536
    fa, fb = open(fresh, "rb"), open(pristine, "rb")
    ranges, off, cur = [], 0, None
    while True:
        a, b = fa.read(BS), fb.read(BS)
        if not a and not b:
            break
        if a != b:
            cur = [off, off + len(a)] if cur is None else [cur[0], off + len(a)]
        elif cur is not None:
            ranges.append(cur)
            cur = None
        off += BS
    if cur is not None:
        ranges.append(cur)
    print(f"== mapa roznic {fresh} vs {pristine} ({off} B)")
    if not ranges:
        print("   BRAK roznic -- flash bajtowo identyczny z pristine")
    for s, e in ranges:
        print(f"   0x{s:08x}-0x{e:08x}  {(e - s) / 1048576:6.2f} MB  {partof(s)}")
    return ranges


def env_diff(fresh, parts_dir):
    def dec_slice(off, size):
        with open(fresh, "rb") as f:
            f.seek(off)
            return xor(f.read(size), off // BLOCK)
    for name, off in (("env", 0x14c0000), ("env-redund", 0x1540000)):
        _, fk = parse_env(dec_slice(off, 0x80000))
        try:
            _, fac = parse_env(open(f"{parts_dir}/{name}.img", "rb").read())
        except OSError:
            fac = {}
        keys = ("boot_partition", "root_partition", "boot_normal", "bootcmd")
        print(f"\n== {name}")
        if not fk:
            print("   swieza kopia NIE parsuje sie jako env (skasowana/przepisana)")
        for k in keys:
            if fk.get(k) != fac.get(k):
                print(f"   {k}: fabryka={fac.get(k)!r} -> teraz={fk.get(k)!r}")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ranges = blockdiff(sys.argv[1], sys.argv[2])
    if "--env" in sys.argv:
        env_diff(sys.argv[1], sys.argv[sys.argv.index("--env") + 1])
    return ranges


if __name__ == "__main__":
    main()
