#!/usr/bin/env bash
# Sets up agent-tunes from a clone of this repo. Safe to run again at any time:
# every step checks whether it is already done.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LINK="$HOME/.agent-tunes"
BINDIR="$HOME/.local/bin"

say()  { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
warn() { printf '  !  %s\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "agent-tunes only runs on macOS. It uses CoreAudio to tell whether"
  echo "something else is playing, and there is no port for other systems yet."
  exit 1
fi

step "Checking what you already have"
MISSING=""
for tool in mpv ffprobe yt-dlp; do
  if command -v "$tool" >/dev/null; then
    say "found $tool"
  else
    say "missing $tool"
    case "$tool" in
      ffprobe) MISSING="$MISSING ffmpeg" ;;
      *)       MISSING="$MISSING $tool" ;;
    esac
  fi
done

if [ -n "$MISSING" ]; then
  if command -v brew >/dev/null; then
    printf '\n  Install%s with Homebrew now? [Y/n] ' "$MISSING"
    read -r reply </dev/tty || reply="n"
    case "$reply" in
      [Nn]*) echo "  Skipped. Run: brew install$MISSING"; ;;
      *)     brew install $MISSING || { warn "Homebrew failed. Run: brew install$MISSING"; exit 1; } ;;
    esac
  else
    warn "Homebrew is not installed. Install these yourself, then run this again:"
    warn "  $MISSING"
    exit 1
  fi
fi

step "Building the audio checker"
if command -v swiftc >/dev/null; then
  mkdir -p "$ROOT/libexec"
  if swiftc -O -o "$ROOT/libexec/audio-watch" "$ROOT/src/audio-watch.swift"; then
    say "built libexec/audio-watch"
  else
    warn "Build failed. agent-tunes will fall back to macOS power assertions,"
    warn "which are less precise but still work."
  fi
else
  warn "swiftc not found, so the precise audio check is unavailable."
  warn "Install the Xcode command line tools with: xcode-select --install"
  warn "agent-tunes falls back to macOS power assertions until then."
fi

step "Creating your settings file"
if [ -f "$ROOT/config.env" ]; then
  say "config.env already exists, leaving it alone"
else
  cp "$ROOT/config.example.env" "$ROOT/config.env"
  say "copied config.example.env to config.env"
fi

step "Linking"
ln -sfn "$ROOT" "$LINK"
say "$LINK -> $ROOT"

mkdir -p "$BINDIR"
ln -sfn "$ROOT/bin/agent-tunes" "$BINDIR/agent-tunes"
say "$BINDIR/agent-tunes"
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *) warn "$BINDIR is not on your PATH. Add this to your shell profile:"
     warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

step "Wiring up Claude Code"
if command -v claude >/dev/null; then
  claude plugin marketplace add "$ROOT" >/dev/null 2>&1 \
    || claude plugin marketplace update agent-tunes >/dev/null 2>&1
  if claude plugin install agent-tunes@agent-tunes >/dev/null 2>&1; then
    say "installed the agent-tunes plugin"
  else
    say "plugin already installed"
  fi
  say "restart Claude Code to load the hooks"
else
  say "Claude Code not found, skipping"
fi

step "Wiring up omp"
if [ -d "$HOME/.omp/agent" ]; then
  mkdir -p "$HOME/.omp/agent/extensions"
  ln -sfn "$ROOT/omp/agent-tunes.ts" "$HOME/.omp/agent/extensions/agent-tunes.ts"
  say "linked the omp extension"
else
  say "omp not found, skipping"
fi

step "Turning it on"
"$ROOT/bin/agent-tunes" on >/dev/null
say "enabled"

printf '\n%s\n' "Almost there. One thing left: give it something to play."
printf '%s\n' "  agent-tunes download <url>     any link yt-dlp understands"
printf '%s\n' "  cp yourtrack.m4a $ROOT/audio/"
printf '\n%s\n' "Then check everything with: agent-tunes doctor"
