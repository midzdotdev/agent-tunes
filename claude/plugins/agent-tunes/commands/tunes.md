---
description: Turn agent-tunes background music on or off, or show its status
allowed-tools: Bash(~/agent-tunes/bin/agent-tunes:*)
---

Run `~/agent-tunes/bin/agent-tunes` with the argument the user asked for:

- no argument, or "status" → `status`
- "on" / "off" / "toggle" → that subcommand
- "play" → `play`
- "stop" → `stop-all`

Argument given: `$ARGUMENTS`

Report the command's output verbatim and add nothing else.
