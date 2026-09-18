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
CONF

D="$AGENT_TUNES_HOME"
LOG="$D/state/agent-tunes.log"
cleanup_all() { "$T" stop --all >/dev/null 2>&1; rm -f "$TUNES_TEST_DIR/other-audio"; }
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

echo "== managing tracks =="
: >"$TMP/spare.m4a"; : >"$TMP/second.m4a"
: >"$TMP/noaudio.m4a"; : >"$TMP/unplayable.m4a"; : >"$TMP/notes.txt"
chk "adds a playable file"        "$("$T" tracks add "$TMP/spare.m4a" >/dev/null 2>&1; echo $?)" "0"
chk "and it is there"             "$([ -f "$D/audio/spare.m4a" ] && echo yes || echo no)" "yes"
chk "refuses a file with no sound" "$("$T" tracks add "$TMP/noaudio.m4a" >/dev/null 2>&1; echo $?)" "1"
chk "refuses one it cannot open"  "$("$T" tracks add "$TMP/unplayable.m4a" >/dev/null 2>&1; echo $?)" "1"
chk "refuses a non-audio suffix"  "$("$T" tracks add "$TMP/notes.txt" >/dev/null 2>&1; echo $?)" "1"
chk "refuses to overwrite"        "$("$T" tracks add "$TMP/spare.m4a" >/dev/null 2>&1; echo $?)" "1"
chk "lists what is there"         "$("$T" tracks list | grep -c 'spare.m4a')" "1"
chk "reveals where they live"     "$("$T" tracks dir)" "$D/audio"

"$T" tracks disable spare >/dev/null
chk "disable marks it"            "$([ -f "$D/state/disabled/spare.m4a" ] && echo yes || echo no)" "yes"
chk "and list says so"            "$("$T" tracks list | grep -c 'spare.m4a .*disabled')" "1"
"$T" tracks enable spare >/dev/null
chk "enable clears the mark"      "$([ -f "$D/state/disabled/spare.m4a" ] && echo yes || echo no)" "no"

"$T" tracks add "$TMP/second.m4a" >/dev/null
chk "an ambiguous name is refused" "$("$T" tracks disable ".m4a" >/dev/null 2>&1; echo $?)" "1"
chk "an unknown name is refused"   "$("$T" tracks disable nonesuch >/dev/null 2>&1; echo $?)" "1"
"$T" tracks disable --all >/dev/null
chk "--all covers every track" "$(find "$D/state/disabled" -type f | wc -l | tr -d ' ')" "3"
: >"$LOG"; "$T" start --key A >/dev/null; settle
chk "so nothing plays"            "$(playing)" "no"
chk "and it says why"             "$(grep -c 'every track is disabled' "$LOG")" "1"
"$T" stop --key A >/dev/null
"$T" tracks enable --all >/dev/null
chk "and clears them all again"      "$(find "$D/state/disabled" -type f | wc -l | tr -d ' ')" "0"

echo "== a track name is a name, not a path =="
mkdir -p "$TMP/precious"; echo keep >"$TMP/precious/notes.txt"
chk "remove refuses to traverse"  "$("$T" tracks remove "../../precious/notes.txt" --yes >/dev/null 2>&1; echo $?)" "1"
chk "and the file is still there" "$([ -f "$TMP/precious/notes.txt" ] && echo yes || echo no)" "yes"
chk "disable refuses too"         "$("$T" tracks disable "../../precious/notes.txt" >/dev/null 2>&1; echo $?)" "1"

echo "== a filename is never run as shell =="
# doctor used to build its checks as strings and eval them, so a track called
# "mix $(...).m4a" ran whatever it held. The payload has to be relative: a
# filename cannot contain a slash, which is what makes the cwd the evidence.
BOOBY='mix $(touch PWNED).m4a'
mkdir -p "$TMP/cwd"; : >"$D/audio/$BOOBY"
chk "the booby-trapped track exists" "$([ -f "$D/audio/$BOOBY" ] && echo yes || echo no)" "yes"
( cd "$TMP/cwd" && "$T" doctor >/dev/null 2>&1 )
chk "doctor does not execute a track name" \
    "$([ -e "$TMP/cwd/PWNED" ] && echo executed || echo no)" "no"
rm -f "$D/audio/$BOOBY"

echo "== without a player it says so =="
: >"$LOG"
TUNES_PLAYER=no-such-player-here "$T" start --key NP >/dev/null; settle
chk "launch names the missing player" "$(grep -c 'is not installed' "$LOG")" "1"
"$T" stop --key NP >/dev/null
: >"$TMP/unseen.m4a"
chk "and add blames the player, not the file" \
    "$(TUNES_PLAYER=no-such-player-here "$T" tracks add "$TMP/unseen.m4a" 2>&1 | grep -c 'is not installed')" "1"

