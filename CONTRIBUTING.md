# Contributing

## How it works

Everything lives in one bash script, `bin/agent-tunes`. The Claude Code plugin
and the Pi extension are thin wrappers that call it, so the two cannot drift
apart.

| | Starts on | Stops on |
| --- | --- | --- |
| Claude Code | `UserPromptSubmit`, `PreToolUse` | `Stop`, `SessionEnd` |
| Pi | `agent_start` | `agent_end`, `session_shutdown` |

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

**Why notification sounds are ignored by name.** `IsRunningOutput` is sticky. A
half-second chime from `systemsoundserverd` was measured still reading as
"playing" 10.35 s later, which no time threshold can separate from someone
starting a call. Hence `TUNES_IGNORE_PROCESSES` rather than a longer
`TUNES_YIELD_SUSTAIN`.

**Why mpv and not ffplay.** ffplay cannot change its volume once it has started,
so it cannot fade out of a stop it did not see coming. mpv exposes a JSON IPC
socket, so `libexec/mpv-fade` ramps the volume down and quits at the bottom of
the ramp. The fade in runs the same code in reverse.

## Rebuilding the audio checker

```bash
agent-tunes build       # compiles src/audio-watch.swift into libexec/
```

Releases ship it prebuilt as a universal binary, so nobody installing it needs a
Swift toolchain.

## Tests

```bash
tests/unit.sh            # silent, stubs, ~30s
tests/integration.sh     # silent, real mpv and real fade
tests/docker.sh          # both of the above, on Linux
tests/audible.sh --yes   # plays out loud, macOS only
```

Three tiers, and only the last one makes a sound.

`tests/unit.sh` replaces every external command with a stub from `tests/stubs`,
so it covers the switch, the start delay, multi-agent counting, yielding, random
positions and cleanup without touching audio at all. It runs against a throwaway
data directory, so a real agent session on the same machine cannot skew the
counts. That matters more than it sounds: getting out of the way of other audio
is the whole point, so a suite that listens to real speakers fails whenever
somebody uses the machine.

`tests/integration.sh` runs the real mpv and the real volume ramp, using mpv's
null audio output. It opens no audio device, so it makes no sound and does not
register as an audio client, while still exercising the IPC socket, the ramp,
quitting at the bottom of it, and seeking to the chosen position.

`tests/docker.sh` runs both on Linux, which also shows the orchestration has no
hidden dependency on macOS.

`tests/audible.sh` holds only what cannot be faked: the CoreAudio checker
against real audio clients, and yielding to a real second player. It refuses to
run without `--yes`, and puts the on/off setting back afterwards.

Most of it can be silenced with a virtual audio device, which is real output as
far as CoreAudio is concerned but inaudible:

```bash
brew install blackhole-2ch
tests/audible.sh --yes --device 'coreaudio/BlackHole2ch'
```

`mpv --audio-device=help` lists what a machine has. System alert sounds still go
to the default device, so the notification case stays audible either way.

## The command seams

`bin/agent-tunes` reads `TUNES_PLAYER`, `TUNES_FADER`, `TUNES_WATCHER` and
`TUNES_FFPROBE`, defaulting to the real commands. They exist so the tests can
substitute stubs. Nothing but the tests should set them.

## Releasing

Bump the version in `package.json`, `.claude-plugin/plugin.json` and
`.claude-plugin/marketplace.json`, then:

```bash
swiftc -O -target arm64-apple-macos14.4  -o /tmp/aw-a src/audio-watch.swift
swiftc -O -target x86_64-apple-macos14.4 -o /tmp/aw-x  src/audio-watch.swift
lipo -create -output /tmp/audio-watch /tmp/aw-a /tmp/aw-x
gh release create vX.Y.Z /tmp/audio-watch
```

The asset must be named exactly `audio-watch`. Setup fetches it from
`releases/latest/download/audio-watch`, and a release without it makes that URL
404 for everyone. Verify with a plain GET afterwards, not a HEAD, and give the
CDN a moment: it has served both a stale copy and a 404 immediately after a
publish.

Setup re-fetches the binary whenever the version changes, so the version bump is
what pushes it out to existing installs.
