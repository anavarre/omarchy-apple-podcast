#!/usr/bin/env bash
# Runs bin/podcasts-api against tests/fixture_server.py; no network, no Apple.
set -u
cd "$(dirname "$0")/.." || exit 1
here=$PWD
tmp=$(mktemp -d); trap 'kill $srv 2>/dev/null; rm -rf "$tmp"' EXIT
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
good=$(printf 'A%.0s' {1..60})
python3 tests/fixture_server.py "$port" "$good" & srv=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/us/new" > /dev/null && break; sleep 0.1; done

export HOME=$tmp PODCASTS_PLUGIN_DIR=$tmp/store
export PODCASTS_API_BASE=http://127.0.0.1:$port PODCASTS_WEB_BASE=http://127.0.0.1:$port
run() { bash "$here/bin/podcasts-api" "$@"; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fails=$((fails + 1)); fi; }

check "config without token" "$(run config | grep -c '"hasToken":false')" 1
run episodes 5 latest > /dev/null 2>&1; check "episodes without token exits 12" $? 12
echo 'short' | run save > /dev/null 2>&1; check "short token refused (26)" $? 26
echo 'bad token!!' | run save > /dev/null 2>&1; check "junk token refused (26)" $? 26
echo "media-user-token=$good; Path=/" | run save; check "cookie pair accepted" $? 0
check "token file mode 600" "$(stat -c %a "$tmp/store/media-user-token")" 600
check "store dir mode 700" "$(stat -c %a "$tmp/store")" 700
check "config with token" "$(run config | grep -c '"hasToken":true')" 1

out=$(run episodes 5 latest); rc=$?
check "episodes exit 0" "$rc" 0
check "episodes status line" "$(printf '%s\n' "$out" | tail -n1)" "HTTP 200"
check "episodes body has title" "$(printf '%s' "$out" | grep -c 'Episode One')" 1
check "dev token cached" "$([ -s "$tmp/store/dev-token" ] && echo yes)" yes
check "up-next works" "$(run episodes 5 up-next | tail -n1)" "HTTP 200"

# Positions: what another device left, and what this one writes back.
pos=$(run positions 1001,1002); check "positions exit 0" $? 0
check "positions status line" "$(printf '%s\n' "$pos" | tail -n1)" "HTTP 200"
check "positions has the saved one" "$(printf '%s' "$pos" | grep -c '"positionInMilliseconds":600000')" 1
check "positions omits unknown episode" "$(printf '%s' "$pos" | grep -c '"id":"1002"')" 0
sp=$(run setposition 1002 754000 false); check "setposition exit 0" $? 0
check "setposition is a 204" "$(printf '%s\n' "$sp" | tail -n1)" "HTTP 204"
check "written position reads back" "$(run positions 1002 | grep -c '"positionInMilliseconds":754000')" 1
run setposition 1002 1800000 true > /dev/null
check "completed reads back" "$(run positions 1002 | grep -c '"completed":true')" 1
run positions '' > /dev/null 2>&1; check "empty ids refused (64)" $? 64
run positions '1001;rm' > /dev/null 2>&1; check "junk ids refused (64)" $? 64
run positions "$(seq -s, 1 31)" > /dev/null 2>&1; check "31 ids refused (64)" $? 64
run setposition abc 5 false > /dev/null 2>&1; check "bad id refused (64)" $? 64
run setposition 1002 -5 false > /dev/null 2>&1; check "bad ms refused (64)" $? 64
run setposition 1002 5 maybe > /dev/null 2>&1; check "bad flag refused (64)" $? 64

printf 'B%.0s' {1..60} | run save
run episodes 5 latest > /dev/null 2>&1; check "wrong token exits 21" $? 21
run positions 1001 > /dev/null 2>&1; check "positions wrong token exits 21" $? 21
run setposition 1001 5 false > /dev/null 2>&1; check "setposition wrong token exits 21" $? 21

run episodes 0 latest > /dev/null 2>&1; check "limit 0 refused (64)" $? 64
run episodes 5 bogus > /dev/null 2>&1; check "bad source refused (64)" $? 64
PODCASTS_API_BASE=http://evil.example run config > /dev/null 2>&1; check "plain http off-box refused" $? 64

run savepos 1002 321000 false; check "savepos exit 0" $? 0
check "getpos reads it back" "$(run getpos 1002 | cut -d' ' -f1,2)" "321000 false"
check "getpos unknown is empty" "$(run getpos 9999)" ""
run savepos 1002 5 maybe > /dev/null 2>&1; check "savepos bad flag refused (64)" $? 64

run forget; check "forget empties store" "$(ls -A "$tmp/store" | wc -l)" 0
mkdir "$tmp/real"; ln -s "$tmp/real" "$tmp/link"
echo "$good" | PODCASTS_PLUGIN_DIR=$tmp/link run save > /dev/null 2>&1; check "symlinked store refused (24)" $? 24

# The token must never be visible in argv while a request is in flight.
check "no token in script source" "$(grep -c "$good" bin/podcasts-api)" 0
[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
