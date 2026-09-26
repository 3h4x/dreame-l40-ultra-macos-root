#!/bin/bash
# Stage 3 from macOS: flash a dustbuilder FEL image (the Valetudo guide's fastboot sequence) with sunxi-fel + fbtool.
# Put your dustbuilder job (the *_fel_ng.zip, md5.txt, _buildflags.sh) in $JOB (default $DATA/job).
# Runtime messages are in Polish.
#
#   flash.sh prepare          no robot: checksums, unpack, split rootfs into sparse pieces (like fastboot 34.0.5),
#                             verify the pieces two independent ways, sha256 manifest
#   flash.sh probe            robot, WRITES NOTHING, no payload: run the stage1 fsbl_ddr4.bin, read back from SRAM
#                             which DRAM parameters it used -> is the zip's fsbl.bin safe (see README)
#   flash.sh rehearse         robot, WRITES NOTHING: fsbl + job payload, getvars, `download` (no flash) of a rootfs
#                             piece and boot.img, read-back of the eMMC compared with the images
#   flash.sh flash            robot, WRITES: oem dust, oem prep, toc1, boot1, rootfs1, boot2, rootfs2. Stops at the
#                             first error, then reads the flash back and compares. Does NOT reboot.
#   flash.sh pieces PART [N]  robot, WRITES: dust + prep, then PART (rootfs1|rootfs2) one sparse piece per call from
#                             piece N, in the live session if there is one. For the eMMC write timeout (README).
#   flash.sh resume STEP      same live session (dust+prep already OKAY): flash from STEP to the end. Idempotent.
#   flash.sh verify           same session: read the flash back (upload) and compare with the images;
#                             ONLY=toc1,boot1,rootfs1,boot2 when slot 2 was left stock on purpose
#   flash.sh reboot           after checking: fastboot reboot
#   flash.sh prepare-restore  no robot: stock partitions from the decrypted stage 1 samples ($DATA/plain/parts),
#                             rootfs split like fastboot, verified, manifest
#   flash.sh restore [PART..] robot, WRITES: back to stock boot1/rootfs1/boot2/rootfs2 (default all), read-back
#                             against the stock partitions. RESTORE=1 for resume/verify after restore.
#
# FSBL=ddr4 loads the stage1 fsbl_ddr4.bin (what the L40 Ultra needs). FB and FEL can be swapped (tests/). Logs:
# $DATA/logs/.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FEL=${FEL:-$REPO/build/sunxi-tools/sunxi-fel}
FB=${FB:-$REPO/build/fbtool}
SPARSE=$REPO/build/fbsparse
SIMG2IMG=$REPO/build/simg2img
DATA=${DATA:-$HOME/dreame-l40}
JOB=${JOB:-$DATA/job}
ZIP=$(ls "$JOB"/*_fel_ng.zip 2>/dev/null | head -1)
W=$DATA/fel            # rozpakowany obraz + kawalki; to, co idzie do robota
# PAYLOAD=...: another payload, e.g. from tools/payload-emmc-caps.sh (tried, did not help -- see JOURNEY.md)
PAYLOAD=${PAYLOAD:-$W/payload.bin}
# the config dustbuilder built the job for; the robot must report the same in `getvar config`
EXPECT_CONFIG=$(sed -n "s/^echo '\\([0-9a-f]*\\)' > configvalue$/\\1/p" "$JOB/_buildflags.sh" 2>/dev/null)
MAX=33554432           # max-download-size of the L40 Ultra payload; re-checked in rehearse
STEPS=(toc1 boot1 rootfs1 boot2 rootfs2)
STOCK=$DATA/plain/parts   # stock partitions from the decrypted stage 1 samples (README)
R=$DATA/restore          # stock rootfs split into pieces, for restore
[ "${1:-}" = restore ] && RESTORE=1
if [ "${RESTORE:-}" = 1 ]; then STEPS=(boot1 rootfs1 boot2 rootfs2); fi

mkdir -p "$DATA/logs"
LOG=$DATA/logs/flash-${1:-none}-$(date +%Y%m%d-%H%M%S).log
exec > >(tee "$LOG") 2>&1
T0=$SECONDS
say() { echo "[$((SECONDS - T0))s] $*"; }
die() { say "!! $*"; say "!! STOP. Log: $LOG"; exit 1; }
size() { stat -f %z "$1" 2>/dev/null || echo 0; }

image_for() {  # partition -> files to flash, in order
  if [ "${RESTORE:-}" = 1 ]; then
    case $1 in
      boot1|boot2) echo "$STOCK/$1.img" ;;
      rootfs1|rootfs2) ls "$R/$1".*.simg ;;
    esac
    return
  fi
  case $1 in
    toc1) echo "$W/toc1.img" ;;
    boot1|boot2) echo "$W/boot.img" ;;
    rootfs1|rootfs2) ls "$W"/rootfs.*.simg ;;
  esac
}

restore_manifest_check() {
  [ -f "$R/MANIFEST.sha256" ] || die "brak $R/MANIFEST.sha256 -- najpierw: flash.sh prepare-restore"
  (cd "$DATA" && shasum -a 256 -c --quiet "$R/MANIFEST.sha256") || die "pliki do restore zmienione -- prepare-restore jeszcze raz"
  say "   manifest restore OK"
}

prepare_restore() {
  [ -f "$STOCK/SHA256SUMS" ] || die "brak $STOCK -- najpierw odszyfruj probki (README, tools/dustdecrypt.py)"
  (cd "$STOCK/.." && shasum -a 256 -c --quiet parts/SHA256SUMS) || die "fabryczne partycje w $STOCK zmienione"
  mkdir -p "$R"; chmod 700 "$R"
  rm -f "$R"/*.simg "$R/MANIFEST.sha256"
  for p in rootfs1 rootfs2; do
    say "== $p: podzial na kawalki <= $MAX B + weryfikacja (simg2img, simgcheck)"
    "$SPARSE" "$MAX" "$STOCK/$p.img" "$R/$p" || die "fbsparse $p"
    "$SIMG2IMG" "$R/$p".*.simg "$R/$p.rebuilt" && cmp "$STOCK/$p.img" "$R/$p.rebuilt" || die "$p: zlozone != fabryczne"
    rm -f "$R/$p.rebuilt"
    python3 "$REPO/tools/simgcheck.py" "$MAX" "$STOCK/$p.img" "$R/$p".*.simg >/dev/null || die "simgcheck $p"
  done
  for p in boot1 boot2; do [ "$(size "$STOCK/$p.img")" -le "$MAX" ] || die "$p > $MAX"; done
  (cd "$DATA" && shasum -a 256 plain/parts/boot1.img plain/parts/boot2.img restore/*.simg > "$R/MANIFEST.sha256")
  say "== PREPARE-RESTORE OK. restore wgra:"
  for p in boot1 rootfs1 boot2 rootfs2; do say "   $p <- $(RESTORE=1 image_for "$p" | xargs -n1 basename | tr '\n' ' ')"; done
}

offline_checks() {
  say "== Sumy kontrolne (bez robota)"
  [ -n "$ZIP" ] && [ -f "$JOB/md5.txt" ] && [ -f "$JOB/_buildflags.sh" ] || die "w $JOB brak *_fel_ng.zip / md5.txt / _buildflags.sh"
  [ -n "$EXPECT_CONFIG" ] || die "brak configvalue w $JOB/_buildflags.sh"
  [ "$(md5 -q "$ZIP")" = "$(awk '/_fel_ng.zip$/ {print $1}' "$JOB/md5.txt")" ] || die "md5 obrazu FEL != md5.txt"
  CHECK=$(unzip -p "$ZIP" check.txt | tr -d '\r\n')
  grep -q "^echo '$CHECK' > checkvalue$" "$JOB/_buildflags.sh" || die "check.txt ($CHECK) != checkvalue"
  grep -q "^echo '$EXPECT_CONFIG' > configvalue$" "$JOB/_buildflags.sh" || die "configvalue joba != $EXPECT_CONFIG"
  say "   zip OK, check=$CHECK, config joba=$EXPECT_CONFIG"
}

manifest_check() {
  [ -f "$W/MANIFEST.sha256" ] || die "brak $W/MANIFEST.sha256 -- najpierw: flash.sh prepare"
  (cd "$W" && shasum -a 256 -c --quiet MANIFEST.sha256) || die "pliki w $W zmienione od prepare -- zrob prepare jeszcze raz"
  say "   manifest OK ($(wc -l < "$W/MANIFEST.sha256" | tr -d ' ') plikow)"
  fsbl_check
}

# Which fsbl initialises DRAM (see README, "fsbl mismatch"). The job's fsbl.bin is fsbl_ddr3.bin: the same code as
# the fsbl_ddr4.bin that ran here twice, differing only in the header's default DRAM set (DDR3). The fsbl uses that
# default only if its board-ID pick from DRAM.ext fails. So the zip's fsbl.bin is loaded only if `flash.sh probe`
# showed the fsbl picking a DRAM.ext DDR4 set on this robot; FSBL=ddr4 loads the stage1 fsbl_ddr4.bin instead.
STAGE1_FSBL=$DATA/stage1/fsbl_ddr4.bin
PROBE=$DATA/logs/fsbl-probe.result
FSBLPARAMS=$REPO/tools/fsblparams.py

STAGE1_TGZ=$DATA/dust-fel-mr813.tar.gz
STAGE1_SHA256=d53292fa35a4241aa6ce3ed6f391f0ab53a248c10cd28fbb8e00e6c0e56f1934   # same pin as setup-mac.sh

stage1_fsbl_check() {
  [ "$(shasum -a 256 "$STAGE1_TGZ" 2>/dev/null | cut -d' ' -f1)" = "$STAGE1_SHA256" ] \
    || die "$STAGE1_TGZ brak albo sha256 != przypiety -- scripts/setup-mac.sh"
  tar -xOzf "$STAGE1_TGZ" fsbl_ddr4.bin | cmp -s - "$STAGE1_FSBL" \
    || die "$STAGE1_FSBL rozni sie od przypietej paczki stage1"
}

fsbl_check() {
  local t
  if [ "${FSBL:-zip}" = ddr4 ]; then
    stage1_fsbl_check
    FSBL_FILE=$STAGE1_FSBL; NEED=type4
    say "   fsbl: fsbl_ddr4.bin ze stage1 (FSBL=ddr4, odejscie od litery przewodnika)"
    return
  fi
  FSBL_FILE=$W/fsbl.bin
  t=$(od -An -tu4 -j 60 -N 4 "$FSBL_FILE" | tr -d ' ')
  if [ "$t" = 4 ]; then NEED=type4; say "   fsbl.bin z zipa: domyslnie DDR4"; return; fi
  stage1_fsbl_check
  python3 "$FSBLPARAMS" --header-only "$FSBL_FILE" "$STAGE1_FSBL" >/dev/null \
    || die "fsbl.bin rozni sie od fsbl_ddr4.bin czyms wiecej niz domyslnym zestawem DRAM -- nie laduje"
  grep -qx 'verdict=ext1' "$PROBE" 2>/dev/null \
    || die "fsbl.bin z zipa ma domyslnie DDR3; bez 'verdict=ext1' z flash.sh probe nie laduje go (albo FSBL=ddr4)"
  NEED=ext1
  say "   fsbl.bin z zipa: domyslnie DDR3, ale probe: robot wybiera zestaw DDR4 z DRAM.ext -> ten sam zestaw"
}

# Runs an fsbl, then reads back from SRAM the DRAM parameters it used and checks them before anything else runs.
fsbl_run() {  # file, requirement (type4|ext1|none), readback path
  $FEL write 0x28000 "$1" && $FEL exe 0x28000 || die "fsbl"
  sleep 5
  $FEL read 0x28000 0x800 "$3" || die "odczyt SRAM po fsbl"
  python3 "$FSBLPARAMS" "$1" "$3" | tee "$3.txt" | grep -E '^(robot used|verdict)' | while read -r l; do say "   $l"; done
  case $2 in
    type4) grep -qx 'type=4' "$3.txt" || die "fsbl ustawil DRAM inaczej niz DDR4 -- STOP przed payloadem, nic nie zapisano" ;;
    ext1) grep -qx 'verdict=ext1' "$3.txt" || die "fsbl nie wybral zestawu DDR4 z DRAM.ext -- STOP przed payloadem, nic nie zapisano" ;;
  esac
}

prepare() {
  offline_checks
  [ -x "$SPARSE" ] && [ -x "$SIMG2IMG" ] || die "brak build/fbsparse lub build/simg2img -- uruchom scripts/setup-mac.sh"
  say "== Rozpakowuje obraz do $W"
  mkdir -p "$W"
  unzip -o -q "$ZIP" fsbl.bin payload.bin toc1.img boot.img rootfs.img check.txt -d "$W" || die "unzip"
  rm -f "$W"/rootfs.*.simg "$W/MANIFEST.sha256"
  say "== Dziele rootfs.img na kawalki <= $MAX B (libsparse z Debiana 13, jak fastboot)"
  "$SPARSE" "$MAX" "$W/rootfs.img" "$W/rootfs" || die "fbsparse"
  say "== Weryfikacja 1/2: simg2img (libsparse) sklada kawalki z powrotem"
  "$SIMG2IMG" "$W"/rootfs.*.simg "$W/rootfs.rebuilt" || die "simg2img"
  cmp "$W/rootfs.img" "$W/rootfs.rebuilt" || die "zlozone kawalki != rootfs.img"
  rm -f "$W/rootfs.rebuilt"
  say "== Weryfikacja 2/2: niezalezny parser (tools/simgcheck.py)"
  python3 "$REPO/tools/simgcheck.py" "$MAX" "$W/rootfs.img" "$W"/rootfs.*.simg || die "simgcheck"
  [ "$(size "$W/boot.img")" -le "$MAX" ] && [ "$(size "$W/toc1.img")" -le "$MAX" ] || die "boot/toc1 > $MAX"
  (cd "$W" && shasum -a 256 fsbl.bin payload.bin toc1.img boot.img rootfs.img rootfs.*.simg > MANIFEST.sha256)
  say "== toc1.img: sha256 $(shasum -a 256 "$W/toc1.img" | cut -c1-64)  md5 $(md5 -q "$W/toc1.img")"
  say "== PREPARE OK. Do robota pojdzie:"
  for s in "${STEPS[@]}"; do say "   $s <- $(image_for "$s" | xargs -n1 basename | tr '\n' ' ')"; done
}

fel_wait() {
  if $FB devices | grep -q .; then
    die "robot juz jest w fastboot z nieznanej sesji -- wylacz go (power 15 s) i zacznij od FEL"
  fi
  say "== Czekam na FEL (do 5 min). Robot: PCB + power 5 s, puszczasz power, PCB jeszcze 3 s."
  for i in $(seq 1 300); do $FEL ver >/dev/null 2>&1 && break; sleep 1; done
  $FEL ver >/dev/null 2>&1 || die "brak FEL"
  T0=$SECONDS
}

fel_boot() {
  fel_wait
  say "== FEL. fsbl: $(basename "$FSBL_FILE"), potem odczyt parametrow DRAM z SRAM"
  fsbl_run "$FSBL_FILE" "$NEED" "$DATA/logs/fsbl-readback-$(date +%Y%m%d-%H%M%S).bin"
  if [ "$PAYLOAD" = "$W/payload.bin" ]; then
    say "== payload.bin z joba"
  else
    say "== PAYLOAD=$PAYLOAD (odejscie od joba) sha256 $(shasum -a 256 "$PAYLOAD" | cut -c1-16)"
  fi
  $FEL write 0x4a000000 "$PAYLOAD" && $FEL exe 0x4a000000 || die "payload"
  for i in $(seq 1 30); do $FB devices | grep -q . && break; sleep 1; done
  $FB devices | grep -q . || die "fastboot nie wstal (nic nie zapisano; wylacz robota i zapytaj dustbuildera)"
  T0=$SECONDS
  say "== fastboot OK. Od teraz 160 s do watchdoga (przewodnik)."
}

probe() {
  local rb
  stage1_fsbl_check
  fel_wait
  rb=$DATA/logs/fsbl-probe-$(date +%Y%m%d-%H%M%S).bin
  say "== FEL. fsbl_ddr4.bin ze stage1 (ten z etapu 1), BEZ payloadu"
  fsbl_run "$STAGE1_FSBL" none "$rb"
  cp "$rb.txt" "$PROBE"
  case $(grep '^verdict=' "$PROBE") in
    verdict=ext1) say "== WYNIK: fsbl wybiera zestaw DDR4 z DRAM.ext (board ID). Domyslny zestaw z naglowka jest"
                  say "   nieuzywany, wiec fsbl.bin z zipa (inny tylko w nim) ustawi DRAM tak samo. rehearse/flash go uzyja." ;;
    verdict=default) say "== WYNIK: fsbl uzyl domyslnego zestawu z naglowka. fsbl.bin z zipa (naglowek DDR3) ustawilby DDR3:"
                     say "   NIE uzywac go. Opcje: FSBL=ddr4 albo pytanie do dustbuildera." ;;
    verdict=none) say "== WYNIK: fsbl nie zapisal, czego uzyl -- nie da sie rozstrzygnac; nie uzywac fsbl.bin z zipa." ;;
    *) say "== WYNIK nieoczekiwany -- zobacz $rb.txt; nie uzywac fsbl.bin z zipa." ;;
  esac
  say "== Nic nie zapisano, payload nie byl ladowany. Wylacz robota: power 15 s, odlacz USB."
}

# The only getvar the guide sends before `oem dust`; flash and restore send nothing else, so up to the last flash the
# robot sees exactly the guide's command stream (tests/test-vs-fastboot.sh). The other reads live in rehearse.
config_check() {
  local cfg
  cfg=$($FB getvar config | sed -n 's/^config: *//p')
  [ "$cfg" = "$EXPECT_CONFIG" ] || die "getvar config='$cfg', oczekiwane $EXPECT_CONFIG -- to nie ten robot/payload"
  say "   config OK: $cfg"
}

