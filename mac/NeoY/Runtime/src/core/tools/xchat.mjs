import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WORKER = fileURLToPath(import.meta.url);
const PROJECT_ID = /^g-p-[A-Za-z0-9_-]{8,128}$/;
const THREAD_ID = /^[A-Za-z0-9_-]{8,160}$/;

const XCHAT_COMMAND_TOOLS = [
  {
    name: "xchat.turn.new",
    description: "Submit a ChatGPT turn. Default async queues durable FIFO and returns status=submitted; sync submits immediately in a caller-owned WebHelm Session and returns a verified receipt.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        project_id: { type: "string", description: "Optional stable ChatGPT Project ID. Omit for a standalone thread." },
        thread_id: { type: "string", description: "Stable current ChatGPT thread ID." },
        message: { type: "string", description: "Continuation/handoff message for the next turn." },
        mode: { type: "string", enum: ["async", "sync"], description: "async is the default durable queue; sync waits for submission and requires caller-owned session_id." },
        session_id: { type: "string", description: "Required for sync only. Caller creates and closes this WebHelm Session." },
        reason: { type: "string", description: "Optional diagnostic reason for the control transfer." },
      },
      required: ["thread_id", "message"],
    },
  },
  {
    name: "xchat.thread.new",
    description: "Synchronously create a new ChatGPT thread via Browser Workspace Platform CLI and return its verified thread ID and URL (Temporary Chat has no durable ID).",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        project_id: { type: "string", description: "Optional stable ChatGPT Project ID. Omit for a normal standalone chat." },
        source_thread_id: { type: "string", description: "Optional stable source thread ID for provenance." },
        temporary: { type: "boolean", description: "Create a ChatGPT Temporary Chat. Defaults to false. Cannot be combined with project_id." },
        message: { type: "string", description: "Continuation/handoff message for the new thread." },
        reason: { type: "string", description: "Optional diagnostic reason for the control transfer." },
      },
      required: ["message"],
    },
  },
];

const XCHAT_COMMAND_MAP = new Map([
  ["turn", XCHAT_COMMAND_TOOLS.find((tool) => tool.name === "xchat.turn.new")],
  ["thread", XCHAT_COMMAND_TOOLS.find((tool) => tool.name === "xchat.thread.new")],
]);

export const XCHAT_LIFECYCLE_TOOLS = [{
  name: "chatgpt",
  description: "Submit ChatGPT turns (async FIFO by default, sync opt-in) or create a thread synchronously. Use command='help' for mode and session requirements.",
  inputSchema: {
    type: "object",
    properties: {
      command: { type: "string", description: "turn, thread, or help" },
      args: { type: "object", description: "Subcommand arguments. Use help for the exact schema." },
    },
    required: ["command"],
    additionalProperties: false,
  },
}];

export function isXChatLifecycleTool(name) {
  return name === "chatgpt";
}

function requireText(args, key) {
  const value = typeof args?.[key] === "string" ? args[key].trim() : "";
  if (!value) throw new Error(`${key} is required`);
  return value;
}

function validate(args, name) {
  if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("arguments must be an object");
  const projectId = typeof args.project_id === "string" && args.project_id.trim() ? args.project_id.trim() : null;
  if (projectId && !PROJECT_ID.test(projectId)) throw new Error("project_id is invalid");
  const temporary = args.temporary === undefined ? false : args.temporary;
  if (typeof temporary !== "boolean") throw new Error("temporary must be a boolean");
  if (name === "xchat.thread.new" && temporary && projectId) throw new Error("temporary=true cannot be combined with project_id");
  const message = requireText(args, "message");
  if (message.length > 64_000) throw new Error("message is too large");
  const sourceThreadId = typeof args.source_thread_id === "string" && args.source_thread_id.trim() ? args.source_thread_id.trim() : null;
  if (sourceThreadId && !THREAD_ID.test(sourceThreadId)) throw new Error("source_thread_id is invalid");
  let threadId = null;
  if (name === "xchat.turn.new") {
    threadId = requireText(args, "thread_id");
    if (!THREAD_ID.test(threadId)) throw new Error("thread_id is invalid");
  }
  const mode = name === "xchat.turn.new" ? (args.mode === undefined ? "async" : args.mode) : null;
  if (name === "xchat.turn.new" && !["async", "sync"].includes(mode)) throw new Error("mode must be async or sync");
  const sessionId = args.session_id;
  if (name === "xchat.turn.new") {
    if (mode === "sync" && (typeof sessionId !== "string" || !sessionId.trim())) {
      throw new Error("mode sync requires caller-owned session_id");
    }
    if (mode === "async" && sessionId !== undefined) throw new Error("mode async does not accept session_id");
  }
  const reason = typeof args.reason === "string" && args.reason.trim() ? args.reason.trim().slice(0, 2000) : null;
  return { projectId, threadId, sourceThreadId, temporary, message, reason, mode, sessionId };
}

