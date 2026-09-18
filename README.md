<div align="center">

# 🎧 agent-tunes

**Music while your coding agent works. Silence when it doesn't.**

[![macOS](https://img.shields.io/badge/macOS-14.4%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-d97757)](https://claude.com/claude-code)
[![Pi](https://img.shields.io/badge/Pi-extension-6366f1)](https://github.com/earendil-works/pi)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

Your agent starts working, music fades in from a random point in the track. It
finishes, the music fades out. Someone rings you on Teams, the music stops
instantly and gets out of the way.

It plays only when nothing else on your Mac is making a sound, so it never talks
over a call, a video, or whatever you already had on.

Works with [Claude Code](https://claude.com/claude-code) and
[Pi](https://github.com/earendil-works/pi), together or separately.

## Install

If you use Claude Code, two commands and you're done:

```bash
claude plugin marketplace add midzdotdev/agent-tunes
claude plugin install agent-tunes@agent-tunes
```

The plugin finishes setting itself up on the next session start, and Claude Code
picks it up without a restart. It will tell you if it needs anything, which on a
machine without [mpv](https://mpv.io) means `brew install mpv`.

For Pi, or if you would rather see what you're running first:

```bash
curl -fsSL https://raw.githubusercontent.com/midzdotdev/agent-tunes/main/install.sh | bash
```

That clones the repo, fetches what it needs, wires up whichever agents you have,
and offers to download your first track while you're there. Cloning and running
`./install.sh` yourself does exactly the same thing. Either way it's safe to run
again later.

Then give it something to play, if you skipped that during setup:

```bash
agent-tunes tracks add "https://www.youtube.com/watch?v=..."
```

That takes anything [yt-dlp](https://github.com/yt-dlp/yt-dlp) understands, which
covers most audio and video sites plus plain file links. A path works just as
well, and so does dropping a file into `~/.agent-tunes/audio/` yourself. Use
music you have the right to play.

The repo is also a Pi package, so `pi install <url>` wires up the extension on
its own. That covers the extension and nothing else, with no mpv, no audio
checker, no command and no music, so the setup script above is still the way in.

## Turning it off

```bash
agent-tunes toggle      # or: on, off
agent-tunes status
```

Both agents also have a `/tunes` command that takes the same words, plus
`/tunes tracks` to list what you have. Adding, removing and enabling are left
out of it on purpose: they change your own music files, so they stay at a
terminal.

Nothing is left running when it's off. The switch is a file in `~/.agent-tunes/state/`, checked
before anything else happens.

## When it plays

Five things have to be true, or it stays quiet:

1. you have it switched on
2. an agent is actually working
3. at least one of your tracks is enabled
4. it isn't already playing
5. nothing else on the Mac is playing audio

There's also a four second delay before the first note. A quick answer finishes
before any sound arrives, so short turns don't produce a two second blip of jazz.

It picks one of your enabled tracks at random, begins somewhere random inside
it, and fades in. When the agent settles, it fades out.

The starting point leaves a tail, so a turn does not run into silence a few
seconds later. That tail is `TUNES_MIN_TAIL`, five minutes by default, shortened
to half the track on anything too short to give five minutes away.

### Getting out of the way

While music is playing, agent-tunes watches for anyone else starting audio. The
moment someone does, it stops, with no fade, because the point is to leave you
the speakers.

It knows the difference between an app that is playing and an app that merely has
audio open. Slack, Teams and an idle Safari all sit there holding audio sessions
without making a sound, and none of them count.

Notification chimes and system alerts do not count either. `TUNES_IGNORE_PROCESSES`
controls which processes are ignored, and `systemsoundserverd` is on that list by
default.

Anything else has to keep playing for `TUNES_YIELD_SUSTAIN` seconds before the
music gets out of its way, which filters brief noises from short-lived processes.

## Several agents at once

Two Claude Code windows, or Claude Code and Pi together, share one player.

```
A starts work   ->  music starts
B starts work   ->  music keeps going
A finishes      ->  music keeps going, B is still busy
B finishes      ->  music fades out
```

Each session registers itself as a file in `~/.agent-tunes/state/active/`, removing it when it
finishes. The last one out stops the music. `agent-tunes status` shows who is
currently registered.

An agent that is killed outright never gets to remove its file. Every session
refreshes its own registration as it works, so one that has not checked in for
`TUNES_SESSION_TTL` is treated as gone, and the music stops when the last real
one does.

## Settings

Settings live in `~/.agent-tunes/config.env`, which setup creates from
`config.example.env`. It's read fresh on every invocation, so edits apply
straight away.

Your music, settings and state all live in `~/.agent-tunes`, well away from the
installed code, so upgrading never touches them.

| Setting | Default | What it does |
| --- | --- | --- |
| `TUNES_VOLUME` | `30` | Volume out of 100 |
| `TUNES_START_DELAY` | `4` | Seconds of work before the music starts |
| `TUNES_FADE_IN` | `4` | Fade in length |
| `TUNES_FADE_OUT` | `1.5` | Fade out length |
| `TUNES_MIN_TAIL` | `300` | Never start this close to the end of a track, halved down to fit a short one |
| `TUNES_RESPECT_OTHER_AUDIO` | `1` | Set to `0` to start even when something else is playing |
| `TUNES_YIELD_TO_OTHER_AUDIO` | `1` | Set to `0` to keep playing when another app starts |
| `TUNES_YIELD_SUSTAIN` | `1` | Seconds another app must keep playing before yielding |
| `TUNES_IGNORE_PROCESSES` | `systemsoundserverd` | Executables that never count, whatever they play |
| `TUNES_SESSION_TTL` | `1800` | Forget a session that has not checked in for this many seconds |
| `TUNES_EXTS` | `m4a mp3 opus webm wav flac` | File suffixes that count as a track |

## Your tracks

Everything lives in `~/.agent-tunes/audio/`, and every track in there may play
unless you say otherwise.

```bash
agent-tunes tracks                        what you have, and what may play
agent-tunes tracks add <path|url>         copy a file in, or fetch one with yt-dlp
agent-tunes tracks remove <name>          delete it, after asking
agent-tunes tracks enable  <name|--all>   let it play
agent-tunes tracks disable <name|--all>   keep it, but never play it
agent-tunes tracks dir                    print where the music is kept
```

```
$ agent-tunes tracks
/Users/you/.agent-tunes/audio

  elevator-jazz.m4a                            3:05:21
  late-night-lofi.m4a                            48:12
  drum-and-bass.m4a                              42:30   disabled

  3 tracks, 2 enabled
```

`<name>` is a filename, or any part of one that matches only a single track, so
`agent-tunes tracks disable lofi` is enough. Adding a file checks that mpv can
actually play it and that there is sound in it, so a video with a silent
soundtrack is turned away rather than quietly playing nothing.

Disabling keeps the file and leaves it out of the shuffle. `--all` covers every
track at once, and disabling the last one tells you nothing will play.

## Other commands

```bash
agent-tunes play              # start now, without waiting for an agent
agent-tunes stop --all        # stop now and clear every session
agent-tunes doctor            # check the wiring
```

## What you need

macOS 14.4 or later and [mpv](https://mpv.io), which plays the audio and is also
what checks a new track before it is added. `ffmpeg` and `yt-dlp` are only needed
by `agent-tunes tracks add` with a URL. Setup offers to fetch all three through
Homebrew.

You do not need Xcode or any developer tools. Setup downloads `audio-watch`
prebuilt as a universal binary covering both Apple silicon and Intel. It links
only against libraries macOS already ships, including the Swift runtime in
`/usr/lib/swift`, so it runs on a stock Mac.

If that download fails, say because you're offline, setup compiles it instead
where a Swift toolchain is present, and otherwise falls back to macOS power
assertions.

## Uninstall

```bash
agent-tunes off
claude plugin uninstall agent-tunes@agent-tunes
claude plugin marketplace remove agent-tunes
rm -f ~/.pi/agent/extensions/agent-tunes.ts ~/.omp/agent/extensions/agent-tunes.ts \
      ~/.local/bin/agent-tunes
```

Then delete `~/.agent-tunes` for your music and settings, and the clone if you
made one.

## Licence

MIT. See [LICENSE](LICENSE). To work on it, see [CONTRIBUTING.md](CONTRIBUTING.md).
