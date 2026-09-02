#!/usr/bin/env bash
# First-run setup, triggered by the plugin's SessionStart hook.
#
# Claude Code has no postinstall hook, and it disables npm preinstall/install/
# postinstall scripts for plugins, so SessionStart is the only place a plugin
# can finish setting itself up. This runs on every session start and does
# nothing at all once the work is done, so keep the fast path fast.
#
# Anything slow happens in the background. A SessionStart hook blocks the
# session while it runs, and nobody should wait on a download to start work.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
DATA="${AGENT_TUNES_HOME:-$HOME/.agent-tunes}"
STAMP="$DATA/.setup-done"
RELEASE="https://github.com/midzdotdev/agent-tunes/releases/latest/download/audio-watch"

# The stamp records which version was set up. A plugin update ships a new
# audio-watch, so a version change has to re-fetch it rather than keep the old
# binary that happens to still be sitting there.
VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1)"
VERSION="${VERSION:-unknown}"

# Fast path: already set up, at this version.
if [ -x "$ROOT/libexec/audio-watch" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$VERSION" ]; then
  exit 0
fi

# A version we have not set up yet: drop the old checker so it is fetched again.
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$VERSION" ]; then
  rm -f "$ROOT/libexec/audio-watch"
fi

mkdir -p "$DATA/audio" "$DATA/state" "$ROOT/libexec" 2>/dev/null

[ -f "$DATA/config.env" ] || cp "$ROOT/config.example.env" "$DATA/config.env" 2>/dev/null

# Put the command on PATH for the human, without clobbering another install.
if [ ! -e "$HOME/.local/bin/agent-tunes" ]; then
  mkdir -p "$HOME/.local/bin" 2>/dev/null
  ln -sfn "$ROOT/bin/agent-tunes" "$HOME/.local/bin/agent-tunes" 2>/dev/null
fi

# Wire up omp too, if it is installed.
if [ -d "$HOME/.omp/agent" ] && [ ! -e "$HOME/.omp/agent/extensions/agent-tunes.ts" ]; then
  mkdir -p "$HOME/.omp/agent/extensions" 2>/dev/null
  ln -sfn "$ROOT/omp/agent-tunes.ts" "$HOME/.omp/agent/extensions/agent-tunes.ts" 2>/dev/null
fi

# Fetch or build the audio checker in the background, then record that we are done.
if [ ! -x "$ROOT/libexec/audio-watch" ]; then
  nohup bash -c '
    root="$1"; stamp="$2"; url="$3"
    if curl -fsSL --max-time 120 "$url" -o "$root/libexec/audio-watch" 2>/dev/null; then
      chmod +x "$root/libexec/audio-watch"
      "$root/libexec/audio-watch" --once >/dev/null 2>&1
      [ $? -le 3 ] || rm -f "$root/libexec/audio-watch"
    fi
    if [ ! -x "$root/libexec/audio-watch" ] && command -v swiftc >/dev/null; then
      swiftc -O -o "$root/libexec/audio-watch" "$root/src/audio-watch.swift" >/dev/null 2>&1
    fi
    printf '%s' "$4" >"$stamp"
  ' _ "$ROOT" "$STAMP" "$RELEASE" "$VERSION" >/dev/null 2>&1 &
else
  printf '%s' "$VERSION" >"$STAMP"
fi

# Say something only when the user has to act. SessionStart output becomes
# context for the model, so keep it short and only when it earns its place.
NOTES=""
command -v mpv >/dev/null || NOTES="agent-tunes needs mpv to play anything: brew install mpv."
if [ -z "$(find "$DATA/audio" -maxdepth 1 -type f 2>/dev/null | head -1)" ]; then
  NOTES="$NOTES agent-tunes has no music yet: run 'agent-tunes download <url>' with any link yt-dlp handles, or drop a file into $DATA/audio."
fi

[ -n "$NOTES" ] && printf 'agent-tunes was installed.%s\n' "$NOTES"
exit 0
