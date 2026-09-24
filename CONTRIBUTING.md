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

**Why system sounds are ignored by name.** `IsRunningOutput` is sticky. A
half-second chime from `systemsoundserverd` was measured still reading as
"playing" 10.35 s later, which no time threshold can separate from someone
starting a call. Hence `TUNES_IGNORE_PROCESSES` rather than a longer
`TUNES_YIELD_SUSTAIN`.

Not every system sound comes from `systemsoundserverd`. The charger chime is
`PowerChime`, a separate app in `/System/Library/CoreServices`, and it stopped
the music until it was added. Matching is on the executable's basename.

The list lives in `bin/agent-tunes` and nowhere else. `audio-watch` ignores
nothing unless it is passed `--ignore-names`, so changing the list never means
rebuilding it. It used to carry a copy of its own, which had to be kept in step
by hand; a unit check now fails if a default list reappears in the Swift.

**What the log says, and why it names names.** A yield used to be logged as a
bare pid, which is meaningless by the time anyone reads it: finding out that the
charger chime was the culprit took a separate listener. `audio-watch` now prints
`BUSY <pid> <name>`, and on stderr `IGNORED <pid> <name>` each time a
name-ignored process starts producing output. The guard feeds that stderr into
the log as it arrives. Ignored processes are reported once per start rather than
per poll, and only while music is playing, since that is the only time one could
have stopped it.

**How tracks are managed.** `audio/` holds the files and nothing else. Whether a
track may play is a marker file in `state/disabled/`, named after it. Absence
means playable, so a file dropped into `audio/` by hand plays without having to
be registered anywhere, which is the behaviour the README promises. Markers whose
track has gone are swept at the top of every `tracks` command, so a name reused
later does not inherit the old one's setting.

Playback picks uniformly from the enabled set. `TUNES_PICK_INDEX` replaces that
choice with a fixed index into the sorted list, which is how the tests assert on
it without depending on a dice roll.

**Why mpv answers "can this be played".** mpv is the thing that will have to play
it, so its own answer is the one that counts, and asking it costs nothing extra:
one run with `--frames=1` reports both the duration and whether there is an audio
stream at all. That second part matters, because mpv opens a video with no
soundtrack quite happily and would then play silence. `--ao=null` means the probe
opens no audio device, so it makes no sound and does not register as an audio
client that our own guard would turn round and yield to.

It replaced ffprobe, which used to answer only the duration half and made ffmpeg
a dependency of playback rather than only of downloading. Measured against a
three hour file the probe takes 0.44s to ffprobe's 0.06s, which is paid once per
track and cached in `state/duration/`.

**Why mpv is required rather than preferred.** There was an ffplay fallback for
machines without mpv. It went when mpv took over reading durations as well: that
path could no longer find out how long a track was, so it would have started
every track at the top, and `tracks add` would have rejected every file. A
missing player is now reported by name, in the log and by `tracks add`, instead
of being half worked around.

**Why mpv and not ffplay.** ffplay cannot change its volume once it has started,
so it cannot fade out of a stop it did not see coming. mpv exposes a JSON IPC
socket, so `libexec/mpv-fade` ramps the volume down and quits at the bottom of
the ramp. The fade in runs the same code in reverse.

## Rebuilding the audio checker

```bash
agent-tunes build       # compiles src/audio-watch.swift into libexec/
```

Releases ship it prebuilt as a universal binary, so nobody installing it needs a
Swift toolchain. Only a change to `src/audio-watch.swift` needs a rebuild; the
ignore list is passed in at runtime.

## Tests

```bash
tests/unit.sh            # silent, stubs, ~60s
tests/integration.sh     # silent, real mpv and real fade
tests/docker.sh          # both of the above, on Linux
tests/audible.sh --yes   # plays out loud, macOS only
```

Three tiers, and only the last one makes a sound.

`tests/unit.sh` replaces every external command with a stub from `tests/stubs`,
so it covers the switch, the start delay, multi-agent counting, yielding, random
positions, track management and cleanup without touching audio at all. It runs against a throwaway
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
run without `--yes`.

It looks after itself in three ways, all of which were learned the hard way. It
generates its own tone in its own data directory rather than using your music.
It switches off whatever is driving `~/.agent-tunes` for the duration, because a
live agent session's hooks start and stop playback on their own schedule and may
be running a different released version against the same state. And it refuses
outright when something else already has the speakers, naming the process:
every check here either asserts the machine is idle or needs playback to start,
which agent-tunes rightly declines while somebody else is playing, so a busy
machine produces a page of failures that look like a broken build. Everything it
changes is put back on the way out, including after that refusal.

Most of it can be silenced with a virtual audio device, which is real output as
far as CoreAudio is concerned but inaudible:

```bash
brew install blackhole-2ch
tests/audible.sh --yes --device 'coreaudio/BlackHole2ch'
```

`mpv --audio-device=help` lists what a machine has. System alert sounds still go
to the default device, so the notification case stays audible either way.

## The command seams

`bin/agent-tunes` reads `TUNES_PLAYER`, `TUNES_FADER` and `TUNES_WATCHER`,
defaulting to the real commands, so the tests can substitute stubs.
`TUNES_PICK_INDEX` is a seam of a different kind: it fixes the random track
choice rather than replacing a command. Nothing but the tests should set any of
them.

**Why ROOT walks the symlink chain.** Setup puts `~/.local/bin/agent-tunes` on
PATH as a link into the checkout. Taking `dirname` of the link gives `~/.local`,
which has no `libexec/`, so `audio-watch` and `mpv-fade` were both missing on
every PATH invocation. Neither is fatal on its own, which is why it went
unnoticed: the code simply skips the fade and gives up on yielding when they are
not executable. `readlink` is used without `-f`, because BSD only grew that flag
recently.

**Why registrations expire.** `state/active/` is the multi-agent count, and a
harness killed outright never fires its stop hook. Its file used to pin the
count above zero for ever. Two things now clear it: `reap_sessions` drops
anything older than `TUNES_SESSION_TTL`, and each player carries a watchdog that
stops it once nothing is registered. The watchdog is not redundant, because the
reaper only runs when some agent-tunes command runs, and the case it exists for
is the one where nothing ever runs again. `TUNES_WATCHDOG_INTERVAL` shortens its
poll for the tests.

**Track names are data, never code.** `doctor` runs each check as a command
rather than building a string and evaluating it, because a check that mentioned
a track interpolated the filename into shell source: a file called
`mix $(...).m4a` ran whatever it held the moment anyone ran `doctor`. For the
same reason `find_track` refuses anything containing a slash, which otherwise
resolved outside `audio/` and let `tracks remove` delete an unrelated file while
the prompt showed only its basename. Both have tests.

The mpv stub answers a probe from the filename it is given: one containing
`noaudio` reports a file with no sound in it, one containing `unplayable` reports
a file mpv cannot open, and anything else is a fixed hour of audio.

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
