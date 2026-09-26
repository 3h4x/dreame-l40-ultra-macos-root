#!/bin/bash
# Valetudo on the rooted robot, over its own Wi-Fi AP (no internet needed; the binary is fetched beforehand).
#   valetudo-install.sh fetch     Mac on the home Wi-Fi: download valetudo-aarch64 + manifest, check sha256
#   valetudo-install.sh install   Mac on the robot's AP: backup /mnt/private + /mnt/misc to the Mac, copy
#                                 Valetudo to /data/valetudo (sha256 checked on the robot), enable
#                                 /data/_root_postboot.sh from the dustbuilder template, reboot
set -eu
DATA=${DATA:-$HOME/dreame-l40}
V=$DATA/valetudo
ROBOT=${ROBOT:-root@192.168.5.1}
SSH=(ssh -i "$HOME/.ssh/id_rsa" -o UserKnownHostsFile="$DATA/known_hosts" -o StrictHostKeyChecking=accept-new
     -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa "$ROBOT")
say() { echo "== $*"; }

manifest_sha() { python3 -c "import json;print(json.load(open('$V/valetudo_release_manifest.json'))['sha256sums']['valetudo-aarch64'])"; }

case ${1:-} in
  fetch)
    mkdir -p "$V"
    curl -fsSL -o "$V/valetudo-aarch64" https://github.com/Hypfer/Valetudo/releases/latest/download/valetudo-aarch64
    curl -fsSL -o "$V/valetudo_release_manifest.json" \
      https://github.com/Hypfer/Valetudo/releases/latest/download/valetudo_release_manifest.json
    [ "$(shasum -a 256 "$V/valetudo-aarch64" | cut -d' ' -f1)" = "$(manifest_sha)" ] || { say "sha256 != manifest"; exit 1; }
    say "OK: Valetudo $(python3 -c "import json;print(json.load(open('$V/valetudo_release_manifest.json'))['version'])")" ;;
  install)
    want=$(manifest_sha)
    [ "$(shasum -a 256 "$V/valetudo-aarch64" | cut -d' ' -f1)" = "$want" ] || { say "local binary sha256 != manifest"; exit 1; }
    say "Robot: $("${SSH[@]}" 'grep ^model= /data/config/miio/device.conf; uname -m')"
    mkdir -p "$DATA/backup"
    b=$DATA/backup/calibration-$(date +%Y%m%d-%H%M%S).tar.gz
    say "Backup /mnt/private + /mnt/misc -> $b"
    "${SSH[@]}" 'tar -czf - /mnt/private /mnt/misc 2>/dev/null' > "$b"
    n=$(tar -tzf "$b" | wc -l | tr -d ' ')
    [ "$n" -gt 5 ] || { say "backup looks empty ($n entries) -- stop"; exit 1; }
    say "   $n entries, $(stat -f %z "$b") B"
    say "Copy Valetudo -> /data/valetudo"
    "${SSH[@]}" 'cat > /data/valetudo.new' < "$V/valetudo-aarch64"
    got=$("${SSH[@]}" 'sha256sum /data/valetudo.new' | cut -d' ' -f1)
    [ "$got" = "$want" ] || { say "sha256 on the robot $got != $want -- stop"; "${SSH[@]}" 'rm -f /data/valetudo.new'; exit 1; }
    "${SSH[@]}" 'mv /data/valetudo.new /data/valetudo && chmod +x /data/valetudo &&
      cp /misc/_root_postboot.sh.tpl /data/_root_postboot.sh && chmod +x /data/_root_postboot.sh &&
      ls -l /data/valetudo /data/_root_postboot.sh'
    say "Reboot; Valetudo at http://192.168.5.1 in ~1-2 min"
    "${SSH[@]}" 'reboot' || true ;;
  *)
    sed -n '2,7p' "$0"; exit 2 ;;
esac
