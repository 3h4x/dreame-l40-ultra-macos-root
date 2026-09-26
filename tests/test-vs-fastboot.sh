#!/bin/bash
# Differential test: the guide's sequence with Google's fastboot vs `flash.sh flash` with our fbtool, each against
# its own tests/fake-robot.py (fastboot over TCP). Passes if, from the first command to the last flash, both robots received
# the same commands in the same order (getvar prelude included) with byte-identical downloads, and both ended with
# partitions equal to the images.
# Needs `flash.sh prepare`, and Google platform-tools fastboot (FASTBOOT=..., default ~/dreame-l40/tools/...).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
DATA_REAL=${DATA:-$HOME/dreame-l40}
FASTBOOT=${FASTBOOT:-$DATA_REAL/tools/platform-tools/fastboot}
W=$DATA_REAL/fel
T=$(mktemp -d "${TMPDIR:-/tmp}/vsfastboot.XXXXXX")
JOB_REAL=${JOB:-$DATA_REAL/job}
export FAKE_CHECK=$(tr -d '\r\n' < "$W/check.txt")
export FAKE_CONFIG=$(sed -n "s/^echo '\\([0-9a-f]*\\)' > configvalue$/\\1/p" "$JOB_REAL/_buildflags.sh")
export FAKE_TOC1HASH=$(xxd -p -l 4 "$W/toc1.img")$(xxd -p -s 16 -l 8 "$W/toc1.img")
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

start_robot() {  # port outdir [gate]
  python3 "$REPO/tests/fake-robot.py" "$@" > "$2.server" 2>&1 &
  PIDS+=($!)
  for i in $(seq 1 50); do grep -q ready "$2.server" 2>/dev/null && return; sleep 0.1; done
  echo "fake robot on $1 did not start"; cat "$2.server"; exit 1
}

# A: what everyone else runs (Valetudo guide, phase 2), Google fastboot 37.0.1.
start_robot 15555 "$T/A"
FB_A=("$FASTBOOT" -s tcp:127.0.0.1:15555)
{
  "${FB_A[@]}" getvar config
  "${FB_A[@]}" oem dust "$(cat "$W/check.txt" | tr -d '\r\n')"
  "${FB_A[@]}" oem prep
  "${FB_A[@]}" flash toc1 "$W/toc1.img"
  "${FB_A[@]}" flash boot1 "$W/boot.img"
  "${FB_A[@]}" flash rootfs1 "$W/rootfs.img"
  "${FB_A[@]}" flash boot2 "$W/boot.img"
  "${FB_A[@]}" flash rootfs2 "$W/rootfs.img"
} > "$T/A.out" 2>&1 || fail "google fastboot run (see $T/A.out)"

# B: our route, unchanged flash.sh + the real fbtool binary; only FEL is mocked. The fake robot refuses
# connections until the mock FEL has "started the payload", like the real one.
mkdir -p "$T/B.mock" "$T/B.data/logs"
ln -s "$W" "$T/B.data/fel"; ln -s "$DATA_REAL/stage1" "$T/B.data/stage1"; ln -s "$JOB_REAL" "$T/B.data/job"
ln -s "$DATA_REAL/dust-fel-mr813.tar.gz" "$T/B.data/dust-fel-mr813.tar.gz"
echo "verdict=ext1" > "$T/B.data/logs/fsbl-probe.result"
ln -s "$REPO/tests/mock-fbtool.sh" "$T/mock-fel.sh"
start_robot 15556 "$T/B" "$T/B.mock/fastboot-up"
MOCK=$T/B.mock DATA=$T/B.data FEL=$T/mock-fel.sh FB=$REPO/build/fbtool FBTOOL_TCP=127.0.0.1:15556 \
  "$REPO/scripts/flash.sh" flash > "$T/B.out" 2>&1 || fail "flash.sh with fbtool (see $T/B.out)"

# Compare.
python3 - "$T" "$W" <<'EOF' || fails=$((fails + 1))
import json, sys, hashlib
t, w = sys.argv[1], sys.argv[2]
def seq(side):
    # Everything from the first command (`getvar config`) to the last `flash:`, getvars included: the stream the
    # payload sees must be identical to Google fastboot's. (After the last flash, flash.sh reads the flash back with
    # getvar toc1hash/upload/oem stage — the guide reboots instead.)
    rs = [json.loads(line) for line in open(f"{t}/{side}/transcript.jsonl")]
    last = max(i for i, r in enumerate(rs) if r["cmd"].startswith("flash:"))
    return [(r["cmd"], r.get("size"), r.get("sha256"), r.get("result")) for r in rs[:last + 1]]
a, b = seq("A"), seq("B")
print(f"google fastboot: {len(a)} commands from the first to the last flash, fbtool: {len(b)}")
bad = 0
if a != b:
    bad = 1
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else None
        y = b[i] if i < len(b) else None
        print(f"  {'==' if x == y else '!='} {i:2} fastboot={x}\n{'':8}fbtool  ={y}")
else:
    print("IDENTICAL: same commands, same order, byte-identical downloads, same results")
    for c, size, sha, res in a:
        print(f"  {c:22} {'' if size is None else f'{size:>10} B sha256 {sha[:16]}…'} {res or ''}")
imgs = {"toc1": "toc1.img", "boot1": "boot.img", "boot2": "boot.img", "rootfs1": "rootfs.img", "rootfs2": "rootfs.img"}
for side in "AB":
    for part, img in imgs.items():
        want = open(f"{w}/{img}", "rb").read()
        got = open(f"{t}/{side}/{part}.img", "rb").read()
        ok = got[:len(want)] == want and not any(got[len(want):])
        if not ok:
            bad = 1
        print(f"  {side} {part:8} {'== ' + img if ok else 'DIFFERS from ' + img}")
sys.exit(bad)
EOF

grep -q "verify=ok" "$T/B.out" || fail "flash.sh read-back verification (see $T/B.out)"
echo "-- flash.sh read-back:"; grep -E "^\[.*\]    (toc1|boot|rootfs|verify)" "$T/B.out"
echo "-- google fastboot said:"; grep -E "Sending|Writing|OKAY|FAIL" "$T/A.out" | head -40
echo "== $fails failure(s); details in $T"
[ $fails = 0 ]