session_checks() {  # rehearse: config + what the session reports + max-download-size vs the biggest piece
  local max biggest
  config_check
  for v in dustversion toc0hash toc1hash toc1version flashsize ramsize; do
    say "   $($FB getvar $v 2>&1 | tail -1)"
  done
  max=$($FB getvar max-download-size | sed -n 's/^max-download-size: *//p')
  biggest=$(for f in "$W/toc1.img" "$W/boot.img" "$W"/rootfs.*.simg; do size "$f"; done | sort -n | tail -1)
  [ -n "$max" ] && [ "$((max))" -ge "$biggest" ] || die "max-download-size='$max' < najwiekszy plik $biggest B"
  say "   max-download-size $((max)) B >= najwiekszy plik $biggest B"
}

flash_step() {  # partition — one fbtool call, like one `fastboot flash PART IMAGE` (prelude once, pieces back to back)
  local f files=() kb=0
  for f in $(image_for "$1"); do files+=("$f"); kb=$((kb + $(size "$f") / 1024)); done
  say "   flash $1: $(for f in "${files[@]}"; do basename "$f"; done | tr '\n' ' ')(${kb} KB)"
  FBTOOL_WRITE=1 $FB flash "$1" "${files[@]}" || return 1
  echo "$1" >> "$STATE"
  say "   $1 OKAY"
}

