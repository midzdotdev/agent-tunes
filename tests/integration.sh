#!/usr/bin/env bash
# Real player, real volume ramp, still silent.
#
# tests/unit.sh stubs the player and the fader, which leaves the actual mpv
# integration untested: the IPC socket, the volume ramp, quitting at the bottom
# of it, and seeking to the chosen position. This runs the real ones with mpv's
# null audio output, so it opens no audio device, makes no sound, and does not
# register as an audio client. It works on Linux too.
#
# Only the CoreAudio checker stays stubbed, because that one cannot be faked
# and cannot run off macOS. It has its own coverage in tests/audible.sh.
#
#   tests/integration.sh
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$ROOT/bin/agent-tunes"

command -v mpv     >/dev/null || { echo "SKIP: mpv is not installed";     exit 0; }
command -v ffmpeg  >/dev/null || { echo "SKIP: ffmpeg is not installed";  exit 0; }
command -v ffprobe >/dev/null || { echo "SKIP: ffprobe is not installed"; exit 0; }

TMP="$(mktemp -d)"
export AGENT_TUNES_HOME="$TMP/data"
export TUNES_TEST_DIR="$TMP/probe"
export TUNES_PLAYER="$ROOT/tests/bin/mpv-null"   # real mpv, no audio device
export TUNES_FADER="$ROOT/libexec/mpv-fade"      # the real volume ramp
export TUNES_WATCHER="$ROOT/tests/stubs/audio-watch"
mkdir -p "$AGENT_TUNES_HOME/audio" "$AGENT_TUNES_HOME/state" "$TUNES_TEST_DIR"

# A real file, so the real ffprobe has something real to measure.
ffmpeg -f lavfi -i "sine=frequency=440:duration=600" -c:a aac -y \
  "$AGENT_TUNES_HOME/audio/tone.m4a" >/dev/null 2>&1

cat >"$AGENT_TUNES_HOME/config.env" <<'CONF'
TUNES_VOLUME=40
TUNES_START_DELAY=1
TUNES_FADE_IN=0.3
TUNES_FADE_OUT=2
TUNES_MIN_TAIL=120
TUNES_RESPECT_OTHER_AUDIO=1
TUNES_YIELD_TO_OTHER_AUDIO=1
TUNES_YIELD_SUSTAIN=0.2
TUNES_TRACK=""
CONF

D="$AGENT_TUNES_HOME"
LOG="$D/state/agent-tunes.log"
trap '"$T" stop-all >/dev/null 2>&1; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want '$3', got '$2')"; fi; }
alive() { local p; p="$(cat "$D/state/player.pid" 2>/dev/null || true)"
          if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo yes; else echo no; fi; }

ask_mpv() {  # property -> value, over the same IPC socket the fader uses
  python3 - "$D/state/mpv.sock" "$1" <<'PY' 2>/dev/null
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])
    s.sendall((json.dumps({"command": ["get_property", sys.argv[2]]}) + "\n").encode())
    buf = b""
    while True:
        d = s.recv(4096)
        if not d: break
        buf += d
        for line in buf.split(b"\n"):
            if b'"data"' in line:
                print(json.loads(line)["data"]); sys.exit()
except Exception:
    pass
PY
}

echo "== the real player starts =="
"$T" on >/dev/null
"$T" start --key A >/dev/null; sleep 3
chk "mpv is running"        "$(alive)" "yes"
chk "its IPC socket is up"  "$([ -S "$D/state/mpv.sock" ] && echo yes || echo no)" "yes"

echo "== it seeks to the chosen position =="
want=$(grep -o 'offset=[0-9]*' "$LOG" | tail -1 | cut -d= -f2)
got=$(ask_mpv time-pos); got=${got%%.*}
near=$(python3 -c "
w=int('${want:-0}'); g=int('${got:-0}')
print('yes' if abs(g-w) <= 15 else f'no (asked {w}, at {g})')")
chk "playing near the offset it logged" "$near" "yes"

echo "== the real fade =="
before=$(ask_mpv volume); before=${before%%.*}
chk "at the configured volume" "$([ "${before:-0}" -ge 35 ] && echo yes || echo "no ($before)")" "yes"
( sleep 0.8; mid=$(ask_mpv volume); echo "${mid%%.*}" >"$TUNES_TEST_DIR/mid-volume" ) &
sampler=$!
"$T" stop --key A >/dev/null
wait $sampler 2>/dev/null
mid=$(cat "$TUNES_TEST_DIR/mid-volume" 2>/dev/null)
chk "volume was ramped down"  "$([ -n "$mid" ] && [ "$mid" -lt "$before" ] && echo yes || echo "no ($before -> ${mid:-none})")" "yes"
chk "mpv quit at the bottom"  "$(alive)" "no"
chk "recorded as a fade"      "$(grep -c 'mode=fade faded=1' "$LOG")" "1"

echo "== yielding kills it outright =="
: >"$LOG"
"$T" start --key A >/dev/null; sleep 3
chk "playing again" "$(alive)" "yes"
: >"$TUNES_TEST_DIR/other-audio"
sleep 2
chk "stopped for the other audio" "$(alive)" "no"
chk "and did not fade"            "$(grep -c 'mode=now faded=0' "$LOG")" "1"
rm -f "$TUNES_TEST_DIR/other-audio"
"$T" stop --key A >/dev/null

echo "== the real duration is respected =="
dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$D/audio/tone.m4a" | cut -d. -f1)
chk "ffprobe read the track" "$([ "${dur:-0}" -ge 590 ] && echo yes || echo "no ($dur)")" "yes"
maxoff=$(grep -o 'offset=[0-9]*' "$LOG" | cut -d= -f2 | sort -n | tail -1)
chk "offset leaves the tail alone" \
    "$([ "${maxoff:-0}" -le $((dur - 120)) ] && echo yes || echo "no ($maxoff of $dur)")" "yes"

echo
echo "=================== $pass passed, $fail failed ==================="
[ "$fail" -eq 0 ]
