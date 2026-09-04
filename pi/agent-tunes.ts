/**
 * agent-tunes: a Pi extension.
 *
 * Signals work start and stop to ~/.agent-tunes/bin/agent-tunes, which owns all
 * the behaviour: the random start position, the "only when nothing else is
 * playing" rule, and the on/off switch. Kept deliberately thin so the Claude
 * Code plugin and this cannot drift apart.
 *
 * Setup symlinks this into ~/.pi/agent/extensions/, where Pi discovers it.
 */
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Find the agent-tunes command.
 *
 * Alongside the checkout first, since this file ships next to it and that holds
 * however the extension was installed: a symlink into an agent directory, or a
 * package install. ~/.agent-tunes is deliberately not consulted: that is the
 * data directory, and it holds no executables.
 */
function findCli(): string {
  const candidates: string[] = [];
  try {
    candidates.push(join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "agent-tunes"));
  } catch {
    /* no import.meta in this loader; the paths below still apply */
  }
  candidates.push(join(homedir(), ".local", "bin", "agent-tunes"));
  candidates.push(join(homedir(), "agent-tunes", "bin", "agent-tunes"));
  for (const c of candidates) {
    try {
      if (existsSync(c)) return c;
    } catch {
      /* unreadable candidate, try the next */
    }
  }
  return "agent-tunes"; // last resort: whatever is on PATH
}

const CLI = findCli();
const KEY = `pi-${process.pid}`;

/** Minimal structural types. Pi injects the real ExtensionAPI at load. */
interface Ctx {
  ui: { notify(msg: string, level?: string): void };
}
interface Api {
  setLabel?(label: string): void;
  on(event: string, handler: (event: unknown, ctx: Ctx) => void): void;
  registerCommand(
    name: string,
    spec: { description: string; handler: (args: string, ctx: Ctx) => Promise<void> },
  ): void;
}

function run(args: string[]): Promise<string> {
  return new Promise((resolve) => {
    execFile(CLI, args, { timeout: 5000 }, (err, stdout, stderr) =>
      resolve(err ? `agent-tunes: ${stderr || err.message}`.trim() : String(stdout).trim()),
    );
  });
}

/** Nested agents share this process, so refcount rather than stopping on the first end. */
let depth = 0;

export default function (pi: Api): void {
  // setLabel is a runtime action rather than a registration call, so calling it
  // while the extension is still loading throws. Defer it to session start.
  pi.on("session_start", () => {
    try {
      pi.setLabel?.("Agent Tunes");
    } catch {
      /* labelling is cosmetic, so never let it break the session */
    }
  });

  pi.on("agent_start", () => {
    if (depth++ === 0) void run(["start", "--key", KEY]);
  });

  pi.on("agent_end", () => {
    depth = Math.max(0, depth - 1);
    if (depth === 0) void run(["stop", "--key", KEY]);
  });

  pi.on("session_shutdown", () => {
    depth = 0;
    void run(["stop", "--key", KEY]);
  });

  pi.registerCommand("tunes", {
    description: "agent-tunes: on | off | toggle | status | play | stop",
    handler: async (args, ctx) => {
      const arg = (args || "").trim().split(/\s+/)[0] || "status";
      const sub = arg === "stop" ? "stop-all" : arg;
      const out = await run([sub]);
      ctx.ui.notify(out || `agent-tunes: ${sub}`, "info");
    },
  });
}
