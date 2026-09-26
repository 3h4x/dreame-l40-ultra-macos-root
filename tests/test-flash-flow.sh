#!/bin/bash
# Runs scripts/flash.sh against tests/mock-fbtool.sh (no USB, no robot) and checks the exact command sequence.
# Needs `scripts/flash.sh prepare` to have been run (uses $HOME/dreame-l40/fel and stage1 read-only).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
DATA_REAL=${DATA:-$HOME/dreame-l40}
T=$(mktemp -d "${TMPDIR:-/tmp}/flashtest.XXXXXX")
JOB_REAL=${JOB:-$DATA_REAL/job}
CHECK=$(tr -d '\r\n' < "$DATA_REAL/fel/check.txt")
export MOCK_CONFIG=$(sed -n "s/^echo '\\([0-9a-f]*\\)' > configvalue$/\\1/p" "$JOB_REAL/_buildflags.sh")
export MOCK_TOC1HASH=$(xxd -p -l 4 "$DATA_REAL/fel/toc1.img")$(xxd -p -s 16 -l 8 "$DATA_REAL/fel/toc1.img")
ln -s "$REPO/tests/mock-fbtool.sh" "$T/mock-fel.sh"
fails=0

setup() {  # dir [copy]: a fake $DATA with the real fel/ (linked or copied) and stage1/
  mkdir -p "$1/data/logs"
  if [ "${2:-}" = copy ]; then mkdir "$1/data/fel"; cp "$DATA_REAL"/fel/* "$1/data/fel/"
  else ln -s "$DATA_REAL/fel" "$1/data/fel"; fi
  ln -s "$DATA_REAL/stage1" "$1/data/stage1"
  ln -s "$JOB_REAL" "$1/data/job"
  ln -s "$DATA_REAL/dust-fel-mr813.tar.gz" "$1/data/dust-fel-mr813.tar.gz"
  [ -d "$DATA_REAL/plain" ] && ln -s "$DATA_REAL/plain" "$1/data/plain"
  [ -d "$DATA_REAL/restore" ] && ln -s "$DATA_REAL/restore" "$1/data/restore"
  [ "${SEED_PROBE-ext1}" != none ] && echo "verdict=${SEED_PROBE-ext1}" > "$1/data/logs/fsbl-probe.result"
  [ "${PRE_UP:-}" = 1 ] && touch "$1/fastboot-up"
  if [ -n "${SEED_STATE:-}" ]; then   # partitions already flashed earlier in this session
    printf '%s\n' $SEED_STATE > "$1/data/logs/flash.state"
    mkdir -p "$1/parts"
    for p in $SEED_STATE; do
      case $p in toc1) f=toc1.img ;; boot*) f=boot.img ;; *) f=rootfs.img ;; esac
      python3 "$REPO/tests/flashsim.py" write "$1/parts" "$p" "$DATA_REAL/fel/$f"
    done
  fi
  touch "$1/calls"
}

run() {  # name expected_rc args...
  local name=$1 want=$2; shift 2
  local d=$T/$name
  [ -d "$d" ] || setup "$d"
  MOCK=$d DATA=$d/data FB=$REPO/tests/mock-fbtool.sh FEL=$T/mock-fel.sh "$REPO/scripts/flash.sh" "$@" > "$d/out" 2>&1
  local rc=$?
  if [ "$rc" != "$want" ]; then echo "FAIL $name: rc=$rc, expected $want"; tail -5 "$d/out"; fails=$((fails + 1)); return 1; fi
}

expect_calls() {  # name, expected write calls (one per line)
  local got
  got=$(grep -vE '^(fel |download |upload$|oem stage[12]$)' "$T/$1/calls")
  if [ "$got" != "$2" ]; then
    echo "FAIL $1: write calls differ"; diff <(echo "$2") <(echo "$got") | head -20; fails=$((fails + 1))
  else echo "ok   $1"; fi
}

check() {  # name, description, command...
  local name=$1 what=$2; shift 2
  "$@" || { echo "FAIL $name: $what"; fails=$((fails + 1)); }
}

ROOTFS() { for i in 01 02 03 04; do echo "flash $1 rootfs.$i.simg"; done; }
FULL="oem dust $CHECK
oem prep
flash toc1 toc1.img
flash boot1 boot.img
$(ROOTFS rootfs1)
flash boot2 boot.img
$(ROOTFS rootfs2)"
no_payload() { ! grep -q '^fel .*0x4a000000' "$T/$1/calls"; }

# 1. Happy path: exactly the guide's sequence, pieces in order, and no reboot.
run happy 0 flash && expect_calls happy "$FULL"
check happy "no final summary" grep -q "GOTOWE BEZ RESTARTU" "$T/happy/out"
check happy "toc1hash not verified after flash" grep -q "toc1hash po: $MOCK_TOC1HASH = naglowek toc1.img" "$T/happy/out"
check happy "zip fsbl.bin not used" grep -q "^fel write 0x28000 .*/fel/fsbl.bin$" "$T/happy/calls"
check happy "no SRAM read-back before payload" grep -q "^fel read 0x28000" "$T/happy/calls"
check happy "flash not read back" grep -q "verify=ok" "$T/happy/out"
check happy "stage1 not read back" grep -qx "oem stage1" "$T/happy/calls"
check happy "no final GOTOWE" grep -q "GOTOWE BEZ RESTARTU" "$T/happy/out"

# 2. rootfs1 piece 3 fails: stop there, nothing after it, no reboot, tells how to resume.
MOCK_FAIL="flash rootfs1 3" run fail-rootfs1 1 flash && expect_calls fail-rootfs1 "oem dust $CHECK
oem prep
flash toc1 toc1.img
flash boot1 boot.img
flash rootfs1 rootfs.01.simg
flash rootfs1 rootfs.02.simg
flash rootfs1 rootfs.03.simg"
check fail-rootfs1 "no resume hint" grep -q "flash.sh resume rootfs1" "$T/fail-rootfs1/out"

# 3. Resume in a live session: no FEL, no dust/prep, rootfs1 again from piece 1, then the rest.
PRE_UP=1 SEED_STATE="toc1 boot1" run resume 0 resume rootfs1 && expect_calls resume "$(ROOTFS rootfs1)
flash boot2 boot.img
$(ROOTFS rootfs2)"
check resume "touched FEL" eval "! grep -q '^fel' '$T/resume/calls'"

# 4. Wrong robot/payload config: stop before any write.
MOCK_CONFIG=deadbeef run bad-config 1 flash && expect_calls bad-config ""

# 5. Rehearsal: only downloads, no write command at all. The mock flash holds the robot's real stock partitions
#    (decrypted stage 1 samples, if present), so the read-back must recognise the untouched state.
STOCK=$DATA_REAL/plain/parts
if [ -f "$STOCK/boot1.img" ]; then
  setup "$T/rehearse"; mkdir -p "$T/rehearse/parts"
  for p in boot1 rootfs1 boot2 rootfs2; do cp "$STOCK/$p.img" "$T/rehearse/parts/"; done
  dd if="$STOCK/boot0-toc0-toc1-area.img" of="$T/rehearse/parts/toc1.img" bs=1m skip=12 count=4 2>/dev/null
fi
run rehearse 0 rehearse && expect_calls rehearse ""
[ -f "$STOCK/boot1.img" ] && check rehearse "stock state not recognised" grep -q "wynik jak w probkach" "$T/rehearse/out"
check rehearse "downloads missing" grep -q '^download rootfs.01.simg$' "$T/rehearse/calls"
check rehearse "boot.img download missing" grep -q '^download boot.img$' "$T/rehearse/calls"

# 6. Fastboot already up from an unknown session: refuse before FEL and before writing.
PRE_UP=1 run stale-session 1 flash && expect_calls stale-session ""

# 7. Resume without a live session: refuse.
run resume-dead 1 resume boot2 && expect_calls resume-dead ""

# 8. Tampered piece after prepare is caught by the manifest (copy of fel dir, one byte changed).
setup "$T/tamper" copy
printf 'X' | dd of="$T/tamper/data/fel/rootfs.02.simg" bs=1 seek=5000 conv=notrunc 2>/dev/null
run tamper 1 flash && expect_calls tamper ""
check tamper "robot touched" eval "! grep -q . '$T/tamper/calls'"
check tamper "no manifest message" grep -q "zmienione od prepare" "$T/tamper/out"

# 9. Probe, fsbl picks the DRAM.ext DDR4 set: verdict ext1, stage1 fsbl only, no payload, nothing written.
SEED_PROBE=none run probe-ext1 0 probe && expect_calls probe-ext1 ""
check probe-ext1 "verdict not ext1" grep -qx "verdict=ext1" "$T/probe-ext1/data/logs/fsbl-probe.result"
check probe-ext1 "payload loaded" no_payload probe-ext1
check probe-ext1 "not the stage1 fsbl" grep -q "^fel write 0x28000 .*/stage1/fsbl_ddr4.bin$" "$T/probe-ext1/calls"

# 10. Probe, fsbl used its header default: verdict default.
SEED_PROBE=none MOCK_DRAM=header run probe-header 0 probe && expect_calls probe-header ""
check probe-header "verdict not default" grep -qx "verdict=default" "$T/probe-header/data/logs/fsbl-probe.result"

# 11. No probe result: the zip's (DDR3-default) fsbl.bin is refused before the robot is touched.
SEED_PROBE=none run no-probe 1 flash && expect_calls no-probe ""
check no-probe "robot touched" eval "! grep -q '^fel' '$T/no-probe/calls'"

# 12. Probe said default: same refusal.
SEED_PROBE=default run probe-default-flash 1 flash && expect_calls probe-default-flash ""

# 13. Probe said ext1 but this boot's read-back does not show the ext set: stop after the fsbl, before the payload.
MOCK_DRAM=header run readback-mismatch 1 flash && expect_calls readback-mismatch ""
check readback-mismatch "payload loaded" no_payload readback-mismatch

# 14. FSBL=ddr4 without a probe: stage1 fsbl_ddr4.bin (header default DDR4), full sequence.
SEED_PROBE=none FSBL=ddr4 MOCK_DRAM=header run fsbl-ddr4 0 flash && expect_calls fsbl-ddr4 "$FULL"
check fsbl-ddr4 "not the stage1 fsbl" grep -q "^fel write 0x28000 .*/stage1/fsbl_ddr4.bin$" "$T/fsbl-ddr4/calls"

# 15. A write that says OKAY but lands wrong (one byte of rootfs1): the read-back catches it, no GOTOWE, no reboot.
MOCK_CORRUPT=rootfs1 run corrupt 1 flash && expect_calls corrupt "$FULL"
check corrupt "rootfs1 not reported BAD" grep -q "rootfs1: BAD" "$T/corrupt/out"
check corrupt "said GOTOWE" eval "! grep -q 'GOTOWE BEZ RESTARTU' '$T/corrupt/out'"
check corrupt "no resume hint" grep -q "flash.sh resume <partycja>" "$T/corrupt/out"

# 16. Restore after a flash: the mock flash holds the rooted images; restore writes the stock partitions back
#     (dust, prep, boot1, 5 x rootfs1, boot2, 5 x rootfs2) and the read-back must match the stock ones.
if [ -f "$DATA_REAL/restore/MANIFEST.sha256" ]; then
  setup "$T/restore"; mkdir -p "$T/restore/parts"
  for p in toc1:toc1.img boot1:boot.img rootfs1:rootfs.img boot2:boot.img rootfs2:rootfs.img; do
    python3 "$REPO/tests/flashsim.py" write "$T/restore/parts" "${p%%:*}" "$DATA_REAL/fel/${p#*:}"
  done
  RP() { for i in 01 02 03 04 05; do echo "flash $1 $1.$i.simg"; done; }
  run restore 0 restore && expect_calls restore "oem dust $CHECK
oem prep
flash boot1 boot1.img
$(RP rootfs1)
flash boot2 boot2.img
$(RP rootfs2)"
  check restore "read-back not ok against stock" grep -q "verify=ok" "$T/restore/out"

  # 17. Partial restore (only slot 2): only those are written and checked.
  setup "$T/restore2"; mkdir -p "$T/restore2/parts"
  for p in toc1:toc1.img boot1:boot.img rootfs1:rootfs.img boot2:boot.img rootfs2:rootfs.img; do
    python3 "$REPO/tests/flashsim.py" write "$T/restore2/parts" "${p%%:*}" "$DATA_REAL/fel/${p#*:}"
  done
  run restore2 0 restore boot2 rootfs2 && expect_calls restore2 "oem dust $CHECK
oem prep
flash boot2 boot2.img
$(RP rootfs2)"
  check restore2 "read-back not ok" grep -q "verify=ok" "$T/restore2/out"
  check restore2 "checked slot 1" eval "! grep -qE '^\[.*\]    (boot1|rootfs1):' '$T/restore2/out'"
else
  echo "skip restore tests: run flash.sh prepare-restore first"
fi

echo "== $fails failure(s); details in $T"
[ $fails = 0 ]
