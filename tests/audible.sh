#!/usr/bin/env bash
# Hardware tests. THESE PLAY MUSIC OUT LOUD.
#
# Only the things that cannot be faked live here: the CoreAudio checker against
# real audio clients, mpv's real volume ramp, and yielding to a real second
# player. Everything else is in tests/unit.sh, which is silent.
#
#   tests/audible.sh --yes
#   tests/audible.sh --yes --device 'coreaudio/BlackHole2ch'
#
# Do not run this while you are using the machine. It plays through your
# speakers, and it deliberately provokes the "something else is playing" path,
# so your own audio will interfere with the results and vice versa.
#
# It runs against a data directory of its own and a tone it generates, never
# your real one, and it switches off any agent-tunes install pointed at
# ~/.agent-tunes for the duration, putting it back afterwards. Both matter: a
# live agent session's hooks start and stop playback on their own schedule, and
# they may be a different released version running different code. Sharing a
# data directory with that produces results nobody can trust.
#
# Set AGENT_TUNES_HOME yourself to override, and you own the consequences.
#
# --device pins playback to a named audio device. Point it at a virtual one such
# as BlackHole (brew install blackhole-2ch) and the music is inaudible while
# still being real output, so the checker sees it as it sees anything else. That
# makes most of this runnable while you are working. System alert sounds still
# go to the default device, so the notification case remains audible.
# `mpv --audio-device=help` lists what is available.
set -uo pipefail

AUDIO_DEVICE=""
CONFIRMED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) CONFIRMED=1 ;;
    --device) AUDIO_DEVICE="${2:-}"; shift ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
  shift
done
[ "$CONFIRMED" = "1" ] || {
  echo "This plays audio out loud. Re-run with --yes when you are not using the machine."
  echo "Or pin it to a virtual device: --yes --device 'coreaudio/BlackHole2ch'"
  exit 2
}
[ "$(uname -s)" = "Darwin" ] || { echo "macOS only: it exercises CoreAudio."; exit 2; }

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$ROOT/bin/agent-tunes"

# Quieten whatever is driving the real data directory, so a live agent session
# cannot start a player in the middle of a measurement. cmd_start checks the
# switch before it registers anything, so off is enough, whatever version the
# hooks are running. Put back by restore().
REAL_HOME="$HOME/.agent-tunes"
REAL_WAS=""
if [ -d "$REAL_HOME" ]; then
  REAL_WAS="$(AGENT_TUNES_HOME="$REAL_HOME" "$T" status | awk '/state/{print $3}')"
  if [ "$REAL_WAS" = "on" ]; then
    AGENT_TUNES_HOME="$REAL_HOME" "$T" off >/dev/null 2>&1
    echo "  (switched $REAL_HOME off for the duration, it goes back on afterwards)"
    # CoreAudio keeps reporting a client as running output for seconds after it
    # stops, so the player we just killed still counts as somebody using the
    # speakers. Asserting idle before that clears fails the first check and
    # leaves every later one looking like a broken build.
    for _i in $(seq 1 60); do
      [ -x "$ROOT/libexec/audio-watch" ] || break
      "$ROOT/libexec/audio-watch" --once >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
fi

# Our own data directory and our own tone, so nothing here can touch your music
# and nothing of yours can wander into the results.
OWN_HOME=""
if [ -z "${AGENT_TUNES_HOME:-}" ]; then
  command -v ffmpeg >/dev/null || {
    echo "ffmpeg is needed to generate the test tone (brew install ffmpeg)," >&2
    echo "or set AGENT_TUNES_HOME to a directory holding a track." >&2
    exit 1
  }
  OWN_HOME="$(mktemp -d)"
  export AGENT_TUNES_HOME="$OWN_HOME"
  mkdir -p "$OWN_HOME/audio"
  ffmpeg -f lavfi -i "sine=frequency=220:duration=600" -c:a aac -y \
    "$OWN_HOME/audio/tone.m4a" >/dev/null 2>&1
  printf 'TUNES_VOLUME=20\n' >"$OWN_HOME/config.env"
  echo "  (using $OWN_HOME, not your own music)"
fi

