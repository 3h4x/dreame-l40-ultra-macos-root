#!/bin/bash
# Test kierunku Mac -> robot (fastboot "download") przed etapem 3. NIC NIE ZAPISUJE DO FLASHA:
# dane laduja tylko w RAM robota, nie ma flash/erase/oem dust/oem prep. Uzywa payloadu ze stage1
# (tego samego co samples.sh). Mierzy predkosc, sprawdza max-download-size i probuje odczytac
# bufor z powrotem (upload) -- jesli payload to wspiera, porownuje bajt w bajt.
# SIZE (bajty) domyslnie 128 MiB, czyli wiecej niz rootfs.img (131.7 MB).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FEL=$REPO/build/sunxi-tools/sunxi-fel
FB=$REPO/build/fbtool
DATA=${DATA:-$HOME/dreame-l40}
S=$DATA/stage1
SIZE=${SIZE:-134217728}
T=$DATA/dltest
mkdir -p "$T"
cd "$T"

size() { stat -f %z "$1" 2>/dev/null || echo 0; }

# Integrity checks run before the robot is touched; any mismatch stops the script.
JOB=${JOB:-$DATA/job}
ZIP=$(ls "$JOB"/*_fel_ng.zip 2>/dev/null | head -1)
[ -n "$ZIP" ] || { echo "!! brak *_fel_ng.zip w $JOB"; exit 1; }
echo "== Sprawdzam sumy kontrolne (bez robota)..."
want=$(awk '/_fel_ng.zip$/ {print $1}' "$JOB/md5.txt")
[ "$(md5 -q "$ZIP")" = "$want" ] || { echo "!! md5 obrazu FEL nie zgadza sie z md5.txt"; exit 1; }
echo "== md5 obrazu FEL zgodne z md5.txt dustbuildera ($want)"
chk=$(unzip -p "$ZIP" check.txt | tr -d '\r\n')
grep -q "'$chk'" "$JOB/_buildflags.sh" || { echo "!! check.txt ($chk) nie pasuje do checkvalue w _buildflags.sh"; exit 1; }
echo "== check.txt $chk zgodny z _buildflags.sh"
for f in fsbl_ddr4.bin payload.bin; do
  tar -xOzf "$DATA/dust-fel-mr813.tar.gz" "$f" | cmp -s - "$S/$f" \
    || { echo "!! $S/$f rozni sie od przypietej paczki stage1"; exit 1; }
done
echo "== fsbl i payload do testu identyczne z przypieta paczka stage1"

echo "== Przygotowuje plik testowy ($((SIZE / 1048576)) MiB losowych danych)..."
[ "$(size test.bin)" -eq "$SIZE" ] || head -c "$SIZE" /dev/urandom > test.bin

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

# The robot requires getvar config in every session before anything else.
$FB getvar config || { echo "!! getvar config nie przeszlo"; exit 1; }

MAX=$($FB getvar max-download-size 2>&1 | sed -n 's/^max-download-size: *//p')
if [ -n "$MAX" ]; then
  MAXB=$((MAX))
  echo "== max-download-size: $MAX = $MAXB B ($((MAXB / 1048576)) MiB)"
  [ "$MAXB" -ge 131700000 ] || echo "!! rootfs.img (131.7 MB) sie NIE zmiesci -- etap 3 bedzie wymagal dzielenia (sparse)"
  if [ "$MAXB" -lt "$SIZE" ]; then
    echo "== Przycinam plik testowy do max-download-size"
    head -c "$MAXB" test.bin > test.cut && mv test.cut test.bin
  fi
else
  echo "== Robot nie podal max-download-size, wysylam pelne $((SIZE / 1048576)) MiB"
fi

N=$(size test.bin)
echo "== download $((N / 1048576)) MiB, minelo $((SECONDS - START)) s..."
T0=$SECONDS
if $FB download test.bin; then
  dt=$((SECONDS - T0)); [ "$dt" -gt 0 ] || dt=1
  echo "== DOWNLOAD OK: $((N / 1048576)) MiB w ${dt} s = $((N / 1048576 / dt)) MiB/s, minelo $((SECONDS - START)) s"
else
  echo "!! DOWNLOAD NIEUDANY po $((SECONDS - T0)) s (log powyzej)."
  exit 1
fi

echo "== Proba odczytu bufora z powrotem (upload), tylko informacyjnie..."
rm -f back.bin
if $FB upload back.bin; then
  if cmp -s test.bin back.bin; then
    echo "== ROUND-TRIP OK: robot zwrocil dokladnie to, co dostal ($((N / 1048576)) MiB)"
  else
    echo "== Upload zwrocil co innego ($(size back.bin) B) -- payload nie oddaje bufora z download, to nie blad"
  fi
else
  echo "== Payload nie wspiera upload po download -- to nie blad"
fi
rm -f back.bin
echo "== Koniec, minelo $((SECONDS - START)) s."
echo "!! TERAZ: trzymaj power robota 15 s (wylaczy sie) i ODLACZ kabel USB."
