<div align="center">

# 🎧 agent-tunes

**Music while your coding agent works. Silence when it doesn't.**

[![macOS](https://img.shields.io/badge/macOS-14.4%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-d97757)](https://claude.com/claude-code)
[![omp](https://img.shields.io/badge/omp-extension-6366f1)](https://omp.sh)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

Your agent starts working, music fades in from a random point in the track. It
finishes, the music fades out. Someone rings you on Teams, the music stops
instantly and gets out of the way.

It plays only when nothing else on your Mac is making a sound, so it never talks
over a call, a video, or whatever you already had on.

Works with [Claude Code](https://claude.com/claude-code) and
[omp](https://omp.sh), together or separately.

## Install

```bash
git clone https://github.com/midzdotdev/agent-tunes.git
cd agent-tunes
./install.sh
```

The installer checks for what it needs, offers to fetch anything missing through
Homebrew, compiles a small helper, and registers itself with whichever agents you
have. Run it again whenever you like; it skips whatever is already done.

Then give it something to play:

```bash
agent-tunes download "https://www.youtube.com/watch?v=..."
```

That accepts anything [yt-dlp](https://github.com/yt-dlp/yt-dlp) understands,
which is most audio and video sites plus plain file links. You can also drop a
file straight into `audio/`. Use music you have the right to play.

Restart Claude Code so it picks up the hooks, and you're done.

## Turning it off

```bash
agent-tunes toggle      # or: on, off
agent-tunes status
```

Both agents also have a `/tunes` command that takes the same words.

Nothing is left running when it's off. The switch is a file in `state/`, checked
before anything else happens.

## When it plays

Four things have to be true, or it stays quiet:

1. you have it switched on
2. an agent is actually working
3. it isn't already playing
4. nothing else on the Mac is playing audio

There's also a four second delay before the first note. A quick answer finishes
before any sound arrives, so short turns don't produce a two second blip of jazz.

Playback begins somewhere random in the track, never in the last five minutes of
it, and fades in. When the agent settles, it fades out.

### Getting out of the way

While music is playing, agent-tunes watches for anyone else starting audio. The
moment someone does, it stops, with no fade, because the point is to leave you
the speakers.

It knows the difference between an app that is playing and an app that merely has
audio open. Slack, Teams and an idle Safari all sit there holding audio sessions
without making a sound, and none of them count.

## Several agents at once

Two Claude Code windows, or Claude Code and omp together, share one player.

```
A starts work   ->  music starts
B starts work   ->  music keeps going
A finishes      ->  music keeps going, B is still busy
B finishes      ->  music fades out
```

Each session registers itself as a file in `state/active/` and removes it when it
finishes. The last one out stops the music. `agent-tunes status` shows who is
currently registered.

## Settings

Copy `config.example.env` to `config.env`, which the installer does for you. It's
read fresh on every invocation, so edits apply straight away.

| Setting | Default | What it does |
| --- | --- | --- |
| `TUNES_VOLUME` | `30` | Volume out of 100 |
| `TUNES_START_DELAY` | `4` | Seconds of work before the music starts |
| `TUNES_FADE_IN` | `4` | Fade in length |
| `TUNES_FADE_OUT` | `1.5` | Fade out length |
| `TUNES_MIN_TAIL` | `300` | Never start this close to the end of a track |
| `TUNES_RESPECT_OTHER_AUDIO` | `1` | Set to `0` to start even when something else is playing |
| `TUNES_YIELD_TO_OTHER_AUDIO` | `1` | Set to `0` to keep playing when another app starts |
| `TUNES_TRACK` | empty | A filename in `audio/`, or an absolute path. Empty picks the first file found |

## Other commands

```bash
agent-tunes play              # start now, without waiting for an agent
agent-tunes stop-all          # stop now and clear every session
agent-tunes doctor            # check the wiring
agent-tunes build             # rebuild the audio checker after editing src/
```

## How it works

Everything lives in one bash script. The Claude Code plugin and the omp extension
are thin wrappers that call it, so the two can't drift apart.

| | Starts on | Stops on |
| --- | --- | --- |
| Claude Code | `UserPromptSubmit`, `PreToolUse` | `Stop`, `SessionEnd` |
| omp | `agent_start` | `agent_end`, `session_shutdown` |

**Telling whether anything else is playing.** CoreAudio has had a process-object
API since macOS 14.4. Every audio client shows up as an object with a PID and an
`IsRunningOutput` flag, which gives an exact answer rather than a guess.
`libexec/audio-watch` reads it.

**Why it polls.** That API also publishes change notifications for the same two
properties, but on macOS 25.6 they arrive about 33 seconds after the event,
whether the process is new or already registered. That is no use when the job is
to get out of the way now, so `audio-watch` polls twice a second instead. A full
scan of every audio client takes 1.87 ms, which you can measure yourself with
`audio-watch --bench`, and it only runs while music is playing. Reaction time to
an app starting playback measured 0.07 s.

On anything older than macOS 14.4 it falls back to power assertions. `coreaudiod`
holds one per playing audio context, so `pmset` gives a workable yes or no.

**Why mpv and not ffplay.** ffplay can't change its volume once it has started,
so it can't fade out of a stop it didn't see coming. mpv exposes a JSON IPC
socket, so `libexec/mpv-fade` ramps the volume down and quits at the bottom of the
ramp. The fade in runs the same code in reverse.

## Tests

```bash
tests/suite.sh
```

23 checks over the switch, multi-agent counting, the fade ramp, yielding, start
suppression, random offsets and cleanup. It plays audio out loud and takes about
a minute.

## What you need

macOS 14.4 or later, plus `mpv`, `ffmpeg` and `yt-dlp`. The installer offers to
fetch these through Homebrew. Building the audio checker needs `swiftc` from the
Xcode command line tools (`xcode-select --install`); without it agent-tunes falls
back to power assertions and still works.

## Uninstall

```bash
claude plugin uninstall agent-tunes@agent-tunes
claude plugin marketplace remove agent-tunes
rm ~/.omp/agent/extensions/agent-tunes.ts ~/.local/bin/agent-tunes ~/.agent-tunes
```

Then delete the clone.

## Licence

MIT. See [LICENSE](LICENSE).
