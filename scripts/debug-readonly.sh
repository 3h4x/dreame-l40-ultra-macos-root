#!/bin/bash
# Debug etapu 3 z macOS -- CZYSTO ODCZYT, nic nie zapisuje do flasha robota.
#
# Po nieudanym flashu (patrz README, "Stage 3 attempt"): boot payloadu z joba do RAM (jak etap 1), potem BEZ
# `oem dust` czyta getvary i zrzuca okno 0 (`upload`, ~399 MB, obejmuje toc1/env/boot1/rootfs1/boot2/kawalek
# rootfs2). Bez `oem dust` `upload` jest szyfrowany tym samym kluczem pozycyjnym co probki etapu 1, wiec zrzut
# porownuje sie bajtowo z pristine `dustx100.bin` (tools/dumpdiff.py) -- widac dokladnie, co zmienil sie na eMMC,
# i co zrobil `oem prep` z env (slot bootowania + root-patch).
#
# Nic z tego nie wchodzi w sciezke `oem dust`/`oem prep`/`flash:`. FEL siedzi w boot ROM SoC -> zawsze odzyskiwalne.
#
#   caffeinate -i env FSBL=ddr4 ./scripts/debug-readonly.sh
#
# Robot: wejdz w FEL (PCB + power ~5 s, puszczasz power, PCB jeszcze ~3 s), podlacz USB, potem odpal skrypt.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FEL=${FEL:-$REPO/build/sunxi-tools/sunxi-fel}
FB=${FB:-$REPO/build/fbtool}
DATA=${DATA:-$HOME/dreame-l40}
FSBL_FILE=$DATA/stage1/fsbl_ddr4.bin        # proven w FEL (README, "fsbl mismatch"); nigdy nie ladowany na flash
PAYLOAD=$DATA/stage1/payload.bin
PRISTINE=$DATA/dustx100.bin                  # probka etapu 1 sprzed flasha (referencja)
MIN=380000000

mkdir -p "$DATA/logs"
OUT=$DATA/logs/debug-fresh-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
exec > >(tee "$OUT/debug.log") 2>&1
T0=$SECONDS
say() { echo "[$((SECONDS - T0))s] $*"; }
die() { say "!! $*"; say "!! STOP. Log: $OUT/debug.log"; exit 1; }
size() { stat -f %z "$1" 2>/dev/null || echo 0; }

[ -f "$FSBL_FILE" ] && [ -f "$PAYLOAD" ] || die "brak fsbl_ddr4.bin/payload.bin w $DATA/stage1"

if $FB devices 2>/dev/null | grep -q .; then
  die "robot juz w fastboot z nieznanej sesji -- wylacz go (power 15 s) i wejdz w FEL od nowa"
fi
say "== Czekam na FEL (do 5 min)"
for i in $(seq 1 300); do $FEL ver >/dev/null 2>&1 && break; sleep 1; done
$FEL ver >/dev/null 2>&1 || die "brak FEL"

say "== fsbl_ddr4.bin -> RAM (nie na flash)"
$FEL write 0x28000 "$FSBL_FILE" >/dev/null 2>&1 && $FEL exe 0x28000 >/dev/null 2>&1 || die "fsbl"
sleep 5
say "== payload.bin -> RAM, exe"
$FEL write 0x4a000000 "$PAYLOAD" >/dev/null 2>&1 && $FEL exe 0x4a000000 >/dev/null 2>&1 || die "payload"
for i in $(seq 1 30); do $FB devices 2>/dev/null | grep -q . && break; sleep 1; done
$FB devices 2>/dev/null | grep -q . || die "fastboot nie wstal"
T0=$SECONDS
say "== fastboot OK (BEZ oem dust). Getvary:"
for v in config toc0hash toc1hash toc1version dustversion flashsize ramsize max-download-size; do
  say "   $v = $($FB getvar $v 2>&1 | sed -n "s/^$v: *//p" | head -1)"
done

say "== upload okno 0 (~30 s, tylko odczyt)"
$FB upload "$OUT/fresh_win0.bin.part" || die "upload"
[ "$(size "$OUT/fresh_win0.bin.part")" -ge "$MIN" ] || die "krotki odczyt"
mv "$OUT/fresh_win0.bin.part" "$OUT/fresh_win0.bin"
say "== zrzut: $OUT/fresh_win0.bin ($(( $(size "$OUT/fresh_win0.bin") / 1048576 )) MB)"

if [ -f "$PRISTINE" ]; then
  say "== Analiza offline: roznice vs pristine + env"
  python3 "$REPO/tools/dumpdiff.py" "$OUT/fresh_win0.bin" "$PRISTINE" --env "$DATA/plain/parts"
else
  say "!! brak $PRISTINE -- pomijam porownanie; zrzut zostaje w $OUT"
fi
say "== KONIEC. Nic nie zapisano na flash robota. Log i zrzut: $OUT"