run_steps() {  # first step
  local started=0 s
  for s in "${STEPS[@]}"; do
    [ "$s" = "$1" ] && started=1
    [ "$started" = 1 ] || continue
    if ! flash_step "$s"; then
      say "!! $s NIE przeszedl. Sesja moze byc wciaz zywa -- NIE rob reboot."
      say "!! Naprawa w tej samej sesji: scripts/flash.sh resume $s"
      say "!! Jesli fastboot zniknal (koniec okna): FEL od nowa i scripts/flash.sh flash (idempotentne)."
      die "flash $s"
    fi
  done
}

# Reads the flash back through the payload (upload = what is on the eMMC now, encrypted like the stage 1 samples)
# and compares every written range with the images. Read-only; stage 1 (the last 8.6 MB of rootfs2) only if the
# 160 s window leaves room.
verify_readback() {
  local v=$DATA/logs/verify-$(date +%Y%m%d-%H%M%S) stages
  mkdir -p "$v"
  say "== Odczyt flasha z powrotem (upload, tylko odczyt, ~30 s)"
  $FB upload "$v/stage0.bin" >/dev/null || { say "!! upload nieudany -- zapisu nie da sie sprawdzic"; return 1; }
  stages=("$v/stage0.bin")
  if [ $((SECONDS - T0)) -lt 110 ]; then
    say "== oem stage1 + upload (koncowka rootfs2)"
    $FB oem stage1 >/dev/null && $FB upload "$v/stage1.bin" >/dev/null && stages+=("$v/stage1.bin")
  else
    say "   za malo czasu na stage1 -- koncowka rootfs2 (8.6 MB) niesprawdzona"
  fi
  local stock=()
  [ "${RESTORE:-}" = 1 ] && stock=(--stock "$STOCK" --only "$(IFS=,; echo "${STEPS[*]}")")
  [ -n "${ONLY:-}" ] && [ "${RESTORE:-}" != 1 ] && stock=(--only "$ONLY")   # e.g. ONLY=toc1,boot1,rootfs1,boot2
  python3 "$REPO/tools/verifyflash.py" ${stock[@]+"${stock[@]}"} "$W" "${stages[@]}" | tee "$v/result.txt" | while read -r l; do say "   $l"; done
  grep -qx 'verify=ok' "$v/result.txt" || {
    say "!! Odczyt NIE zgadza sie z obrazem (wyzej: BAD). NIE rob reboot."
    say "!! Naprawa w tej samej sesji: scripts/flash.sh resume <partycja> (znow weryfikuje)"
    die "weryfikacja odczytem"
  }
  say "== GOTOWE BEZ RESTARTU: wszystko OKAY, toc1hash zgodny, odczyt flasha = obrazy. scripts/flash.sh reboot"
}

