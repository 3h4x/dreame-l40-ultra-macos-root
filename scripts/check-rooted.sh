#!/bin/bash
# Po `flash.sh reboot`: sprawdza przez SSH (tylko odczyt), czy robot wstal z systemem z roota i czy partycje na
# eMMC sa dokladnie tym, co wgralismy. Najpierw polacz Maca z Wi-Fi robota (dwa zewnetrzne przyciski 3 s -> AP).
#   check-rooted.sh            host 192.168.5.1, klucz ~/.ssh/id_rsa (podany dustbuilderowi)
#   PARTS="boot1:boot.img rootfs1:rootfs.img" check-rooted.sh   gdy slot 2 zostal fabryczny
# SSH mozna podmienic (SSH=...), HOST=..., KEY=...
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
DATA=${DATA:-$HOME/dreame-l40}
W=$DATA/fel
HOST=${HOST:-192.168.5.1}
KEY=${KEY:-$HOME/.ssh/id_rsa}
SSH=${SSH:-ssh}
# Own known_hosts so the robot's host key does not land in ~/.ssh; old dropbear may still want ssh-rsa.
OPTS=(-i "$KEY" -o UserKnownHostsFile="$DATA/known_hosts" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
      -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa)
fails=0
say() { echo "== $*"; }
bad() { echo "!! $*"; fails=$((fails + 1)); }
r() { "$SSH" "${OPTS[@]}" "root@$HOST" "$@"; }

say "SSH root@$HOST"
banner=$(r 'cat /etc/banner /etc/motd 2>/dev/null; echo; uname -a; cat /proc/cmdline') || { bad "SSH nie dziala"; exit 1; }
echo "$banner" | sed 's/^/   /'
echo "$banner" | grep -q "dustbuilder" && say "system zbudowany przez dustbuildera" || bad "brak 'dustbuilder' w bannerze"
root=$(echo "$banner" | grep -o 'root=[^ ]*' | head -1)
say "aktywny root: ${root:-nieznany}"

# md5 of the first N bytes of each partition vs the image we flashed (busybox has head -c and md5sum).
for part in ${PARTS:-boot1:boot.img rootfs1:rootfs.img boot2:boot.img rootfs2:rootfs.img}; do
  p=${part%%:*}; img=$W/${part#*:}
  n=$(stat -f %z "$img"); want=$(md5 -q "$img")
  got=$(r "head -c $n /dev/by-name/$p | md5sum" | cut -d' ' -f1)
  [ "$got" = "$want" ] && say "$p = ${part#*:} (md5 $want)" || bad "$p: md5 $got, oczekiwane $want"
done

[ "$fails" = 0 ] && say "WSZYSTKO ZGODNE. Dalej: etap 4 -- backup /mnt/private, /mnt/misc (README), potem Valetudo." \
  || say "$fails problem(ow) -- nie idz dalej, pokaz wynik."
[ "$fails" = 0 ]
