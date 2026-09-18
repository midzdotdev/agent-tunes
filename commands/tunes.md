---
description: Turn agent-tunes background music on or off, or show its status
allowed-tools: Bash(agent-tunes:*)
---

Run `agent-tunes` with the argument the user asked for:

- no argument, or "status" → `status`
- "on" / "off" / "toggle" → that subcommand
- "play" → `play`
- "stop" → `stop --all`
- "tracks" → `tracks list`

Never run `tracks add`, `tracks remove`, `tracks enable` or `tracks disable`.
Those change or delete the user's own music files, so they belong at their
terminal rather than here. If that is what they asked for, tell them the command
to run instead of running it.

Argument given: `$ARGUMENTS`

Report the command's output verbatim and add nothing else.
