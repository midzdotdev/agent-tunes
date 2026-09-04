#!/usr/bin/env bash
# Hardware tests. THESE PLAY MUSIC OUT LOUD.
#
# Only the things that cannot be faked live here: the CoreAudio checker against
# real audio clients, mpv's real volume ramp, and yielding to a real second
# player. Everything else is in tests/unit.sh, which is silent.
#
#   tests/audible.sh --yes
#
# Do not run this while you are using the machine. It plays through your
# speakers, and it deliberately provokes the "something else is playing" path,
# so your own audio will interfere with the results and vice versa.
set -uo pipefail

[ "${1:-}" = "--yes" ] || {
  echo "This plays audio out loud. Re-run with --yes when you are not using the machine."
  exit 2
}
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only: it exercises CoreAudio."; exit 2; }

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$ROOT/bin/agent-tunes"
D="${AGENT_TUNES_HOME:-$HOME/.agent-tunes}"
TRACK="$(find "$D/audio/" -maxdepth 1 -type f 2>/dev/null | sort | head -1)"
[ -n "$TRACK" ] || { echo "No track in $D/audio. Add one with: agent-tunes download <url>"; exit 1; }
WATCH="$ROOT/libexec/audio-watch"
LOG="$D/state/agent-tunes.log"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want '$3', got '$2')"; fi; }
cleanup() { "$T" stop-all >/dev/null 2>&1; pkill -f "mpv .*$D/audio" 2>/dev/null; sleep 1; }
trap cleanup EXIT
cleanup

echo "== the checker reads real audio clients =="
if [ -x "$WATCH" ]; then
  "$WATCH" --once >/dev/null 2>&1; idle=$?
  chk "reports idle when nothing plays" "$idle" "1"
  mpv --no-video --no-terminal --really-quiet --no-config --volume=5 "$TRACK" >/dev/null 2>&1 &
  other=$!; sleep 2
  "$WATCH" --once >/dev/null 2>&1; busy=$?
  chk "spots a real player"             "$busy" "0"
  kill $other 2>/dev/null; sleep 1
else
  echo "  SKIP  checker not built (agent-tunes build)"
fi

echo "== notification chimes are not treated as someone taking the speakers =="
cleanup; "$T" play >/dev/null 2>&1; sleep 5
P="$(cat "$D/state/player.pid" 2>/dev/null)"
if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
  osascript -e 'display notification "test" with title "agent-tunes" sound name "Ping"' >/dev/null 2>&1
  sleep 3
  chk "music survives a notification" "$(kill -0 "$P" 2>/dev/null && echo alive || echo gone)" "alive"
else
  bad "music survives a notification (could not start playback)"
fi

echo "== the real volume ramp =="
: >"$LOG"
if [ -n "${P:-}" ] && kill -0 "$P" 2>/dev/null; then
  vols=""
  for i in 1 2 3 4 5; do
    v=$(python3 - "$D/state/mpv.sock" <<'PY' 2>/dev/null
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(1); s.connect(sys.argv[1])
    s.sendall((json.dumps({"command": ["get_property", "volume"]}) + "\n").encode())
    buf = b""
    while True:
        d = s.recv(4096)
        if not d: break
        buf += d
        for line in buf.split(b"\n"):
            if b'"data"' in line:
                print(int(json.loads(line)["data"])); sys.exit()
except Exception:
    pass
PY
)
    [ -n "$v" ] && vols="$vols $v"
    sleep 0.3
  done &
  sampler=$!
  "$T" stop-all >/dev/null 2>&1
  wait $sampler 2>/dev/null
  chk "it faded rather than cutting" "$(grep -c 'mode=fade faded=1' "$LOG")" "1"
else
  bad "the real volume ramp (nothing was playing)"
fi

echo "== yields to a real second player =="
cleanup; "$T" play >/dev/null 2>&1; sleep 5
P="$(cat "$D/state/player.pid" 2>/dev/null)"
if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
  : >"$LOG"
  mpv --no-video --no-terminal --really-quiet --no-config --volume=5 "$TRACK" >/dev/null 2>&1 &
  other=$!
  for i in $(seq 1 250); do kill -0 "$P" 2>/dev/null || break; sleep 0.02; done
  chk "stopped for it"   "$(kill -0 "$P" 2>/dev/null && echo alive || echo gone)" "gone"
  chk "and did not fade" "$(grep -c 'mode=now faded=0' "$LOG")" "1"
  kill $other 2>/dev/null
else
  bad "yields to a real second player (could not start playback)"
fi

cleanup
echo
echo "=================== $pass passed, $fail failed ==================="
[ "$fail" -eq 0 ]