D="$AGENT_TUNES_HOME"
TRACK="$(find "$D/audio/" -maxdepth 1 -type f 2>/dev/null | sort | head -1)"
[ -n "$TRACK" ] || { echo "No track in $D/audio. Add one with: agent-tunes tracks add <url>"; exit 1; }
WATCH="$ROOT/libexec/audio-watch"
LOG="$D/state/agent-tunes.log"

# Both our player and the stand-in "other app" follow the chosen device, so a
# virtual one silences the pair of them.
MPV_ARGS=()
if [ -n "$AUDIO_DEVICE" ]; then
  export TUNES_TEST_AUDIO_DEVICE="$AUDIO_DEVICE"
  export TUNES_PLAYER="$ROOT/tests/bin/mpv-device"
  MPV_ARGS=(--audio-device="$AUDIO_DEVICE")
  echo "  (playback pinned to $AUDIO_DEVICE)"
fi

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want '$3', got '$2')"; fi; }
cleanup() { "$T" stop --all >/dev/null 2>&1; pkill -f "mpv .*$D/audio" 2>/dev/null; sleep 1; }

# These tests drive playback, so it has to be switched on, and whatever the
# machine had set before must be put back afterwards.
WAS="$("$T" status | awk '/state/{print $3}')"
restore() {
  cleanup
  [ "$WAS" = "off" ] && "$T" off >/dev/null 2>&1
  [ -n "$OWN_HOME" ] && rm -rf "$OWN_HOME"
  [ "$REAL_WAS" = "on" ] && AGENT_TUNES_HOME="$REAL_HOME" "$T" on >/dev/null 2>&1
  return 0
}

# CoreAudio keeps reporting a client as running output for seconds after it
# stops, so a player killed a moment ago still counts as somebody using the
# speakers. Wait for it to clear rather than racing it.
wait_idle() {
  local i
  for i in $(seq 1 60); do
    [ -x "$WATCH" ] || return 0
    "$WATCH" --once >/dev/null 2>&1 && sleep 0.5 || return 0
  done
  return 0
}
trap restore EXIT

# Anything else using the speakers makes every measurement here meaningless: the
# first check asserts the machine is idle, and the rest need playback to start,
# which agent-tunes correctly refuses while somebody else is playing. Refuse up
# front and name the culprit, rather than reporting four failures that look like
# a broken build.
if [ -x "$ROOT/libexec/audio-watch" ]; then
  if busy_pid="$("$ROOT/libexec/audio-watch" --once 2>/dev/null)"; then
    busy_pid="${busy_pid#BUSY }"
    echo "Something is already playing audio, so these tests cannot run:" >&2
    ps -o pid,comm -p "$busy_pid" 2>/dev/null | tail -1 | sed 's/^/  /' >&2
    echo "Stop it, or wait for it to finish, and run this again." >&2
    exit 2
  fi
fi

"$T" on >/dev/null
cleanup

echo "== the checker reads real audio clients =="
if [ -x "$WATCH" ]; then
  "$WATCH" --once >/dev/null 2>&1; idle=$?
  chk "reports idle when nothing plays" "$idle" "1"
  mpv --no-video --no-terminal --really-quiet --no-config "${MPV_ARGS[@]+"${MPV_ARGS[@]}"}" --volume=5 "$TRACK" >/dev/null 2>&1 &
  other=$!; sleep 2
  "$WATCH" --once >/dev/null 2>&1; busy=$?
  chk "spots a real player"             "$busy" "0"
  kill $other 2>/dev/null; sleep 1
else
  echo "  SKIP  checker not built (agent-tunes build)"
fi

echo "== notification chimes are not treated as someone taking the speakers =="
cleanup; wait_idle; "$T" play >/dev/null 2>&1; sleep 5
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
  "$T" stop --all >/dev/null 2>&1
  wait $sampler 2>/dev/null
  chk "it faded rather than cutting" "$(grep -c 'mode=fade faded=1' "$LOG")" "1"
else
  bad "the real volume ramp (nothing was playing)"
fi

echo "== yields to a real second player =="
cleanup; wait_idle; "$T" play >/dev/null 2>&1; sleep 5
P="$(cat "$D/state/player.pid" 2>/dev/null)"
if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
  : >"$LOG"
  mpv --no-video --no-terminal --really-quiet --no-config "${MPV_ARGS[@]+"${MPV_ARGS[@]}"}" --volume=5 "$TRACK" >/dev/null 2>&1 &
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
