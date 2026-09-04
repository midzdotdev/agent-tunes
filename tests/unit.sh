#!/usr/bin/env bash
# Silent behaviour tests.
#
# Every external command is replaced by a stub in tests/stubs, so this makes no
# sound, needs no audio hardware, and cannot be disturbed by whatever else is
# using the speakers. It also runs against a throwaway data directory, so a real
# agent session working on the same machine does not show up in the counts.
#
# Runs on Linux as well as macOS, which is what lets it run in a container.
#
#   tests/unit.sh
#
# The parts that genuinely need hardware live in tests/audible.sh.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$ROOT/bin/agent-tunes"
STUBS="$ROOT/tests/stubs"

TMP="$(mktemp -d)"
export AGENT_TUNES_HOME="$TMP/data"
export TUNES_TEST_DIR="$TMP/probe"
export TUNES_PLAYER="$STUBS/mpv"
export TUNES_FADER="$STUBS/mpv-fade"
export TUNES_WATCHER="$STUBS/audio-watch"
export TUNES_FFPROBE="$STUBS/ffprobe"
mkdir -p "$AGENT_TUNES_HOME/audio" "$AGENT_TUNES_HOME/state" "$TUNES_TEST_DIR"
: >"$AGENT_TUNES_HOME/audio/test-track.m4a"

cat >"$AGENT_TUNES_HOME/config.env" <<'CONF'
TUNES_VOLUME=30
TUNES_START_DELAY=1
TUNES_FADE_IN=0.2
TUNES_FADE_OUT=0.2
TUNES_MIN_TAIL=300
TUNES_RESPECT_OTHER_AUDIO=1
TUNES_YIELD_TO_OTHER_AUDIO=1
TUNES_YIELD_SUSTAIN=0.2
TUNES_IGNORE_PROCESSES="systemsoundserverd"
TUNES_TRACK=""
CONF

D="$AGENT_TUNES_HOME"
LOG="$D/state/agent-tunes.log"
cleanup_all() { "$T" stop-all >/dev/null 2>&1; rm -f "$TUNES_TEST_DIR/other-audio"; }
trap 'cleanup_all; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want '$3', got '$2')"; fi; }

playing() {
  local p; p="$(cat "$D/state/player.pid" 2>/dev/null || true)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo yes; else echo no; fi
}
count() { find "$D/state/active" -type f 2>/dev/null | wc -l | tr -d ' '; }
settle() { sleep "${1:-2}"; }

echo "== the switch =="
"$T" off >/dev/null
"$T" start --key A >/dev/null; settle
chk "disabled: nothing plays"      "$(playing)" "no"
chk "disabled: nothing registers"  "$(count)"   "0"
"$T" on >/dev/null
chk "enabled"                      "$("$T" status | awk '/state/{print $3}')" "on"

echo "== the start delay =="
: >"$LOG"; "$T" start --key A >/dev/null
chk "silent before the delay is up" "$(playing)" "no"
settle
chk "playing once it is"            "$(playing)" "yes"

echo "== several agents =="
"$T" start --key B >/dev/null; sleep 0.5
chk "B joins"                "$(playing)/$(count)" "yes/2"
"$T" start --key C >/dev/null; sleep 0.5
chk "C joins"                "$(playing)/$(count)" "yes/3"
"$T" stop  --key A >/dev/null; sleep 0.5
chk "A leaves, music stays"  "$(playing)/$(count)" "yes/2"
"$T" stop  --key C >/dev/null; sleep 0.5
chk "C leaves, music stays"  "$(playing)/$(count)" "yes/1"
: >"$TUNES_TEST_DIR/fade-args"
"$T" stop  --key B >/dev/null; sleep 0.5
chk "last one out stops it"  "$(playing)/$(count)" "no/0"
chk "it faded on the way out" "$(grep -c -- "--quit" "$TUNES_TEST_DIR/fade-args")" "1"
chk "fade ramps down to zero" "$(grep -- "--quit" "$TUNES_TEST_DIR/fade-args" | awk '{print $3}' | head -1)" "0"
chk "an unknown key is harmless" "$("$T" stop --key NeverRegistered >/dev/null 2>&1; echo $?)" "0"