verify_after() {
  say "== Weryfikacja przed restartem"
  for s in "${STEPS[@]}"; do grep -qx "$s" "$STATE" || die "brak OKAY dla $s w $STATE"; done
  say "   wszystkie 5 partycji: OKAY"
  # toc1hash = first 4 bytes of the toc1 name + magic + add_sum of the toc1 on flash (seen 2026-09-25); the job's
  # toc1.img already had the same add_sum as the robot's toc1 before flashing, so it must still match, not change.
  local after want
  after=$($FB getvar toc1hash 2>&1 | sed -n 's/^toc1hash: *//p')
  want=$(xxd -p -l 4 "$W/toc1.img")$(xxd -p -s 16 -l 8 "$W/toc1.img")
  [ "$after" = "$want" ] || die "toc1hash po flashu '$after' != naglowek toc1.img '$want' -- NIE rob reboot"
  say "   toc1hash po: $after = naglowek toc1.img"
}

STATE=$DATA/logs/flash.state
case ${1:-} in
  prepare)
    prepare ;;
  probe)
    probe ;;
  rehearse)
    offline_checks; manifest_check; fel_boot; session_checks
    say "== PROBA: download (bez flash) rootfs.01 i boot.img"
    $FB download "$(image_for rootfs1 | head -1)" || die "download rootfs.01"
    $FB download "$W/boot.img" || die "download boot.img"
    # The read-back check on the untouched flash: toc1 and boot2 already equal the images (README), the rest not.
    say "== PROBA odczytu: upload + porownanie niezmienionego flasha z obrazami"
    say "   (oczekiwane: toc1 i boot2 juz identyczne; boot1, rootfs1, rootfs2 jeszcze fabryczne, wiec inne)"
    v=$DATA/logs/rehearse-readback-$(date +%Y%m%d-%H%M%S); mkdir -p "$v"
    if $FB upload "$v/stage0.bin" >/dev/null; then
      python3 "$REPO/tools/verifyflash.py" "$W" "$v/stage0.bin" > "$v/result.txt"
      grep -E '^[a-z0-9]+: (OK|BAD)' "$v/result.txt" | sed 's/: BAD$/: fabryczne, inne niz obraz (zostanie nadpisane)/; s/: OK$/: identyczne z obrazem/' \
        | while read -r l; do say "   $l"; done
      if grep -qx 'toc1: OK' "$v/result.txt" && grep -qx 'boot2: OK' "$v/result.txt" \
         && grep -qx 'boot1: BAD' "$v/result.txt" && grep -qx 'rootfs1: BAD' "$v/result.txt"; then
        say "   odczyt dziala z payloadem joba: wynik jak w probkach z etapu 1"
      else
        say "!! odczyt dal inny wynik niz probki -- weryfikacja po flashu moze nie byc wiarygodna"
      fi
    else
      say "!! upload z payloadem joba nie dziala -- po flashu zostanie tylko OKAY + toc1hash"
    fi
    say "== PROBA OK, nic nie zapisano. Wylacz robota: power 15 s, odlacz USB." ;;
  flash)
    offline_checks; manifest_check; fel_boot; config_check   # max-download-size etc.: checked in rehearse
    : > "$STATE"
    say "== oem dust $CHECK"
    FBTOOL_WRITE=1 $FB oem dust "$CHECK" || die "oem dust (nic jeszcze nie flashowano)"
    say "== oem prep"
    FBTOOL_WRITE=1 $FB oem prep || die "oem prep (nic jeszcze nie flashowano)"
    run_steps toc1
    verify_after
    verify_readback ;;
  pieces)
    # One sparse piece per fbtool call with a pause between, in the live session if there is one (the payload's
    # U-Boot hit an eMMC write timeout mid-rootfs1 on 26.09, see README). On failure: power cycle, then
    # `flash.sh pieces PART N` from the failed piece. Each piece writes only its own range.
    P=${2:-}; FROM=${3:-1}; PAUSE=${PAUSE:-20}
    case $P in rootfs1|rootfs2) ;; *) die "uzycie: flash.sh pieces rootfs1|rootfs2 [od_kawalka]" ;; esac
    offline_checks; manifest_check
    if $FB devices | grep -q .; then say "== zywa sesja fastboot, bez FEL"; else fel_boot; fi
    config_check
    say "== oem dust $CHECK"
    FBTOOL_WRITE=1 $FB oem dust "$CHECK" || die "oem dust"
    say "== oem prep"
    FBTOOL_WRITE=1 $FB oem prep || die "oem prep"
    n=0
    for f in $(image_for "$P"); do
      n=$((n + 1)); [ "$n" -lt "$FROM" ] && continue
      say "   flash $P kawalek $n: $(basename "$f") ($(( $(size "$f") / 1024 )) KB)"
      FBTOOL_WRITE=1 $FB flash "$P" "$f" || die "$P kawalek $n NIE przeszedl -- power 15 s, FEL, potem: flash.sh pieces $P $n"
      echo "$P.$n" >> "$STATE"
      say "   $P kawalek $n OKAY"
      [ "$n" -lt "$(image_for "$P" | wc -l)" ] && { say "   przerwa ${PAUSE} s"; sleep "$PAUSE"; }
    done
    say "== $P: wszystkie kawalki OKAY. Sprawdzenie: flash.sh verify (ta sama sesja) albo rehearse po restarcie." ;;
  resume)
    printf '%s\n' "${STEPS[@]}" | grep -qx "${2:-}" || die "uzycie: flash.sh resume toc1|boot1|rootfs1|boot2|rootfs2"
    manifest_check
    $FB devices | grep -q . || die "brak fastboot -- sesja skonczona, zacznij od FEL: flash.sh flash"
    $FB getvar config | grep -q "$EXPECT_CONFIG" || die "getvar config nie pasuje"
    [ -f "$STATE" ] || : > "$STATE"
    run_steps "$2"
    verify_after
    verify_readback ;;
  verify)
    manifest_check
    $FB devices | grep -q . || die "brak fastboot -- sesja skonczona"
    verify_readback ;;
  prepare-restore)
    prepare_restore ;;
  restore)
    shift
    [ $# -gt 0 ] && STEPS=("$@")
    for p in "${STEPS[@]}"; do case $p in boot1|rootfs1|boot2|rootfs2) ;; *) die "restore: nieznana partycja $p" ;; esac; done
    offline_checks; manifest_check; restore_manifest_check; fel_boot; config_check
    : > "$STATE"
    say "== RESTORE (fabryczne): ${STEPS[*]}"
    say "== oem dust $CHECK"
    FBTOOL_WRITE=1 $FB oem dust "$CHECK" || die "oem dust (nic jeszcze nie zapisano)"
    say "== oem prep"
    FBTOOL_WRITE=1 $FB oem prep || die "oem prep (nic jeszcze nie zapisano)"
    run_steps "${STEPS[0]}"
    verify_after
    verify_readback ;;
  reboot)
    FBTOOL_WRITE=1 $FB reboot || die "reboot"
    say "== reboot wyslany. Za ~1-2 min: Wi-Fi robota, potem ssh -i ~/.ssh/id_rsa root@192.168.5.1" ;;
  *)
    sed -n '2,20p' "$0"; exit 2 ;;
esac
