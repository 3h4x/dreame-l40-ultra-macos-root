#!/bin/bash
# Stage 1 (READ ONLY): `getvar config` + the 3 samples dustbuilder asks for, from macOS. Safe to re-run: fetches only
# the missing samples into $DATA (~/dreame-l40). Upload config.txt + dreame_samples.zip to dustbuilder.
# Runtime messages are in Polish.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FEL=$REPO/build/sunxi-tools/sunxi-fel
FB=$REPO/build/fbtool
DATA=${DATA:-$HOME/dreame-l40}
S=$DATA/stage1
cd "$DATA"
MIN=380000000
FILES=(dustx100.bin dustx101.bin dustx102.bin)

size() { stat -f %z "$1" 2>/dev/null || echo 0; }
have() { [ "$(size "$1")" -ge "$MIN" ]; }
all_done() { for f in "${FILES[@]}"; do have "$f" || return 1; done; }

finish() {
  echo
  echo "== Wszystkie 3 probki sa. Pakuje do zipa..."
  rm -f dreame_samples.zip
  zip -0 dreame_samples.zip "${FILES[@]}" config.txt
  ls -la dreame_samples.zip
  echo "== ETAP 1 GOTOWY."
  echo "!! TERAZ: trzymaj power robota 15 s (wylaczy sie) i ODLACZ kabel USB."
  exit 0
}

all_done && finish

if $FB devices | grep -q .; then
  echo "== Robot juz w fastboot, pomijam FEL"
else
  echo "== Czekam na robota w trybie FEL (do 5 min)..."
  for i in $(seq 1 300); do $FEL ver >/dev/null 2>&1 && break; sleep 1; done
  $FEL ver || { echo "!! Brak robota w trybie FEL."; exit 1; }
  echo "== Laduje fsbl (DRAM)..."
  $FEL write 0x28000 "$S/fsbl_ddr4.bin" && $FEL exe 0x28000 || exit 1
  sleep 5
  echo "== Laduje payload (fastboot)..."
  $FEL write 0x4a000000 "$S/payload.bin" && $FEL exe 0x4a000000 || exit 1
  echo "== Czekam na fastboot..."
  for i in $(seq 1 30); do $FB devices | grep -q . && break; sleep 1; done
  $FB devices | grep -q . || { echo "!! Fastboot nie wstal."; exit 1; }
fi
START=$SECONDS
echo "== Fastboot OK. Okno ~180 s liczy sie od przyciskow, jedziemy od razu."

# The robot requires getvar config in every session before any oem stage command.
CFG=$($FB getvar config | grep '^config:')
echo "== $CFG"
grep -q '^config:' config.txt 2>/dev/null || echo "$CFG" > config.txt

stage=0
for n in 0 1 2; do
  f=${FILES[$n]}
  have "$f" && { echo "== $f juz jest, pomijam"; continue; }
  while [ "$stage" -lt "$n" ]; do
    stage=$((stage + 1))
    $FB oem stage$stage || { echo "!! oem stage$stage nie przeszlo"; exit 1; }
  done
  echo "== Pobieram $f, minelo $((SECONDS - START)) s z 160..."
  T0=$SECONDS
  rm -f "$f.part"
  if $FB upload "$f.part" && [ "$(size "$f.part")" -ge "$MIN" ]; then
    mv "$f.part" "$f"
    dt=$((SECONDS - T0)); [ "$dt" -gt 0 ] || dt=1
    echo "== $f OK ($(( $(size "$f") / 1048576 )) MB w ${dt} s = $(( $(size "$f") / 1048576 / dt )) MB/s), minelo $((SECONDS - START)) s"
  else
    rm -f "$f.part"
    echo "!! $f przerwane (pewnie watchdog). Wejdz w FEL jeszcze raz i odpal skrypt."
    exit 1
  fi
done

all_done && finish
