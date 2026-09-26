#!/bin/bash
# Joins the robot to a Wi-Fi network through Valetudo's API, typed into the UART root shell.
# SSID and password come from $DATA/wifi.txt (line 1 SSID, line 2 password, chmod 600, not in git) and are
# read with `read -s` on the robot, so neither lands in the UART log.
#   robot-wifi.sh        send the configuration
#   robot-wifi.sh status Valetudo's Wi-Fi status + the robot's IPv4 addresses
set -eu
DATA=${DATA:-$HOME/dreame-l40}
PORT=${PORT:-$(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART /dev/cu.wchusbserial* 2>/dev/null | head -1)}
LOG=${LOG:-$(ls -t "$DATA"/logs/uart-*.log | head -1)}
API=http://127.0.0.1/api/v2/robot/capabilities/WifiConfigurationCapability

send() { printf '%s\n' "$1" > "$PORT"; }
show() {  # lines the robot printed since log line $1
  sleep "$2"; tail -n +"$(( $1 + 1 ))" "$LOG" | grep -v ctrl_ifname
}

L=$(wc -l < "$LOG")
if [ "${1:-}" = status ]; then
  send "curl -s $API; echo; ip -4 addr | grep inet"
  show "$L" 4; exit
fi

F=$DATA/wifi.txt
[ -f "$F" ] || { echo "brak $F (linia 1: SSID, linia 2: haslo)"; exit 1; }
B64=$(python3 - "$F" <<'EOF'
import base64, json, sys
ssid, pw = open(sys.argv[1]).read().split('\n')[:2]
body = {"ssid": ssid, "credentials": {"type": "wpa2_psk", "typeSpecificSettings": {"password": pw}}}
print(base64.b64encode(json.dumps(body).encode()).decode())
EOF
)
# `read -s` takes the secret line without echo (busybox `stty -echo` segfaults on this robot and the respawned
# login echoed the next line into the log).
send ""
sleep 1
send "read -s B"
sleep 1
send "$B64"
sleep 1
send "echo \"\$B\" | base64 -d | curl -s -o /dev/null -w 'wifi PUT http %{http_code}\n' -X PUT -H 'Content-Type: application/json' --data-binary @- $API; unset B"
show "$L" 4
if grep -qF "$B64" "$LOG"; then echo "!! payload w logu -- usun: $LOG"; fi
echo "== za ~30-60 s: scripts/robot-wifi.sh status"