function resultText(payload) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], isError: false };
}

// The Platform CLI owns the authoritative receipt. Never manufacture a thread ID.
export function parsePlatformReceipt(output, action) {
  const envelope = output?.result ?? output;
  if (!envelope || envelope.ok === false) throw new Error(envelope?.stderr || "Browser Workspace action failed");
  const raw = typeof envelope?.stdout === "string" ? envelope.stdout.trim() : envelope;
  let receipt;
  try { receipt = typeof raw === "string" ? JSON.parse(raw) : raw; }
  catch { throw new Error("Browser Workspace returned no machine-readable receipt"); }
  if (receipt?.status !== "submitted" || receipt?.mode !== action) throw new Error("Browser Workspace did not verify submission");
  if (action === "new-thread" && !receipt.temporary && (!THREAD_ID.test(receipt.thread_id || "") || !/^https:\/\/chatgpt\.com\/c\//.test(receipt.thread_url || ""))) {
    throw new Error("Browser Workspace did not return a durable ChatGPT thread ID and URL");
  }
  return receipt;
}

export function scheduleXChatLifecycle(name, input, options = {}) {
  if (!isXChatLifecycleTool(name)) throw new Error(`unknown ChatGPT lifecycle tool: ${name}`);
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("arguments must be an object");
  const command = typeof input.command === "string" ? input.command.trim() : "";
  const args = input.args === undefined ? {} : input.args;
  if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("args must be an object");
  if (command === "help") {
    const named = typeof args.command === "string" ? args.command.trim() : "";
    if (named) {
      const tool = XCHAT_COMMAND_MAP.get(named);
      if (!tool) throw new Error(`Unknown chatgpt command '${named}'`);
      return resultText({ command: named, description: tool.description || "", schema: tool.inputSchema });
    }
    return resultText({ commands: [...XCHAT_COMMAND_MAP].map(([subcommand, tool]) => ({ command: subcommand, description: tool.description || "" })) });
  }
  const tool = XCHAT_COMMAND_MAP.get(command);
  if (!tool) throw new Error(`Unknown chatgpt command '${command}'`);
  const internalName = tool.name;
  const parsed = validate(args, internalName);
  const action = internalName === "xchat.turn.new" ? "new-turn" : "new-thread";
  const config = {
    ...(parsed.projectId ? { project_id: parsed.projectId } : {}),
    temporary: parsed.temporary,
    message: parsed.message,
    reason: parsed.reason,
    ...(parsed.threadId ? { thread_id: parsed.threadId } : {}),
    ...(action === "new-turn" ? { mode: parsed.mode } : {}),
    ...(parsed.sourceThreadId ? { source_thread_id: parsed.sourceThreadId } : {}),
  };
  const dir = fs.mkdtempSync(path.join(options.tmpDir || process.env.TMPDIR || "/tmp", "neoy-chatgpt-"));
  const configPath = path.join(dir, "config.json");
  try {
    fs.chmodSync(dir, 0o700);
    fs.writeFileSync(configPath, JSON.stringify(config), { mode: 0o600 });
    const cli = options.cli || process.env.BROWSER_WORKSPACE_CLI || "uvx";
    const prefix = options.cli || process.env.BROWSER_WORKSPACE_CLI ? [] : ["browser-workspace"];
    const sessionArgs = action === "new-thread" ? ["--auto-session"] :
      parsed.mode === "sync" ? ["--mode", "sync", "--session-id", parsed.sessionId.trim()] : ["--mode", "async"];
    const result = (options.spawnSyncImpl || spawnSync)(cli, [...prefix, "platform", "run", "chatgpt", action, ...sessionArgs, "--config", configPath], {
      encoding: "utf8",
      timeout: Number(process.env.XCHAT_LIFECYCLE_TIMEOUT_MS || 600_000),
      maxBuffer: 4 * 1024 * 1024,
    });
    if (result.error || result.status !== 0) throw new Error(result.error?.message || String(result.stderr || result.stdout || "Browser Workspace lifecycle action failed"));
    let output;
    try { output = JSON.parse(String(result.stdout || "")); }
    catch { throw new Error("Browser Workspace did not return JSON"); }
    return resultText(parsePlatformReceipt(output, action));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}
