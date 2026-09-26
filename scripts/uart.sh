#!/bin/bash
# Nagrywa konsole UART robota (SoC UART0, 115200 8N1) do pliku w $DATA/logs/. Bez zapisu do robota.
#
# Sprzet: adapter USB-UART 3.3 V (FT232RL zworka na 3.3V, albo CP2102), 3x dupont M-F do SoC Breakout:
#   adapter TXD -> breakout RX,  adapter RXD -> breakout TX,  adapter GND -> breakout GND   (patrz docs/breakout-pcb.md)
#
#   ./scripts/uart.sh            # auto-wykrywa port, loguje do $DATA/logs/uart-<ts>.log, echo na ekran; Ctrl-C konczy
#   ./scripts/uart.sh --list     # tylko pokazuje wykryte porty szeregowe
#   PORT=/dev/cu.usbserial-XXXX ./scripts/uart.sh   # wymuszenie portu
#
# Loopback test PRZED podlaczeniem robota: zewrzyj TXD<->RXD adaptera, odpal skrypt, wpisz cos w innym oknie:
#   printf 'test\r' > /dev/cu.usbserial-XXXX   -> w logu powinno pojawic sie "test".
set -u
DATA=${DATA:-$HOME/dreame-l40}
BAUD=${BAUD:-115200}

find_port() { ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART /dev/cu.wchusbserial* /dev/cu.usbmodem* 2>/dev/null; }

if [ "${1:-}" = --list ]; then
  echo "Wykryte porty (cu.*):"; find_port || echo "  (brak — podlacz adapter USB-UART)"; exit 0
fi

PORT=${PORT:-$(find_port | head -1)}
if [ -z "${PORT:-}" ]; then
  echo "!! Nie znaleziono portu szeregowego. Podlacz adapter USB-UART i sprawdz: ./scripts/uart.sh --list"
  echo "   (FT232RL/CP2102 pojawiaja sie jako /dev/cu.usbserial-* albo /dev/cu.SLAB_USBtoUART)"
  exit 1
fi

mkdir -p "$DATA/logs"
LOG=$DATA/logs/uart-$(date +%Y%m%d-%H%M%S).log
echo "== Port: $PORT  Baud: $BAUD  Log: $LOG"
echo "== Ctrl-C konczy. (8N1, bez kontroli przeplywu)"

echo "----- UART $PORT @ $BAUD, start $(date) -----" | tee -a "$LOG"
# 8N1, bez echa, surowy odczyt. stty i cat musza dzialac na TYM SAMYM otwartym deskryptorze: macOS resetuje
# ustawienia portu (do 9600) po ostatnim zamknieciu, wiec `stty -f PORT` + osobne `cat PORT` czyta na 9600.
{
  stty "$BAUD" cs8 -cstopb -parenb -crtscts -echo raw || { echo "!! stty nie ustawil portu $PORT" >&2; exit 1; }
  echo "== predkosc na otwartym porcie: $(stty speed)" >&2
  exec cat
} < "$PORT" | tee -a "$LOG"