echo "== a marker cannot outlive its track =="
: >"$D/state/disabled/ghost.m4a"
"$T" tracks list >/dev/null
chk "swept on the next tracks command" "$([ -f "$D/state/disabled/ghost.m4a" ] && echo yes || echo no)" "no"

echo "== removing a track =="
chk "needs --yes when not a terminal" "$("$T" tracks remove second </dev/null >/dev/null 2>&1; echo $?)" "1"
"$T" tracks remove second --yes >/dev/null
chk "removes the file"            "$([ -f "$D/audio/second.m4a" ] && echo yes || echo no)" "no"
chk "and its marker with it"      "$([ -f "$D/state/disabled/second.m4a" ] && echo yes || echo no)" "no"

echo "== choosing which track to play =="
# Only the enabled ones are candidates, so this is deterministic.
"$T" tracks disable spare >/dev/null
: >"$TUNES_TEST_DIR/player-args"
for i in 1 2 3; do
  "$T" start --key "P$i" >/dev/null; settle
  "$T" stop --key "P$i" >/dev/null; sleep 0.5
done
# Counted against the launches that actually happened, not against a fixed
# number of them: how reliably a start produces a launch is a timing question,
# and it has its own tests above.
launches=$(grep -c -- '--start=' "$TUNES_TEST_DIR/player-args")
chk "it launched at all"           "$([ "${launches:-0}" -ge 1 ] && echo yes || echo no)" "yes"
chk "never picks a disabled track" "$(grep -c 'spare.m4a' "$TUNES_TEST_DIR/player-args")" "0"
chk "every launch used an enabled track" \
    "$(grep -c 'test-track.m4a' "$TUNES_TEST_DIR/player-args")" "$launches"
"$T" tracks enable spare >/dev/null

# The pick indexes into the whole enabled list rather than always landing on
# the first, which is what the old single-track behaviour did. Three tracks and
# an exact expectation per index, so a correct implementation never fails here.
: >"$TMP/aaa.m4a"; "$T" tracks add "$TMP/aaa.m4a" >/dev/null
i=0
for want in aaa.m4a spare.m4a test-track.m4a; do
  : >"$TUNES_TEST_DIR/player-args"
  TUNES_PICK_INDEX=$i "$T" play >/dev/null 2>&1; sleep 0.5
  "$T" stop --all >/dev/null; sleep 0.5
  chk "index $i picks $want" "$(grep -c -- "$want" "$TUNES_TEST_DIR/player-args")" "1"
  i=$((i + 1))
done
"$T" tracks remove spare --yes >/dev/null
"$T" tracks remove aaa --yes >/dev/null

echo "== found through a symlink =="
# ~/.local/bin/agent-tunes is a link into the checkout, and taking dirname of
# the link used to put ROOT somewhere with no libexec/, quietly costing the
# fade-out and the yielding.
ln -sf "$T" "$TMP/linked-agent-tunes"
chk "resolves to the checkout, not the link" \
    "$("$TMP/linked-agent-tunes" status | awk '/code/{print $3}')" "$ROOT"

echo "== a session that stops checking in is forgotten =="
"$T" start --key LIVE >/dev/null; : >"$D/state/active/k-ghost"
chk "both are registered" "$(count)" "2"
touch -t "$(date -v-90M +%Y%m%d%H%M 2>/dev/null || date -d '90 minutes ago' +%Y%m%d%H%M)" \
      "$D/state/active/k-ghost"
"$T" status >/dev/null
chk "the stale one is reaped"  "$([ -f "$D/state/active/k-ghost" ] && echo yes || echo no)" "no"
chk "the live one is untouched" "$([ -f "$D/state/active/k-LIVE" ] && echo yes || echo no)" "yes"
"$T" stop --key LIVE >/dev/null; settle 1

echo "== and the music does not outlive it =="
# Nothing would ever run a command again in the case this covers, so the
# player carries a watchdog of its own.
: >"$LOG"
TUNES_WATCHDOG_INTERVAL=1 "$T" start --key DOOMED >/dev/null; settle
chk "playing while it is registered" "$(playing)" "yes"
touch -t "$(date -v-90M +%Y%m%d%H%M 2>/dev/null || date -d '90 minutes ago' +%Y%m%d%H%M)" \
      "$D/state/active/k-DOOMED"
for i in 1 2 3 4 5 6 7 8; do [ "$(playing)" = "no" ] && break; sleep 1; done
chk "stopped once nothing was left"  "$(playing)" "no"
chk "and said why"                   "$(grep -c 'no sessions left' "$LOG")" "1"
"$T" stop --all >/dev/null

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
