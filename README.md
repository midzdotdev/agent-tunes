# agent-tunes

Background music while a coding agent works. One implementation, two front-ends:
a **Claude Code plugin** and an **omp extension**. Both are thin shims that shell
out to `bin/agent-tunes`, so the behaviour lives in exactly one place.

## The switch

```bash
agent-tunes on          # or: off, toggle
agent-tunes status
```

`agent-tunes` is on `PATH` via `~/.local/bin/agent-tunes`. Inside omp there is
also `/tunes on|off|toggle|status`, and inside Claude Code `/tunes`.

## What it does

On every turn, the agent's hooks call `agent-tunes start`. That does **not** play
anything immediately — it marks the session as working and schedules a check
`TUNES_START_DELAY` seconds later. At that point audio starts only if all of:

1. `agent-tunes` is enabled,
2. a session is still working,
3. nothing of ours is already playing,
4. **nothing else on the machine is playing audio.**

The start delay means a short turn finishes before any sound is made — no
two-second blips of jazz for a one-line answer.

Playback starts at a **random position** in the track (never within
`TUNES_MIN_TAIL` seconds of the end), fades in over `TUNES_FADE_IN`, and fades
out over `TUNES_FADE_OUT` when the last active agent session finishes.

## Multiple agents

Concurrent agents are reference-counted. `start` registers a session by touching
`state/active/k-<session>`; `stop` removes that one file and only stops the music
if the directory is then empty. So:

```
A starts  -> registers, music starts
B starts  -> registers, music continues
A stops   -> deregisters, music continues (B is still working)
B stops   -> deregisters, directory empty, music fades out
```

A directory of one file per agent rather than a single shared list, because
create and remove are then atomic — no read-modify-write, so two agents starting
or stopping at the same instant cannot lose each other's entry.

The session key comes from the `session_id` in the JSON that Claude Code pipes to
its hooks, and from `--key omp-<pid>` for omp. `agent-tunes status` lists who is
currently registered. Nested omp subagents share a process, so the extension
reference-counts them in memory and only signals `stop` when the outermost one
finishes.

Deliberately, the launcher decides what to do from the registered set *at the
moment it wakes*, not from which agent asked. An earlier version tagged each
request with a token and had the launcher abort on a mismatch; that dropped the
music entirely when one agent's request landed while another's launcher was
still in its start delay.

## Getting out of the way

While the music plays, `libexec/audio-watch` guards it. The moment any other
process starts producing audio — a call, a video, Spotify — the music **stops
at once, with no fade**, because the point is to get out of the way.

Rule 4 above and that guard share one source of truth: CoreAudio's process-object
API (macOS 14.4+). Every audio client is an `AudioObject` carrying a PID and an
`IsRunningOutput` flag, so the answer is exact — an app merely holding an audio
session open reports false. Measured on this machine, Slack, Teams and an idle
Safari all report false while a playing `mpv` reports true.

### Why it polls

CoreAudio publishes change notifications for both the process list and the
running-output flag, and an earlier version of `audio-watch` used them instead
of polling. Measured on macOS 25.6 those notifications arrived **~33 seconds**
after the event — the same for a newly spawned process and for one already
registered. That is useless for "get out of the way now", so the listeners were
dropped.

What replaced them is one long-lived process polling twice a second. A full scan
of every audio client costs **1.87 ms** (`audio-watch --bench`), so the guard
costs roughly 0.4% of one core while music is playing and nothing at all when it
is not. Measured worst-case reaction time is the poll interval; observed
reaction to an already-running app starting playback was 0.07 s.

There is a cheaper fallback if the API is ever unavailable: `coreaudiod` holds
one `PreventUserIdleSystemSleep` power assertion per playing audio context, so
`pmset -g assertions` gives a usable yes/no. It is only used if `audio-watch`
reports the API missing.

## Why mpv rather than ffplay

ffplay cannot change volume once it has started, so it cannot fade out on a stop
it did not know was coming. mpv exposes a JSON IPC socket, so `libexec/mpv-fade`
ramps the volume down and quits at the bottom of the ramp. The fade-in uses the
same mechanism in reverse rather than a second, filter-based one. ffplay remains
a fallback if mpv is not installed — with no fade-out.

