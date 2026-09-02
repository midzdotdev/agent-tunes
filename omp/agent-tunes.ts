/**
 * agent-tunes — omp extension.
 *
 * Signals work start/stop to ~/agent-tunes/bin/agent-tunes, which owns all the
 * behaviour (random start position, the "only when nothing else is playing"
 * rule, the on/off switch). This file is deliberately thin so that the Claude
 * Code plugin and omp cannot drift apart.
 *
 * Symlinked into ~/.omp/agent/extensions/ so omp auto-discovers it.
 */
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const CLI = join(homedir(), "agent-tunes", "bin", "agent-tunes");
const KEY = `omp-${process.pid}`;

/** Minimal structural types — omp injects the real ExtensionAPI at load. */
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
  pi.setLabel?.("Agent Tunes");

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
