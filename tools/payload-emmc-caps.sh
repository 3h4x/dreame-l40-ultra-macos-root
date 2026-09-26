#!/bin/bash
# Copy of the job's payload.bin whose U-Boot may not use HS400/HS200/DDR on the eMMC (sdc2) -> plain HS 52 MHz.
# Only the device tree at 2 MiB changes; the payload has no checksum (stamp 0x5f0a6c39, length 0).
#   tools/payload-emmc-caps.sh IN OUT
set -eu
IN=$1 OUT=$2
OFF=2097152
NODE=/soc@03000000/sdmmc@04022000
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

python3 - "$IN" "$T/orig.dtb" "$OFF" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read(); off = int(sys.argv[3])
assert d[4:9] == b'uboot' and d[off:off+4] == b'\xd0\x0d\xfe\xed', 'unexpected payload layout'
size = struct.unpack('>I', d[off+4:off+8])[0]
open(sys.argv[2], 'wb').write(d[off:off+size])
EOF

cp "$T/orig.dtb" "$T/new.dtb"
for p in mmc-hs400-1_8v mmc-hs200-1_8v mmc-ddr-1_8v; do fdtput -d "$T/new.dtb" "$NODE" "$p"; done
dtc -I dtb -O dts -o "$T/orig.dts" "$T/orig.dtb" 2>/dev/null
dtc -I dtb -O dts -o "$T/new.dts" "$T/new.dtb" 2>/dev/null
diff "$T/orig.dts" "$T/new.dts" || true

python3 - "$IN" "$T/orig.dtb" "$T/new.dtb" "$OUT" "$OFF" <<'EOF'
import sys
p = bytearray(open(sys.argv[1], 'rb').read())
old = open(sys.argv[2], 'rb').read(); new = open(sys.argv[3], 'rb').read(); off = int(sys.argv[5])
assert len(new) <= len(old)
p[off:off+len(old)] = new + b'\0' * (len(old) - len(new))
open(sys.argv[4], 'wb').write(p)
o = open(sys.argv[1], 'rb').read()
diff = [i for i in range(len(o)) if o[i] != p[i]]
assert diff and off <= min(diff) and max(diff) < off + len(old), 'change outside the dtb'
print(f'{sys.argv[4]}: {len(diff)} bytes differ, all inside the dtb at {off:#x}')
EOF
shasum -a 256 "$OUT"
