#!/usr/bin/env bash
# Runs bin/podcasts-player against a real mpv (null audio output) and a local
# audio server. Skipped when mpv or socat is missing, unless CI is set.
set -u
cd "$(dirname "$0")/.." || exit 1
here=$PWD
for t in mpv socat; do
  command -v "$t" > /dev/null || { echo "skipped: $t is not installed"; [ -n "${CI:-}" ] && exit 1; exit 0; }
done
tmp=$(mktemp -d)
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 tests/audio_server.py "$port" & srv=$!
export HOME=$tmp PODCASTS_PLUGIN_DIR=$tmp/store PODCASTS_PLAYER_DIR=$tmp/run PODCASTS_MPV_AO=null
run() { bash "$here/bin/podcasts-player" "$@"; }
trap 'run stop; kill $srv 2>/dev/null; rm -rf "$tmp"' EXIT
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/ep.wav" && break; sleep 0.1; done
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fails=$((fails + 1)); fi; }
num() { printf '%s' "$1" | sed -n "s/.*\"$2\":\([-0-9.]*\).*/\1/p"; }
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{d=a-b; if(d<0)d=-d; print (d<=t)?"yes":"no"}'; }

run status > /dev/null 2>&1; check "status with no player exits 30" $? 30
PODCASTS_PLAYER_DIR="$tmp/a,b" run status > /dev/null 2>&1; check "player dir with socat syntax refused (24)" $? 24
PODCASTS_PLAYER_DIR="$tmp/a:b" run status > /dev/null 2>&1; check "player dir with colon refused (24)" $? 24
run toggle > /dev/null 2>&1; check "toggle with no player exits 30" $? 30
run play 'file:///etc/passwd' x > /dev/null 2>&1; check "file:// refused (64)" $? 64
run play 'https://x.test/a b.mp3' x > /dev/null 2>&1; check "whitespace URL refused (64)" $? 64
run seek abc > /dev/null 2>&1; check "bad seek refused (64)" $? 64
run play "http://127.0.0.1:$port/ep.wav" x 1.5 > /dev/null 2>&1; check "fractional start refused (64)" $? 64
run play "http://127.0.0.1:$port/ep.wav" x -3 > /dev/null 2>&1; check "negative start refused (64)" $? 64

run play "http://127.0.0.1:$port/ep.wav" resumed 40; check "play with a start" $? 0
sleep 1
check "starts where it was left" "$(near "$(num "$(run status)" position)" 41 2)" yes

run play "http://127.0.0.1:$port/ep.wav" 'A "quoted" title'; check "play starts" $? 0
sleep 1
s=$(run status); check "status exits 0" $? 0
check "duration is 60s" "$(near "$(num "$s" duration)" 60 1)" yes
check "title survives quoting" "$(printf '%s' "$s" | grep -c 'A \\"quoted\\" title')" 1
check "playing, not paused" "$(printf '%s' "$s" | grep -c '"paused":false')" 1

run toggle; sleep 0.4
s=$(run status); check "toggle pauses" "$(printf '%s' "$s" | grep -c '"paused":true')" 1
p0=$(num "$s" position)
run seek 15; sleep 0.4
p1=$(num "$(run status)" position)
check "seek +15" "$(near "$p1" "$(awk -v a="$p0" 'BEGIN{print a+15}')" 1)" yes
run seek -10; sleep 0.4
p2=$(num "$(run status)" position)
check "seek -10" "$(near "$p2" "$(awk -v a="$p1" 'BEGIN{print a-10}')" 1)" yes
run seekto 30; sleep 0.4
check "seekto 30" "$(near "$(num "$(run status)" position)" 30 1)" yes
check "speed starts at 1" "$(near "$(num "$(run status)" speed)" 1 0.001)" yes
run speed 1.5; sleep 0.3
check "speed 1.5 applied" "$(near "$(num "$(run status)" speed)" 1.5 0.001)" yes
run speed 0.8; sleep 0.3
check "speed 0.8 applied" "$(near "$(num "$(run status)" speed)" 0.8 0.001)" yes
run speed 3 > /dev/null 2>&1; check "speed 3 refused (64)" $? 64
run speed 1.5x > /dev/null 2>&1; check "speed junk refused (64)" $? 64
check "speed file mode 600" "$(stat -c %a "$tmp/store/speed")" 600
check "speed dir mode 700" "$(stat -c %a "$tmp/store")" 700
ln -sf "$tmp/target" "$tmp/store/speed"
run speed 2; check "speed through a symlink exits 0" $? 0
check "speed is not written through a symlink" "$([ -e "$tmp/target" ] && echo written || echo no)" no
rm -f "$tmp/store/speed"
run speed 1; sleep 0.3
run toggle; sleep 0.4
check "toggle resumes" "$(run status | grep -c '"paused":false')" 1

run stop; sleep 0.5
run status > /dev/null 2>&1; check "stopped: status exits 30" $? 30
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