echo "== getting out of the way =="
: >"$TUNES_TEST_DIR/other-audio"
: >"$LOG"; "$T" start --key A >/dev/null; settle
chk "will not start over other audio" "$(playing)" "no"
chk "and says why"  "$(grep -c 'skip: other audio playing' "$LOG")" "1"
"$T" stop --key A >/dev/null
rm -f "$TUNES_TEST_DIR/other-audio"

: >"$LOG"; : >"$TUNES_TEST_DIR/fade-args"
"$T" start --key A >/dev/null; settle
chk "plays once the other audio stops" "$(playing)" "yes"
: >"$TUNES_TEST_DIR/other-audio"      # someone else starts playing
sleep 2
chk "yields to it"            "$(playing)" "no"
chk "without fading"          "$(grep -c -- "--quit" "$TUNES_TEST_DIR/fade-args")" "0"
chk "and records why"         "$(grep -c 'mode=now faded=0' "$LOG")" "1"
"$T" stop --key A >/dev/null
rm -f "$TUNES_TEST_DIR/other-audio"

echo "== picking a position =="
: >"$TUNES_TEST_DIR/player-args"
for i in 1 2 3 4; do
  "$T" start --key "R$i" >/dev/null; settle
  "$T" stop --key "R$i" >/dev/null; sleep 0.5
done
starts=$(grep -o -- '--start=[0-9]*' "$TUNES_TEST_DIR/player-args" | sort -u | wc -l | tr -d ' ')
chk "each start picks a fresh position" "$starts" "4"
maxoff=$(grep -o -- '--start=[0-9]*' "$TUNES_TEST_DIR/player-args" | cut -d= -f2 | sort -n | tail -1)
chk "never within the closing minutes" "$([ "${maxoff:-0}" -le 3300 ] && echo yes || echo "no ($maxoff)")" "yes"

echo "== nothing to play =="
mv "$D/audio/test-track.m4a" "$TMP/held.m4a"
: >"$LOG"; "$T" start --key A >/dev/null; settle
chk "says so rather than failing" "$(grep -c 'skip: no track' "$LOG")" "1"
"$T" stop --key A >/dev/null
mv "$TMP/held.m4a" "$D/audio/test-track.m4a"

echo "== the Pi extension =="
# Silent: loading happens before any model call, so this needs no credentials.
if command -v pi >/dev/null 2>&1; then
  err=$(timeout 90 pi -e "$ROOT/pi/agent-tunes.ts" -p "hi" </dev/null 2>&1 \
        | grep -ci "failed to load extension" | tr -d ' ')
  chk "Pi loads it without complaint" "$err" "0"

  # Loading is not enough. It shells out to the agent-tunes command, and that
  # once resolved to the data directory, where no executable lives.
  probe="$TMP/probe.ts"
  sed 's|  pi.registerCommand("tunes", {|  try { require("node:fs").writeFileSync(process.env.TUNES_TEST_DIR + "/cli-path", CLI); } catch {}\n\n  pi.registerCommand("tunes", {|' \
    "$ROOT/pi/agent-tunes.ts" >"$probe"
  rm -f "$TUNES_TEST_DIR/cli-path"
  timeout 90 pi -e "$probe" -p "hi" </dev/null >/dev/null 2>&1
  resolved="$(cat "$TUNES_TEST_DIR/cli-path" 2>/dev/null || true)"
  chk "the command it resolves exists" \
      "$([ -n "$resolved" ] && [ -x "$resolved" ] && echo yes || echo "no ($resolved)")" "yes"
else
  echo "  SKIP  Pi is not installed here"
fi

echo "== leaves nothing behind =="
cleanup_all; sleep 0.5
chk "no player left running" "$(playing)" "no"
chk "no sessions left"       "$(count)"   "0"
chk "no stale locks"         "$(ls -d "$D"/state/pending.lock "$D"/state/mpv.sock 2>/dev/null | wc -l | tr -d ' ')" "0"

echo
echo "=================== $pass passed, $fail failed ==================="
[ "$fail" -eq 0 ]
