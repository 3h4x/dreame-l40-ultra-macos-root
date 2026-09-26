#!/bin/bash
# Stand-in for build/fbtool and sunxi-fel in tests: never touches USB, appends every call to $MOCK/calls.
# The "robot" appears in fastboot after `exe 0x4a000000`. MOCK_FAIL="flash rootfs1 3" fails the 3rd
# `flash rootfs1`; MOCK_CONFIG is the config the robot reports,
# MOCK_TOC1HASH its toc1hash. MOCK_DRAM decides what the fsbl writes
# back into SRAM: ext1 (default; it picked DRAM.ext set 1, the DDR4 one) or header (it used its header default).
# Flashes really land in $MOCK/parts via tests/flashsim.py, and `upload` returns the encrypted stage built from them;
# MOCK_CORRUPT=PART flips one byte of PART after it is written, as a bad write would.
set -u
M=$MOCK
case $(basename "$0") in
  mock-fel.sh)
    echo "fel $*" >> "$M/calls"
    case $1 in
      write) [ "$2" = 0x28000 ] && cp "$3" "$M/sram.bin" ;;
      exe) [ "$2" = 0x4a000000 ] && touch "$M/fastboot-up" ;;
      read)
        python3 - "$M/sram.bin" "$4" "${MOCK_DRAM:-ext1}" <<'EOF'
import sys
# Like the real robot (2026-09-25): the header stays as loaded, and a "DRAM" + u32 1 + 32-word block with the
# parameters actually used is written at 0x340, over the start of DRAM.ext.
d = bytearray(open(sys.argv[1], "rb").read())
if sys.argv[3] == "ext1":
    i = d.find(b"DRAM.ext") + 8 + 4 + 32 + 0x80        # set 1
    s = bytearray(d[i:i + 0x80])
    s[28:32] = (0x02000001).to_bytes(4, "little")        # para2 as autoscan would set it
else:
    s = bytearray(d[0x38:0xb8])
d[0x340:0x348 + 0x80] = b"DRAM\x01\x00\x00\x00" + s
open(sys.argv[2], "wb").write(d[:0x800])
EOF
        ;;
    esac
    exit 0 ;;
esac

cmd="$*"
case $1 in
  devices) [ -f "$M/fastboot-up" ] && echo "libusb	fastboot"; exit 0 ;;
  getvar)
    case $2 in
      config) echo "config: ${MOCK_CONFIG:?}" ;;
      max-download-size) echo "max-download-size: 0x02000000" ;;
      toc1hash) echo "toc1hash: ${MOCK_TOC1HASH:?}" ;;   # toc1 header of the image; the same before and after
      *) echo "$2: x" ;;
    esac
    exit 0 ;;
esac

# Everything below would change the robot: it must carry FBTOOL_WRITE=1, like the real tool.
case $1 in
  flash|reboot) [ "${FBTOOL_WRITE:-}" = 1 ] || { echo "refused" >&2; exit 3; } ;;
  oem) [ "$2" = dust ] || [ "$2" = prep ] && { [ "${FBTOOL_WRITE:-}" = 1 ] || { echo "refused" >&2; exit 3; }; } ;;
esac
SIM=$(dirname "$0")/flashsim.py
[ -f "$SIM" ] || SIM=$(dirname "$(readlink "$0")")/flashsim.py
if [ "$1" = flash ]; then   # flash PART FILE... : one line per piece in calls, like one download+flash:PART each
  part=$2; shift 2
  mkdir -p "$M/parts"
  for f in "$@"; do
    echo "flash $part $(basename "$f")" >> "$M/calls"
    if [ -n "${MOCK_FAIL:-}" ]; then
      read -r _ fpart fn <<< "$MOCK_FAIL"
      n=$(grep -c "^flash $fpart " "$M/calls")
      [ "$part" = "$fpart" ] && [ "$n" = "$fn" ] && { echo "FAILED flash:$part: mock" >&2; exit 1; }
    fi
    python3 "$SIM" write "$M/parts" "$part" "$f" || exit 1
  done
  if [ "${MOCK_CORRUPT:-}" = "$part" ]; then
    printf '\xff' | dd of="$M/parts/$part.img" bs=1 seek=4096 conv=notrunc 2>/dev/null
  fi
  echo OKAY
  exit 0
fi
case $1 in
  download) cmd="download $(basename "$2")" ;;
  upload) cmd="upload" ;;
esac
echo "$cmd" >> "$M/calls"
case $1 in
  upload) mkdir -p "$M/parts"; python3 "$SIM" stage "$M/parts" "$(cat "$M/stage" 2>/dev/null || echo 0)" "$2" || exit 1 ;;
  oem) case $2 in stage1|stage2) echo "${2#stage}" > "$M/stage" ;; esac ;;
esac
echo OKAY