## Layout

Everything lives here; the two agents reach it by symlink.

```
~/agent-tunes/
├── bin/agent-tunes            all behaviour
├── config.env                 settings, sourced live
├── audio/                     tracks (first one found is used)
├── state/                     enabled flag, pidfile, mpv socket, active sessions, log
├── src/audio-watch.swift      source for the CoreAudio checker
├── libexec/
│   ├── audio-watch            compiled checker (agent-tunes build)
│   └── mpv-fade               volume ramp over mpv's IPC socket
├── claude/                    a local Claude Code marketplace
│   ├── .claude-plugin/marketplace.json
│   └── plugins/agent-tunes/   plugin.json, hooks/hooks.json, commands/tunes.md
└── omp/agent-tunes.ts         omp extension
```

Symlinks pointing at this directory:

| Link | Target |
|---|---|
| `~/.local/bin/agent-tunes` | `bin/agent-tunes` |
| `~/.omp/agent/extensions/agent-tunes.ts` | `omp/agent-tunes.ts` |
| `~/.claude/plugins/cache/agent-tunes/agent-tunes/1.0.0` | `claude/plugins/agent-tunes` |

The third one matters: `claude plugin install` **copies** a local plugin into its
cache, so the copy was replaced with a symlink. Edits to `hooks.json` are
therefore live, needing only a Claude Code restart rather than a reinstall.

`~/.claude/settings.json` holds the marketplace entry and the enabled flag.

## Hook wiring

| Agent | Start | Stop |
|---|---|---|
| Claude Code | `UserPromptSubmit`, `PreToolUse` | `Stop`, `SessionEnd` |
| omp | `agent_start` | `agent_end`, `session_shutdown` |

The omp extension reference-counts nested agents in-process, so a subagent
finishing does not stop the music while the main agent is still working.

## Settings

Edit `config.env` — it is sourced on every invocation, so changes are live.

| Setting | Default | Meaning |
|---|---|---|
| `TUNES_VOLUME` | `30` | player volume, 0-100 |
| `TUNES_START_DELAY` | `4` | seconds of continuous work before audio starts |
| `TUNES_FADE_IN` | `4` | fade-in length in seconds |
| `TUNES_FADE_OUT` | `1.5` | fade-out length when a turn ends |
| `TUNES_MIN_TAIL` | `300` | never start within this many seconds of the end |
| `TUNES_RESPECT_OTHER_AUDIO` | `1` | `0` starts even when something else is playing |
| `TUNES_YIELD_TO_OTHER_AUDIO` | `1` | `0` keeps playing when another process starts audio |
| `TUNES_TRACK` | `""` | filename in `audio/`, or an absolute path |

## Other commands

```bash
agent-tunes play              # start now, ignoring the work tracking
agent-tunes stop-all          # stop now and clear all sessions
agent-tunes doctor            # check the wiring
agent-tunes build             # recompile audio-watch after editing src/
agent-tunes download <url>    # add another track with yt-dlp
```

## From a fresh clone

`audio/` and the compiled `libexec/audio-watch` are not in the repo, so:

```bash
agent-tunes build                    # compile the CoreAudio checker
agent-tunes download <url>           # fetch a track of your own
agent-tunes doctor                   # confirm the wiring
agent-tunes on
```

## Tests

```bash
tests/suite.sh
```

23 checks covering the switch, multi-agent reference counting, the fade-out
ramp, yielding to other audio, start suppression, random offsets and cleanup.
It plays audio out loud and takes about a minute.

## Requirements

`mpv` (`brew install mpv`), `ffprobe` (`brew install ffmpeg`), `yt-dlp` for
downloading, and `swiftc` from the Xcode command line tools to build
`audio-watch`. macOS 14.4 or later for the audio check; older versions fall back
to power assertions.

## Uninstall

```bash
claude plugin uninstall agent-tunes@agent-tunes
claude plugin marketplace remove agent-tunes
rm ~/.omp/agent/extensions/agent-tunes.ts ~/.local/bin/agent-tunes
```
