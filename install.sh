#!/usr/bin/env bash
# Sets up agent-tunes. Safe to run again at any time: every step checks whether
# it is already done.
#
#   curl -fsSL https://raw.githubusercontent.com/midzdotdev/agent-tunes/main/install.sh | bash
#
# Piped through a shell like that, this clones the repo first and re-runs itself
# from the clone. From inside a clone it just does the work.
set -uo pipefail

REPO="https://github.com/midzdotdev/agent-tunes.git"
RELEASE="https://github.com/midzdotdev/agent-tunes/releases/latest/download/audio-watch"
DATA="${AGENT_TUNES_HOME:-$HOME/.agent-tunes}"
BINDIR="$HOME/.local/bin"

say()  { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
warn() { printf '  !  %s\n' "$*"; }
ask()  { # ask <prompt> <variable>; leaves the variable empty when there is no terminal
  printf '  %s' "$1"
  # stderr is redirected before stdin, so a missing /dev/tty fails quietly.
  if read -r "$2" 2>/dev/null </dev/tty; then :; else eval "$2="; printf '\n'; fi
}

if [ "$(uname -s)" != "Darwin" ]; then
  echo "agent-tunes only runs on macOS. It uses CoreAudio to tell whether"
  echo "something else is playing, and there is no port for other systems yet."
  exit 1
fi

# ---------------------------------------------------------------- bootstrap --
SELF="${BASH_SOURCE[0]:-}"
ROOT=""
[ -n "$SELF" ] && [ -f "$SELF" ] && ROOT="$(cd -- "$(dirname -- "$SELF")" && pwd -P)"

if [ -z "$ROOT" ] || [ ! -f "$ROOT/src/audio-watch.swift" ]; then
  DEST="${AGENT_TUNES_DIR:-$HOME/agent-tunes}"
  step "Fetching agent-tunes"
  if [ -d "$DEST/.git" ]; then
    git -C "$DEST" pull --ff-only --quiet && say "updated $DEST"
  else
    command -v git >/dev/null || { echo "git is required"; exit 1; }
    git clone --depth 1 --quiet "$REPO" "$DEST" || { echo "Could not clone into $DEST"; exit 1; }
    say "cloned into $DEST"
  fi
  exec bash "$DEST/install.sh" "$@"
fi

# ------------------------------------------------------------------- tools ---
step "Checking what you already have"
MISSING=""
command -v mpv    >/dev/null && say "found mpv"    || { say "missing mpv";    MISSING="$MISSING mpv"; }
command -v yt-dlp >/dev/null && say "found yt-dlp" || { say "missing yt-dlp"; MISSING="$MISSING yt-dlp"; }
command -v ffmpeg >/dev/null && say "found ffmpeg" || { say "missing ffmpeg"; MISSING="$MISSING ffmpeg"; }

if [ -n "$MISSING" ]; then
  if command -v brew >/dev/null; then
    ask "Install$MISSING with Homebrew? [Y/n] " reply
    case "${reply:-y}" in
      [Nn]*) warn "Skipped. agent-tunes needs mpv to play anything: brew install$MISSING" ;;
      *)     brew install $MISSING || warn "Homebrew failed. Try: brew install$MISSING" ;;
    esac
  else
    warn "Homebrew is not installed. Install these yourself, then run this again:"
    warn " $MISSING"
  fi
fi

# ------------------------------------------------------------ audio checker --
step "Getting the audio checker"
mkdir -p "$ROOT/libexec"
usable() { [ -x "$1" ] && { "$1" --once >/dev/null 2>&1; [ $? -le 3 ]; }; }

if usable "$ROOT/libexec/audio-watch"; then
  say "already present"
elif curl -fsSL --max-time 60 "$RELEASE" -o "$ROOT/libexec/audio-watch" 2>/dev/null \
     && chmod +x "$ROOT/libexec/audio-watch" && usable "$ROOT/libexec/audio-watch"; then
  say "downloaded the prebuilt binary"
elif command -v swiftc >/dev/null; then
  rm -f "$ROOT/libexec/audio-watch"
  if swiftc -O -o "$ROOT/libexec/audio-watch" "$ROOT/src/audio-watch.swift" 2>/dev/null; then
    say "built it from source"
  else
    warn "Build failed. Falling back to macOS power assertions, which are less"
    warn "precise about which app is playing but still work."
  fi
else
  rm -f "$ROOT/libexec/audio-watch"
  warn "Could not download or build it, so agent-tunes will use macOS power"
  warn "assertions instead. Less precise, still works."
fi

# ---------------------------------------------------------------- settings ---
step "Setting up your data directory"
mkdir -p "$DATA/audio" "$DATA/state"
say "$DATA"
if [ -f "$DATA/config.env" ]; then
  say "config.env already exists, leaving it alone"
else
  cp "$ROOT/config.example.env" "$DATA/config.env"
  say "copied config.example.env to $DATA/config.env"
fi
: >"$DATA/.setup-done"

# ----------------------------------------------------------------- linking ---
step "Linking"
mkdir -p "$BINDIR"
ln -sfn "$ROOT/bin/agent-tunes" "$BINDIR/agent-tunes"
say "$BINDIR/agent-tunes"
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *) warn "$BINDIR is not on your PATH. Add this to your shell profile:"
     warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ------------------------------------------------------------------ agents ---
step "Wiring up your agents"
if command -v claude >/dev/null; then
  claude plugin marketplace add "$ROOT" >/dev/null 2>&1 \
    || claude plugin marketplace update agent-tunes >/dev/null 2>&1
  claude plugin install agent-tunes@agent-tunes >/dev/null 2>&1
  say "Claude Code plugin installed, no restart needed"
else
  say "Claude Code not found, skipping"
fi

if [ -d "$HOME/.omp/agent" ]; then
  mkdir -p "$HOME/.omp/agent/extensions"
  ln -sfn "$ROOT/omp/agent-tunes.ts" "$HOME/.omp/agent/extensions/agent-tunes.ts"
  say "omp extension linked"
else
  say "omp not found, skipping"
fi

# ------------------------------------------------------------------ a track --
step "Choosing something to play"
if [ -n "$("$ROOT/bin/agent-tunes" status | sed -n 's/^  track *: //p' | grep -v '^none')" ]; then
  say "you already have a track"
else
  say "Paste a link and it will be downloaded now. Anything yt-dlp handles works."
  say "Leave it blank to skip and add one later. Use music you may play."
  ask "link: " url
  if [ -n "${url:-}" ]; then
    "$ROOT/bin/agent-tunes" download "$url" >/dev/null 2>&1 \
      && say "downloaded" \
      || warn "Download failed. Try again later with: agent-tunes download <url>"
  else
    say "skipped"
  fi
fi

step "Turning it on"
"$ROOT/bin/agent-tunes" on >/dev/null
say "enabled"

printf '\n%s\n' "Done. Check it over with: agent-tunes doctor"
printf '%s\n'   "Turn it off any time with: agent-tunes off"
