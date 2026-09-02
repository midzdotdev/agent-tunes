#!/usr/bin/env bash
# agent-tunes acceptance suite. Run from ~/agent-tunes.
cd ~/agent-tunes || exit 1
T=./bin/agent-tunes
D="${AGENT_TUNES_HOME:-$HOME/.agent-tunes}"
TRACK="$(find "$D/audio" -maxdepth 1 -type f | sort | head -1)"
[ -n "$TRACK" ] || { echo "No track in $D/audio. Add one with: agent-tunes download <url>"; exit 1; }
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want '$3', got '$2')"; fi; }
playing() { pgrep -f "mpv .*$D/audio" >/dev/null && echo yes || echo no; }
count()   { find "$D"/state/active -type f 2>/dev/null | wc -l | tr -d ' '; }
cleanup() { $T stop-all >/dev/null 2>&1; pkill -f "ffplay.*$D/audio" 2>/dev/null; pkill -f "mpv.*$D/audio" 2>/dev/null; sleep 1; }

cleanup; rm -f "$D"/state/agent-tunes.log

echo "== 1. doctor =="
if $T doctor | grep -q FAIL; then bad "doctor has failures"; $T doctor; else ok "all doctor checks green"; fi

echo "== 2. switch =="
$T off >/dev/null; chk "off disables" "$($T status | awk '/state/{print $3}')" "off"
$T start --key X >/dev/null 2>&1; sleep 6
chk "disabled start is a no-op" "$(playing)" "no"
chk "disabled start registers nothing" "$(count)" "0"
$T on >/dev/null; chk "on enables" "$($T status | awk '/state/{print $3}')" "on"

echo "== 3. multi-agent reference counting =="
$T start --key AgentA >/dev/null; sleep 8
chk "A starts work" "$(playing)/$(count)" "yes/1"
$T start --key AgentB >/dev/null; sleep 1
chk "B joins"       "$(playing)/$(count)" "yes/2"
$T start --key AgentC >/dev/null; sleep 1
chk "C joins"       "$(playing)/$(count)" "yes/3"
$T stop  --key AgentA >/dev/null; sleep 1
chk "A leaves"      "$(playing)/$(count)" "yes/2"
$T stop  --key AgentC >/dev/null; sleep 1
chk "C leaves"      "$(playing)/$(count)" "yes/1"
OFF1=$(grep -c "playing pid=" "$D"/state/agent-tunes.log)
$T stop  --key AgentB >/dev/null; sleep 1
chk "last one out stops it" "$(playing)/$(count)" "no/0"
chk "stopped with a fade" "$(tail -1 "$D"/state/agent-tunes.log | grep -o 'mode=fade faded=1')" "mode=fade faded=1"
chk "unknown key is harmless" "$($T stop --key NeverRegistered >/dev/null 2>&1; echo $?)" "0"

echo "== 4. fade-out ramps the volume =="
$T play >/dev/null; sleep 5
VOLS=""
( for i in 1 2 3 4 5; do
    v=$(python3 -c "
import json,socket,sys
try:
    s=socket.socket(socket.AF_UNIX); s.settimeout(1); s.connect('$D/state/mpv.sock')
    s.sendall((json.dumps({'command':['get_property','volume']})+'\n').encode())
    buf=b''
    while True:
        d=s.recv(4096)
        if not d: break
        buf+=d
        for line in buf.split(b'\n'):
            if b'\"data\"' in line: print(int(json.loads(line)['data'])); sys.exit()
except Exception: print('-')
"); echo "$v" >> /tmp/vols.txt; sleep 0.3
  done ) & S=$!
rm -f /tmp/vols.txt
T0=$(python3 -c 'import time;print(time.time())')
$T stop-all >/dev/null
T1=$(python3 -c 'import time;print(time.time())')
wait $S
VOLS=$(tr '\n' ' ' < /tmp/vols.txt)
echo "     sampled volumes: $VOLS"
DESC=$(python3 -c "
v=[int(x) for x in '$VOLS'.split() if x.isdigit()]
print('yes' if len(v)>=3 and all(a>=b for a,b in zip(v,v[1:])) and v[0]>v[-1] else 'no')")
chk "volume ramps downwards" "$DESC" "yes"
chk "stop takes about the fade length" "$(python3 -c "print('yes' if 1.4 <= $T1-$T0 <= 3.0 else 'no ($T1-$T0)')")" "yes"

echo "== 5. yields immediately to other audio =="
$T play >/dev/null; sleep 5
P=$(cat "$D"/state/player.pid)
T0=$(python3 -c 'import time;print(time.time())')
mpv --no-video --no-terminal --really-quiet --no-config --volume=5 --start=900 "$TRACK" >/dev/null 2>&1 & O=$!
for i in $(seq 1 500); do kill -0 "$P" 2>/dev/null || break; sleep 0.02; done
T1=$(python3 -c 'import time;print(time.time())')
LAT=$(python3 -c "print('%.2f' % ($T1-$T0))")
echo "     yielded after ${LAT}s"
chk "stopped for the other app" "$(kill -0 "$P" 2>/dev/null && echo alive || echo gone)" "gone"
chk "yielded within 3s" "$(python3 -c "print('yes' if $LAT < 3.0 else 'no')")" "yes"
chk "no fade when yielding" "$(tail -1 "$D"/state/agent-tunes.log | grep -o 'mode=now faded=0')" "mode=now faded=0"

kill $O 2>/dev/null; sleep 2

echo "== 6. will not start while another app is playing =="
# ffplay as the interferer, so "is OUR player running" stays unambiguous.
ffplay -nodisp -autoexit -loglevel quiet -volume 5 -ss 900 "$TRACK" >/dev/null 2>&1 & O2=$!
sleep 3
$T start --key Busy >/dev/null; sleep 8
chk "start suppressed" "$(playing)" "no"
chk "logged the skip" "$(tail -1 "$D"/state/agent-tunes.log | grep -o 'skip: other audio playing')" "skip: other audio playing"
kill $O2 2>/dev/null; sleep 2
$T stop --key Busy >/dev/null

echo "== 7. starts from a random position =="
OFFS=$(grep -o 'offset=[0-9]*' "$D"/state/agent-tunes.log | sort -u | wc -l | tr -d ' ')
STARTS=$(grep -c 'playing pid=' "$D"/state/agent-tunes.log)
chk "every start used a distinct offset" "$OFFS" "$STARTS"

echo "== 8. leaves nothing behind =="
cleanup
chk "no stray players or guards" "$(pgrep -f 'mpv|ffplay|audio-watch' | wc -l | tr -d ' ')" "0"
chk "no stale locks" "$(ls -d "$D"/state/pending.lock "$D"/state/mpv.sock 2>/dev/null | wc -l | tr -d ' ')" "0"

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" -eq 0 ]
