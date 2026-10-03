import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WORKER = fileURLToPath(import.meta.url);
const PROJECT_ID = /^g-p-[A-Za-z0-9_-]{8,128}$/;
const THREAD_ID = /^[A-Za-z0-9_-]{8,160}$/;

export const XCHAT_LIFECYCLE_TOOLS = [
  {
    name: "xchat.turn.new",
    description: "Terminal control transfer: schedule the next user turn in the same Web ChatGPT thread after the current assistant turn finishes. Uses Browser Workspace. On success, stop the current turn and perform no further business actions.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        project_id: { type: "string", description: "Optional stable ChatGPT Project ID. Omit for a standalone thread." },
        thread_id: { type: "string", description: "Stable current ChatGPT thread ID." },
        message: { type: "string", description: "Continuation/handoff message for the next turn." },
        reason: { type: "string", description: "Optional diagnostic reason for the control transfer." },
      },
      required: ["thread_id", "message"],
    },
  },
  {
    name: "xchat.thread.new",
    description: "Terminal control transfer: schedule creation of a fresh Web ChatGPT thread, optionally inside a Project or as Temporary Chat, and submit the continuation there. Uses Browser Workspace. On success, stop the current turn and perform no further business actions.",
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

export function isXChatLifecycleTool(name) {
  return name === "xchat.turn.new" || name === "xchat.thread.new";
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
  const reason = typeof args.reason === "string" && args.reason.trim() ? args.reason.trim().slice(0, 2000) : null;
  return { projectId, threadId, sourceThreadId, temporary, message, reason };
}

function resultText(payload) {
  return { content: [{ type: "text", text: JSON.stringify(payload) }], isError: false };
}

export function scheduleXChatLifecycle(name, args, options = {}) {
  if (!isXChatLifecycleTool(name)) throw new Error(`unknown XChat lifecycle tool: ${name}`);
  const parsed = validate(args, name);
  const transferId = options.transferId || crypto.randomUUID();
  const dataRoot = options.dataDir || process.env.NEOY_DATA_DIR || path.join(os.homedir(), "Library/Application Support/NeoY");
  const dir = path.join(dataRoot, "xchat-lifecycle");
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  try { fs.chmodSync(dir, 0o700); } catch {}

  const action = name === "xchat.turn.new" ? "new-turn" : "new-thread";
  const config = {
    ...(parsed.projectId ? { project_id: parsed.projectId } : {}),
    temporary: parsed.temporary,
    message: parsed.message,
    reason: parsed.reason,
    ...(parsed.threadId ? { thread_id: parsed.threadId } : {}),
    ...(parsed.sourceThreadId ? { source_thread_id: parsed.sourceThreadId } : {}),
  };
  const configPath = path.join(dir, `${transferId}.json`);
  const statusPath = path.join(dir, `${transferId}.status.json`);
  fs.writeFileSync(configPath, JSON.stringify(config), { mode: 0o600 });
  fs.writeFileSync(statusPath, JSON.stringify({
    transfer_id: transferId,
    status: "scheduled",
    mode: action,
    ...(parsed.projectId ? { project_id: parsed.projectId } : {}),
    temporary: parsed.temporary,
    ...(parsed.threadId ? { thread_id: parsed.threadId } : {}),
    ...(parsed.sourceThreadId ? { source_thread_id: parsed.sourceThreadId } : {}),
    reason: parsed.reason,
    created_at: new Date().toISOString(),
  }), { mode: 0o600 });

  const spawnImpl = options.spawnImpl || spawn;
  const workerPath = options.workerPath || WORKER;
  const child = spawnImpl(process.execPath, [workerPath, action, configPath, statusPath], {
    detached: true,
    stdio: "ignore",
    env: { ...process.env, ...(options.env || {}) },
  });
  child.unref?.();

  return resultText({
    status: "scheduled",
    terminal: true,
    transfer_id: transferId,
    mode: action,
    ...(parsed.projectId ? { project_id: parsed.projectId } : {}),
    temporary: parsed.temporary,
    ...(parsed.threadId ? { thread_id: parsed.threadId } : {}),
    ...(parsed.sourceThreadId ? { source_thread_id: parsed.sourceThreadId } : {}),
    instruction: "End the current orchestrator turn now. Do not make additional business tool calls.",
  });
}


function writeWorkerStatus(statusPath, payload) {
  const tmp = statusPath + ".tmp-" + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(payload), { mode: 0o600 });
  fs.renameSync(tmp, statusPath);
}

function runWorker(action, configPath, statusPath) {
  if (!["new-turn", "new-thread"].includes(action) || !configPath || !statusPath) return 64;
  const cli = process.env.BROWSER_WORKSPACE_CLI
    || path.join(os.homedir(), ".agents/skills/browser-workspace/bin/browser-workspace");
  const started = new Date().toISOString();
  try {
    writeWorkerStatus(statusPath, { transfer_id: path.basename(statusPath, ".status.json"), status: "running", mode: action, started_at: started });
    const result = spawnSync(cli, ["platform", "run", "chatgpt", action, "--config", configPath], {
      encoding: "utf8",
      timeout: Number(process.env.XCHAT_LIFECYCLE_TIMEOUT_MS || 600_000),
      maxBuffer: 4 * 1024 * 1024,
    });
    const stdout = String(result.stdout || "").trim();
    const stderr = String(result.stderr || "").trim();
    if (result.error || result.status !== 0) {
      writeWorkerStatus(statusPath, { status: "failed", mode: action, started_at: started, finished_at: new Date().toISOString(), exit_code: result.status, error: result.error?.message || stderr || stdout || "Browser Workspace lifecycle action failed" });
      return result.status || 1;
    }
    let output = stdout;
    try { output = JSON.parse(stdout || "{}"); } catch {}
    writeWorkerStatus(statusPath, { status: "completed", mode: action, started_at: started, finished_at: new Date().toISOString(), output });
    return 0;
  } finally {
    try { fs.unlinkSync(configPath); } catch {}
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  const [action, configPath, statusPath] = process.argv.slice(2);
  process.exitCode = runWorker(action, configPath, statusPath);
}
