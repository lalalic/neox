#!/usr/bin/env node
import { handleShell, SHELL_TOOLS } from "./shell.mjs";
import { handleFilesystem, FILESYSTEM_TOOLS } from "./filesystem.mjs";
import { handlePatch, PATCH_TOOLS } from "./patch.mjs";
import { handleCodex, CODEX_TOOLS } from "./codex.mjs";
import { handleAudit, AUDIT_TOOLS } from "./audit.mjs";
import { configurePty, handlePty, ptyReady, ptyStatus, teardownPty, PTY_TOOLS } from "./pty.mjs";

import { execFileSync, spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const CORE_VERSION = "0.2.0";
const SERVER_NAME = "neo-core-tools";
const SERVER_TITLE = "Neo Core Tools";
const MODERN_PROTOCOL = "2026-07-28";
const LEGACY_PROTOCOLS = new Set(["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]);
const HOME = os.homedir();
const APP_SUPPORT_DIR = envValue("NEO_CORE_DATA_DIR", "MAC_DEV_BRIDGE_DATA_DIR") || path.join(HOME, "Library", "Application Support", "NeoY", "core");
const JOB_DIR = path.join(APP_SUPPORT_DIR, "jobs");
const LOG_DIR = envValue("NEO_CORE_LOG_DIR", "MAC_DEV_BRIDGE_LOG_DIR") || path.join(HOME, "Library", "Logs", "NeoY", "Core");
const AUDIT_LOG = envValue("NEO_CORE_AUDIT_LOG", "MAC_DEV_BRIDGE_AUDIT_LOG") || path.join(LOG_DIR, "audit.jsonl");
const DEFAULT_OUTPUT_BYTES = clampInt(envValue("NEO_CORE_DEFAULT_OUTPUT_BYTES", "MAC_DEV_BRIDGE_DEFAULT_OUTPUT_BYTES"), 1_000_000, 1_024, 8_000_000);
const MAX_OUTPUT_BYTES = clampInt(envValue("NEO_CORE_MAX_OUTPUT_BYTES", "MAC_DEV_BRIDGE_MAX_OUTPUT_BYTES"), 8_000_000, 1_024, 64_000_000);
const SHELL_EXEC_DEFAULT_TIMEOUT_MS = 600_000;
const AUDIT_MODE = ["off", "metadata", "full"].includes(envValue("NEO_CORE_AUDIT_MODE", "MAC_DEV_BRIDGE_AUDIT_MODE") || "metadata")
  ? (envValue("NEO_CORE_AUDIT_MODE", "MAC_DEV_BRIDGE_AUDIT_MODE") || "metadata")
  : "metadata";
const DEFAULT_SHELL = process.platform === "darwin" && fs.existsSync("/bin/zsh")
  ? "/bin/zsh"
  : fs.existsSync("/bin/bash")
    ? "/bin/bash"
    : "/bin/sh";
const SHELL = envValue("NEO_CORE_SHELL", "MAC_DEV_BRIDGE_SHELL") || DEFAULT_SHELL;
const CODEX_BIN = process.env.CODEX_BIN || "codex";
const CORE_TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const UNLOCK_RECHECK_MS = clampInt(envValue("NEO_CORE_UNLOCK_RECHECK_MS", "MAC_DEV_BRIDGE_UNLOCK_RECHECK_MS"), 3_000, 250, 60_000);


const TUNNEL_RUNTIME_KEY_WAS_PRESENT = Boolean(process.env.CONTROL_PLANE_API_KEY);
delete process.env.CONTROL_PLANE_API_KEY;
const FULL_ACCESS_ACK = "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS";
// Capture the environment acknowledgement, then remove it from our own environment so
// no child can inherit it.
//
// Every child got it before: mergedEnv() copies process.env into shell_exec and
// shell_start, so any command the model ran could re-launch Core Tools with the ack
// already set — and a Core Tools process started that way never reads the unlock file, so it is
// unstoppable by the kill switch. That is a route around the revocation latch created
// by the very tool the latch is meant to gate. CONTROL_PLANE_API_KEY has been scrubbed
// on the line above for the same reason; this variable was missed.
//
// Behaviour for THIS process is unchanged: the captured value still unlocks, exactly
// as documented in SECURITY.md.
const FULL_ACCESS_ACK_FROM_ENV = envValue("NEO_CORE_FULL_ACCESS_ACK", "MAC_DEV_BRIDGE_FULL_ACCESS_ACK");
delete process.env.NEO_CORE_FULL_ACCESS_ACK;
delete process.env.MAC_DEV_BRIDGE_FULL_ACCESS_ACK;
const FULL_ACCESS_UNLOCK_FILE = envValue("NEO_CORE_UNLOCK_FILE", "MAC_DEV_BRIDGE_UNLOCK_FILE") || path.join(APP_SUPPORT_DIR, "FULL_ACCESS_ENABLED");

await Promise.all([
  fsp.mkdir(APP_SUPPORT_DIR, { recursive: true, mode: 0o700 }),
  fsp.mkdir(JOB_DIR, { recursive: true, mode: 0o700 }),
  fsp.mkdir(LOG_DIR, { recursive: true, mode: 0o700 }),
]);
await Promise.all([
  fsp.chmod(APP_SUPPORT_DIR, 0o700).catch(() => {}),
  fsp.chmod(JOB_DIR, 0o700).catch(() => {}),
  fsp.chmod(LOG_DIR, 0o700).catch(() => {}),
  fsp.chmod(AUDIT_LOG, 0o600).catch((error) => {
    if (error?.code !== "ENOENT") throw error;
  }),
]);

let fullAccessUnlocked = FULL_ACCESS_ACK_FROM_ENV === FULL_ACCESS_ACK;
if (!fullAccessUnlocked) {
  try {
    fullAccessUnlocked = (await fsp.readFile(FULL_ACCESS_UNLOCK_FILE, "utf8")).trim() === FULL_ACCESS_ACK;
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}
if (!fullAccessUnlocked) {
  stderr(`Refusing to start unrestricted Neo Core Tools. Create ${FULL_ACCESS_UNLOCK_FILE} containing ${FULL_ACCESS_ACK}, or set NEO_CORE_FULL_ACCESS_ACK to that exact value.`);
  process.exit(78);
}

let legacyInitialized = false;

function envValue(primary, legacy) {
  return process.env[primary] ?? process.env[legacy];
}

function clampInt(value, fallback, min, max) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

function nowIso() {
  return new Date().toISOString();
}

function safeJson(value) {
  return JSON.stringify(value, (_key, nested) => {
    if (typeof nested === "bigint") return nested.toString();
    if (Buffer.isBuffer(nested)) return nested.toString("base64");
    return nested;
  });
}

function writeProtocolMessage(message) {
  process.stdout.write(`${safeJson(message)}\n`);
}

function stderr(message) {
  process.stderr.write(`[${nowIso()}] ${message}\n`);
}

function serverInfo() {
  return {
    name: SERVER_NAME,
    title: SERVER_TITLE,
    version: CORE_VERSION,
    description: "Unrestricted local shell, filesystem, process, patch, and Codex-history access on the host Mac.",
  };
}

function isModernRequest(message) {
  const version = message?.params?._meta?.["io.modelcontextprotocol/protocolVersion"];
  return version === MODERN_PROTOCOL || message?.method === "server/discover";
}

function resultMeta() {
  return { "io.modelcontextprotocol/serverInfo": serverInfo() };
}

function completeResult(payload, modern, cache = null) {
  if (!modern) return payload;
  return {
    resultType: "complete",
    ...payload,
    ...(cache ? { ttlMs: cache.ttlMs, cacheScope: cache.cacheScope } : {}),
    _meta: { ...(payload?._meta || {}), ...resultMeta() },
  };
}

function sendResult(id, result) {
  writeProtocolMessage({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message, data = undefined) {
  writeProtocolMessage({
    jsonrpc: "2.0",
    id: id ?? null,
    error: { code, message, ...(data === undefined ? {} : { data }) },
  });
}

function toolTextResult(value, { isError = false, modern = false } = {}) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return completeResult(
    {
      content: [{ type: "text", text }],
      structuredContent: typeof value === "string" ? { text: value } : value,
      isError,
    },
    modern,
  );
}

function requireString(args, key, { allowEmpty = false } = {}) {
  const value = args?.[key];
  if (typeof value !== "string" || (!allowEmpty && value.length === 0)) {
    throw new Error(`'${key}' must be ${allowEmpty ? "a string" : "a non-empty string"}`);
  }
  return value;
}

function optionalString(args, key, fallback = undefined) {
  const value = args?.[key];
  if (value === undefined || value === null) return fallback;
  if (typeof value !== "string") throw new Error(`'${key}' must be a string`);
  return value;
}

function optionalBoolean(args, key, fallback = false) {
  const value = args?.[key];
  if (value === undefined || value === null) return fallback;
  if (typeof value !== "boolean") throw new Error(`'${key}' must be a boolean`);
  return value;
}

function optionalInteger(args, key, fallback, min, max) {
  const value = args?.[key];
  if (value === undefined || value === null) return fallback;
  if (!Number.isInteger(value)) throw new Error(`'${key}' must be an integer`);
  if (value < min || value > max) throw new Error(`'${key}' must be between ${min} and ${max}`);
  return value;
}

function requireInteger(args, key, min, max) {
  const value = args?.[key];
  if (!Number.isInteger(value)) throw new Error(`'${key}' must be an integer`);
  if (value < min || value > max) throw new Error(`'${key}' must be between ${min} and ${max}`);
  return value;
}

const GUI_FOCUS_POLICY = envValue("NEO_CORE_GUI_FOCUS_POLICY", "MAC_DEV_BRIDGE_GUI_FOCUS_POLICY") || "background-first";
const SETTINGS_FILE = envValue("NEO_CORE_SETTINGS_FILE", "MAC_DEV_BRIDGE_SETTINGS_FILE") || path.join(APP_SUPPORT_DIR, "settings.json");
const DEFAULT_OPERATOR_SETTINGS = Object.freeze({ strictApprovals: false });
const FOREGROUND_GUI_APPROVAL_FILE = envValue("NEO_CORE_FOREGROUND_GUI_APPROVAL_FILE", "MAC_DEV_BRIDGE_FOREGROUND_GUI_APPROVAL_FILE")
  || path.join(APP_SUPPORT_DIR, "FOREGROUND_GUI_APPROVED");
const FOREGROUND_GUI_MAX_TTL_MS = 5 * 60 * 1000;

async function readOperatorSettings() {
  let raw;
  try {
    raw = await fsp.readFile(SETTINGS_FILE, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return { ...DEFAULT_OPERATOR_SETTINGS };
    throw error;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // A malformed operator settings file fails toward the safer behavior rather
    // than silently granting broader browser/GUI access.
    return { strictApprovals: true, settingsError: "invalid-json" };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { strictApprovals: true, settingsError: "invalid-shape" };
  }
  return {
    strictApprovals: typeof parsed.strictApprovals === "boolean"
      ? parsed.strictApprovals
      : DEFAULT_OPERATOR_SETTINGS.strictApprovals,
  };
}

function extractQuotedTargets(command, pattern) {
  const out = [];
  for (const match of command.matchAll(pattern)) {
    const value = String(match[1] || match[2] || "").trim();
    if (value) out.push(value);
  }
  return out;
}

function guiFocusRisk(command) {
  if (process.platform !== "darwin" || GUI_FOCUS_POLICY !== "background-first") return null;
  if (typeof command !== "string" || command.length === 0) return null;

  const usesOsascript = /(^|[\s;&|()])(?:\/usr\/bin\/)?osascript(?:[\s;&|<]|$)/m.test(command);
  const jxaApps = extractQuotedTargets(command, /\bApplication\s*\(\s*(?:["']([^"']+)["'])\s*\)/g);
  const tellApps = extractQuotedTargets(command, /tell\s+application\s+(?:["']([^"']+)["'])/gi);
  const tellProcesses = extractQuotedTargets(command, /tell\s+process\s+(?:["']([^"']+)["'])/gi);
  const appTargets = [...new Set([...jxaApps, ...tellApps, ...tellProcesses])];
  const nonSystemTargets = appTargets.filter((name) => name.toLowerCase() !== "system events");

  if ((usesOsascript || jxaApps.length > 0) && nonSystemTargets.length > 0) {
    return { reason: "apple-events-app-control", apps: nonSystemTargets };
  }

  if (usesOsascript && /\b(?:activate|frontmost\s+(?:to|=)\s+true|AXRaise|keystroke|key code)\b/i.test(command)) {
    return { reason: "apple-events-focus-action", apps: appTargets.length ? appTargets : ["System Events"] };
  }

  if (/(^|[\s;&|()])(?:\/usr\/bin\/)?open(?:[\s;&|<]|$)/m.test(command) && !/(^|\s)-g(?:\s|$)/m.test(command)) {
    const appMatches = extractQuotedTargets(command, /(?:^|\s)-a\s+(?:["']([^"']+)["'])/gm);
    return { reason: "macos-open-foreground", apps: appMatches.length ? appMatches : ["open"] };
  }

  return null;
}


async function foregroundGuiApprovalPresent() {
  try {
    await fsp.stat(FOREGROUND_GUI_APPROVAL_FILE);
    return { present: true, path: FOREGROUND_GUI_APPROVAL_FILE };
  } catch (error) {
    return { present: false, path: FOREGROUND_GUI_APPROVAL_FILE, reason: error?.code || String(error) };
  }
}

async function consumeForegroundGuiApproval(risk) {
  let raw;
  try {
    raw = await fsp.readFile(FOREGROUND_GUI_APPROVAL_FILE, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }

  let grant;
  try {
    grant = JSON.parse(raw);
  } catch (source) {
    const error = new Error("Foreground GUI approval file is invalid JSON.");
    error.code = "GUI_FOREGROUND_APPROVAL_INVALID";
    throw error;
  }

  const nonce = typeof grant?.nonce === "string" ? grant.nonce : "";
  const expiresAt = typeof grant?.expiresAt === "string" ? grant.expiresAt : "";
  const allowedApps = Array.isArray(grant?.allowedApps) ? grant.allowedApps.filter((x) => typeof x === "string") : [];
  const expiry = Date.parse(expiresAt);
  const now = Date.now();
  if (!/^[0-9a-fA-F]{32}$/.test(nonce) || !Number.isFinite(expiry) || expiry <= now || expiry - now > FOREGROUND_GUI_MAX_TTL_MS) {
    await fsp.unlink(FOREGROUND_GUI_APPROVAL_FILE).catch(() => {});
    const error = new Error("Foreground GUI approval is missing, expired, or malformed.");
    error.code = "GUI_FOREGROUND_APPROVAL_INVALID";
    throw error;
  }

  const normalized = new Set(allowedApps.map((x) => x.trim().toLowerCase()).filter(Boolean));
  const missing = risk.apps.filter((app) => !normalized.has(String(app).trim().toLowerCase()));
  if (missing.length > 0) {
    const error = new Error(`Foreground GUI approval does not allow: ${missing.join(", ")}.`);
    error.code = "GUI_FOREGROUND_APP_NOT_APPROVED";
    throw error;
  }

  // Single use. Unlink before executing the focus-stealing shell call.
  await fsp.unlink(FOREGROUND_GUI_APPROVAL_FILE);
  return { nonce, expiresAt, allowedApps };
}

function optionalStringArray(args, key, fallback = undefined) {
  const value = args?.[key];
  if (value === undefined || value === null) return fallback;
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    throw new Error(`'${key}' must be an array of strings`);
  }
  return value;
}

function resolvePath(input, cwd = HOME) {
  if (typeof input !== "string" || input.length === 0) throw new Error("path must be a non-empty string");
  if (input === "~") return HOME;
  if (input.startsWith("~/")) return path.join(HOME, input.slice(2));
  return path.resolve(cwd, input);
}

function normalizeEnv(input) {
  if (input === undefined || input === null) return {};
  if (typeof input !== "object" || Array.isArray(input)) throw new Error("'env' must be an object");
  const output = {};
  for (const [key, value] of Object.entries(input)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new Error(`Invalid environment variable name: ${key}`);
    if (value === null) output[key] = null;
    else if (["string", "number", "boolean"].includes(typeof value)) output[key] = String(value);
    else throw new Error(`Environment value for '${key}' must be string, number, boolean, or null`);
  }
  return output;
}

function mergedEnv(overrides = {}) {
  const env = { ...process.env };
  for (const [key, value] of Object.entries(overrides)) {
    if (value === null) delete env[key];
    else env[key] = value;
  }
  return env;
}

function redactString(input) {
  return String(input)
    .replace(/\b(sk-[A-Za-z0-9_-]{12,})\b/g, "[REDACTED_OPENAI_KEY]")
    .replace(/\b(gh[pousr]_[A-Za-z0-9]{20,})\b/g, "[REDACTED_GITHUB_TOKEN]")
    .replace(/\b(xox[baprs]-[A-Za-z0-9-]{10,})\b/g, "[REDACTED_SLACK_TOKEN]")
    .replace(/((?:password|passwd|token|secret|api[_-]?key)\s*[=:]\s*)[^\s'\"]+/gi, "$1[REDACTED]");
}

// Keystrokes are never written to the audit log, at any AUDIT_MODE.
//
// This is centralised inside audit() rather than applied at the call site because
// three separate paths log a tool's raw arguments: the success path, the failure
// path in tools/call, and assertStillUnlocked's revocation record. Measured while
// building this: driving an ssh-keygen passphrase and a `read -s` prompt through
// pty_write turns AUDIT_MODE=full into a plaintext password store, and redactString
// cannot help because a passphrase looks like any other word. The byte length and a
// hash prefix keep the record useful for correlating a session without keeping the
// secret.
function auditSafeArguments(tool, args) {
  if (tool === "pty_write" && typeof args?.data === "string") {
    const bytes = Buffer.byteLength(args.data, "utf8");
    const digest = crypto.createHash("sha256").update(args.data, "utf8").digest("hex").slice(0, 16);
    return { ...args, data: `[REDACTED ${bytes} bytes sha256:${digest}]` };
  }
  return args;
}

async function audit(tool, argsInput, summary = {}, error = null) {
  if (AUDIT_MODE === "off") return;
  try {
    const args = auditSafeArguments(tool, argsInput);
    const raw = safeJson(args ?? {});
    const entry = {
      timestamp: nowIso(),
      pid: process.pid,
      tool,
      argumentsHash: crypto.createHash("sha256").update(raw).digest("hex"),
      summary,
      error: error ? String(error?.message || error) : null,
    };
    if (AUDIT_MODE === "full") entry.arguments = JSON.parse(redactString(raw));
    else {
      const preview = redactString(raw).slice(0, 512);
      entry.argumentsPreview = preview;
    }
    await fsp.appendFile(AUDIT_LOG, `${safeJson(entry)}\n`, { encoding: "utf8", mode: 0o600 });
  } catch (auditError) {
    stderr(`audit failure: ${auditError?.message || auditError}`);
  }
}

function boundedCollector(maxBytes) {
  const chunks = [];
  let bytes = 0;
  let truncated = false;
  return {
    append(chunk) {
      if (!Buffer.isBuffer(chunk)) chunk = Buffer.from(chunk);
      if (bytes >= maxBytes) {
        truncated = true;
        return;
      }
      const remaining = maxBytes - bytes;
      if (chunk.length > remaining) {
        chunks.push(chunk.subarray(0, remaining));
        bytes += remaining;
        truncated = true;
      } else {
        chunks.push(chunk);
        bytes += chunk.length;
      }
    },
    value() {
      return Buffer.concat(chunks).toString("utf8");
    },
    get truncated() {
      return truncated;
    },
    get bytes() {
      return bytes;
    },
  };
}

async function runCommand({ command, cwd, env = {}, stdin = undefined, timeoutMs = SHELL_EXEC_DEFAULT_TIMEOUT_MS, maxOutputBytes = DEFAULT_OUTPUT_BYTES }) {
  const effectiveCwd = resolvePath(cwd || HOME);
  const stdout = boundedCollector(Math.min(maxOutputBytes, MAX_OUTPUT_BYTES));
  const stderrOutput = boundedCollector(Math.min(maxOutputBytes, MAX_OUTPUT_BYTES));
  const startedAt = Date.now();
  let timedOut = false;
  let settled = false;

  return await new Promise((resolve, reject) => {
    const child = spawn(SHELL, ["-lc", command], {
      cwd: effectiveCwd,
      env: mergedEnv(env),
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    // Registered so a revocation can kill in-flight commands. Without this the
    // bridge exits and leaves an unrestricted process running past its own
    // timeout, invisible to disable.sh (shell_exec writes no job metadata).
    inFlightCommands.add(child);
    child.once("close", () => inFlightCommands.delete(child));

    let timer = null;
    const fail = (error) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      reject(error);
    };

    child.once("error", fail);
    child.stdout.on("data", (chunk) => stdout.append(chunk));
    child.stderr.on("data", (chunk) => stderrOutput.append(chunk));

    if (stdin !== undefined) child.stdin.end(String(stdin));
    else child.stdin.end();

    if (timeoutMs > 0) {
      timer = setTimeout(() => {
        timedOut = true;
        try {
          process.kill(-child.pid, "SIGTERM");
        } catch {
          try { child.kill("SIGTERM"); } catch {}
        }
        setTimeout(() => {
          if (settled) return;
          try {
            process.kill(-child.pid, "SIGKILL");
          } catch {
            try { child.kill("SIGKILL"); } catch {}
          }
        }, 2_000).unref();
      }, timeoutMs);
      timer.unref();
    }

    child.once("close", (code, signal) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({
        command,
        shell: SHELL,
        cwd: effectiveCwd,
        exitCode: code,
        signal,
        timedOut,
        durationMs: Date.now() - startedAt,
        stdout: stdout.value(),
        stderr: stderrOutput.value(),
        stdoutTruncated: stdout.truncated,
        stderrTruncated: stderrOutput.truncated,
        capturedStdoutBytes: stdout.bytes,
        capturedStderrBytes: stderrOutput.bytes,
      });
    });
  });
}

async function readJobMetadata(jobId) {
  if (!/^[A-Za-z0-9._-]{1,128}$/.test(jobId)) throw new Error("Invalid job_id");
  const metadataPath = path.join(JOB_DIR, `${jobId}.json`);
  return JSON.parse(await fsp.readFile(metadataPath, "utf8"));
}

async function writeJobMetadata(metadata) {
  // Write then rename, so the file is never partially visible.
  //
  // A plain writeFile let process.exit land between open and write, leaving a 0-byte
  // file. disable.sh's job_field then extracts nothing and builds no target, so a live
  // unrestricted process read as "no job" — the reclaimer silently skipped it. Measured
  // during a revocation that raced a provider restart.
  const metadataPath = path.join(JOB_DIR, `${metadata.id}.json`);
  const tmpPath = `${metadataPath}.tmp`;
  await fsp.writeFile(tmpPath, `${JSON.stringify(metadata, null, 2)}\n`, { mode: 0o600 });
  await fsp.rename(tmpPath, metadataPath);
}

function processRunning(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

async function tailFile(filePath, maxBytes = 100_000) {
  // pty session metadata lives in the same jobs directory so scripts/disable.sh
  // reclaims it, but a pty has no log files: its output is a ring buffer read
  // through pty_read. Without this guard shell_job_status on a pty entry threw an
  // opaque TypeError from stat(undefined) instead of returning empty logs.
  if (typeof filePath !== "string" || filePath.length === 0) {
    return { text: "", size: 0, returnedBytes: 0, truncated: false };
  }
  try {
    const stat = await fsp.stat(filePath);
    const length = Math.min(stat.size, maxBytes);
    const handle = await fsp.open(filePath, "r");
    try {
      const buffer = Buffer.alloc(length);
      await handle.read(buffer, 0, length, stat.size - length);
      return { text: buffer.toString("utf8"), size: stat.size, returnedBytes: length, truncated: stat.size > length };
    } finally {
      await handle.close();
    }
  } catch (error) {
    if (error?.code === "ENOENT") return { text: "", size: 0, returnedBytes: 0, truncated: false };
    throw error;
  }
}

async function callCodexAppServer(method, params, timeoutMs = 30_000) {
  return await new Promise((resolve, reject) => {
    const child = spawn(CODEX_BIN, ["app-server"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });
    const rl = readline.createInterface({ input: child.stdout });
    const stderrCollector = boundedCollector(200_000);
    child.stderr.on("data", (chunk) => stderrCollector.append(chunk));

    let done = false;
    let timer = null;
    const finish = (error, value) => {
      if (done) return;
      done = true;
      if (timer) clearTimeout(timer);
      rl.close();
      try { child.stdin.end(); } catch {}
      try { child.kill("SIGTERM"); } catch {}
      if (error) reject(error);
      else resolve(value);
    };

    child.once("error", (error) => finish(error));
    child.once("exit", (code, signal) => {
      if (!done) finish(new Error(`codex app-server exited before responding (code=${code}, signal=${signal}): ${stderrCollector.value()}`));
    });

    rl.on("line", (line) => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (message.id === 0) {
        child.stdin.write(`${JSON.stringify({ method: "initialized", params: {} })}\n`);
        child.stdin.write(`${JSON.stringify({ id: 1, method, params })}\n`);
        return;
      }
      if (message.id === 1) {
        if (message.error) finish(new Error(`Codex app-server error ${message.error.code}: ${message.error.message}`));
        else finish(null, message.result);
      }
    });

    child.stdin.write(`${JSON.stringify({
      id: 0,
      method: "initialize",
      params: {
        clientInfo: { name: SERVER_NAME, title: SERVER_TITLE, version: CORE_VERSION },
        capabilities: { experimentalApi: true },
      },
    })}\n`);

    timer = setTimeout(() => {
      finish(new Error(`Timed out waiting for Codex app-server after ${timeoutMs}ms: ${stderrCollector.value()}`));
    }, timeoutMs);
    timer.unref();
  });
}

const TOOLS = [
{
    name: "bridge_status",
    title: "Bridge status",
    description: "Inspect the host identity, runtime paths, permissions context, configured shell, audit log, and Codex executable. This is read-only.",
    inputSchema: { type: "object", additionalProperties: false },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  ...SHELL_TOOLS,
  ...FILESYSTEM_TOOLS,
  ...PATCH_TOOLS,
  ...CODEX_TOOLS,
  ...AUDIT_TOOLS,
  ...PTY_TOOLS,
];

function advertisedTools() {
  return ptyStatus().available ? TOOLS : TOOLS.filter((tool) => !tool.name.startsWith("pty_"));
}

// Re-read the unlock state before every tool call, so removing the unlock file
// is genuinely fail-closed.
//
// Checking it only at startup made `rm` of the file a no-op against a process
// already serving: it kept answering 200 with unrestricted shell until someone
// found and killed it. That turned containment into an external process-hunting
// problem, which is where three separate false-"disabled" bugs came from. The
// authority over "is full access permitted right now" belongs here, next to the
// tools it gates. One stat+read per call is nothing beside spawning a login shell.
//
// MAC_DEV_BRIDGE_FULL_ACCESS_ACK in the environment still unlocks, unchanged —
// but that is the operator's own process env, not a file anyone can revoke, so
// it is deliberately not a kill-switch surface.
// Foreground shell_exec children, so revocation can reclaim them.
const inFlightCommands = new Set();

function killInFlightCommands() {
  for (const child of inFlightCommands) {
    // Negative pid: the whole group, since runCommand spawns detached. The
    // pid > 1 guard is not paranoia: in JS -0 === 0, and process.kill(-0) signals
    // THIS process group, which on the tunnel transport contains tunnel-client —
    // so a spawn that failed to produce a pid would make the kill switch take out
    // its own supervisor. scripts/disable.sh refuses the same target for the same
    // reason.
    if (killProcessGroup(child.pid, "SIGKILL") !== null) {
      try {
        child.kill("SIGKILL");
      } catch {}
    }
  }
  inFlightCommands.clear();
}

// One guarded group kill for every reclaim path. Returns null on success, or the
// errno / reason string, so a caller can report honestly instead of assuming.
function killProcessGroup(pgid, signal) {
  if (!Number.isInteger(pgid) || pgid <= 1) return "INVALID_TARGET";
  try {
    process.kill(-pgid, signal);
    return null;
  } catch (error) {
    return error?.code || String(error?.message || error);
  }
}

// Verified by the same predicate the kill used: -pgid. Verifying containment by
// the helper's exit code instead is how this project shipped three "Disabled"
// verdicts it had not achieved.
const TRANSIENT_LATCH_ERRNOS = new Set(["EMFILE", "ENFILE", "EIO", "EAGAIN", "EINTR", "EBUSY", "ETIMEDOUT"]);

// One reader for the latch, shared by the per-call check and the idle recheck.
// Two copies of this errno taxonomy would be two chances to diverge, and a
// divergent kill-vs-verify predicate is the origin of every false "Disabled"
// verdict this project has shipped.
//
// Returns "unlocked", "revoked", or "unreadable" (transient: the caller should
// leave the current state alone rather than revoke on a momentary failure).
async function readUnlockLatch() {
  try {
    return (await fsp.readFile(FULL_ACCESS_UNLOCK_FILE, "utf8")).trim() === FULL_ACCESS_ACK ? "unlocked" : "revoked";
  } catch (error) {
    if (TRANSIENT_LATCH_ERRNOS.has(error?.code)) {
      stderr(`Unlock file read failed transiently (${error.code}); retrying once.`);
      try {
        await new Promise((r) => setTimeout(r, 10));
        return (await fsp.readFile(FULL_ACCESS_UNLOCK_FILE, "utf8")).trim() === FULL_ACCESS_ACK ? "unlocked" : "revoked";
      } catch (retryError) {
        if (TRANSIENT_LATCH_ERRNOS.has(retryError?.code)) {
          stderr(`Unlock file still unreadable (${retryError.code}); leaving the current state in place.`);
          return "unreadable";
        }
        return "revoked";
      }
    }
    // ENOENT, EISDIR, ELOOP, ENOTDIR, EACCES, ... all mean "not a readable
    // unlock file", which is indistinguishable from revocation. Revoke.
    stderr(`Unlock file is not readable (${error?.code || error}); treating as revoked.`);
    return "revoked";
  }
}

// The latch is only consulted per tool call, so an idle pty session generates no
// checks at all: without this interval, "removing the unlock file terminates live
// sessions" is false for exactly as long as the client stops calling. Armed while
// any session is live, disarmed when none is.
async function recheckUnlock() {
  if (FULL_ACCESS_ACK_FROM_ENV === FULL_ACCESS_ACK) return;
  if (unlockRecheckInFlight) return;
  unlockRecheckInFlight = true;
  try {
    const state = await readUnlockLatch();
    if (state === "unreadable") return;
    fullAccessUnlocked = state === "unlocked";
    if (state === "unlocked") return;
    const sessions = ptyStatus().sessions.filter((session) => !session.exited).map(({ id, leaderPid }) => ({ id, leaderPid }));
    stderr(`Full-access unlock revoked (${FULL_ACCESS_UNLOCK_FILE}); reclaiming ${sessions.length} pty session(s) and exiting.`);
    // Containment first here, unlike the per-call path: no response is pending on
    // this path, so there is nothing to flush and nothing to lose by killing before
    // the audit append. The audit is still awaited before exitAfterFlush, because
    // exitAfterFlush fires on an empty stdout via setImmediate and would otherwise
    // beat appendFile — and a revocation that leaves no trace is the one event that
    // must not.
    const reclaimed = teardownPty("revoked");
    killInFlightCommands();
    await audit("pty_unlock_recheck", {}, { revoked: true, sessions, reclaimed }, new Error("Full-access unlock has been revoked; the bridge is shutting down."));
    exitAfterFlush(78);
  } finally {
    unlockRecheckInFlight = false;
  }
}

async function assertStillUnlocked(tool, args) {
  if (FULL_ACCESS_ACK_FROM_ENV === FULL_ACCESS_ACK) return;
  const state = await readUnlockLatch();
  if (state === "unreadable") return;
  // Keep bridge_status honest: this field previously froze at the startup value
  // and would report `true` while the file was gone.
  const ok = state === "unlocked";
  fullAccessUnlocked = ok;

  if (!ok) {
    const message = "Full-access unlock has been revoked; the bridge is shutting down.";
    stderr(`Full-access unlock revoked (${FULL_ACCESS_UNLOCK_FILE}); refusing further tool calls and exiting.`);
    // Audit HERE, awaited, before scheduling the exit. Relying on the caller's
    // catch to audit lost the record entirely: exitAfterFlush fires on an empty
    // stdout via setImmediate, which can beat the caller's appendFile. A
    // revocation that leaves no audit trace is the one event that must not.
    await audit(tool ?? "unknown", args ?? {}, { revoked: true }, new Error(message));
    // Reclaim in-flight commands: exiting without this leaves an unrestricted
    // process running past its own timeout with nothing tracking it.
    //
    // Both reclaims are synchronous and sit between the decision and the exit on
    // purpose. exitAfterFlush can process.exit on the very next tick, so any await
    // inserted here is a window in which the bridge dies with a live pty still
    // holding an unrestricted shell.
    killInFlightCommands();
    teardownPty("revoked");
    // Exit so a supervisor restarts into the locked state where startup fails 78,
    // but only after the response has been flushed.
    exitAfterFlush(78);
    throw new Error(message);
  }
}

const context = { HOME, SHELL, JOB_DIR, DEFAULT_OUTPUT_BYTES, MAX_OUTPUT_BYTES, SHELL_EXEC_DEFAULT_TIMEOUT_MS, GUI_FOCUS_POLICY, readOperatorSettings, guiFocusRisk, consumeForegroundGuiApproval, normalizeEnv, optionalString, optionalInteger, optionalBoolean, optionalStringArray, requireString, requireInteger, resolvePath, crypto, fs, fsp, path, process, spawn, mergedEnv, nowIso, writeJobMetadata, readJobMetadata, processRunning, tailFile, killProcessGroup, audit, runCommand, CODEX_BIN, callCodexAppServer, AUDIT_LOG };
configurePty(context);

let unlockRecheckInFlight = false;
const unlockRecheckTimer = setInterval(() => {
  recheckUnlock().catch((error) => stderr(`unlock recheck failed: ${error?.message || error}`));
}, UNLOCK_RECHECK_MS);
unlockRecheckTimer.unref();

async function dispatchTool(name, args) {
  await assertStillUnlocked(name, args);
  switch (name) {
    case "bridge_status": {
      const status = {
        bridgeVersion: CORE_VERSION,
        pid: process.pid,
        hostname: os.hostname(),
        username: os.userInfo().username,
        uid: typeof process.getuid === "function" ? process.getuid() : null,
        gid: typeof process.getgid === "function" ? process.getgid() : null,
        home: HOME,
        platform: process.platform,
        architecture: process.arch,
        release: os.release(),
        node: process.version,
        shell: SHELL,
        codexBin: CODEX_BIN,
        tunnelRuntimeKeyScrubbedFromChildEnvironment: TUNNEL_RUNTIME_KEY_WAS_PRESENT,
        cwd: process.cwd(),
        dataDir: APP_SUPPORT_DIR,
        jobDir: JOB_DIR,
        auditLog: AUDIT_LOG,
        auditMode: AUDIT_MODE,
        guiFocusPolicy: GUI_FOCUS_POLICY,
        operatorSettings: await readOperatorSettings(),
        settingsFile: SETTINGS_FILE,
        foregroundGuiApproved: await foregroundGuiApprovalPresent(),
        fullAccessUnlocked,
        fullAccessUnlockFile: FULL_ACCESS_UNLOCK_FILE,
        ...(() => {
          const pty = ptyStatus();
          return {
            ptyAvailable: pty.available,
            ptyHelper: pty.helper,
            ptyLimits: { ...pty.limits, unlockRecheckMs: UNLOCK_RECHECK_MS },
            ptySessions: pty.sessions,
          };
        })(),
        // Built at read time from the live registry, never cached. fullAccessUnlocked
        // once froze at its startup value and reported `true` while the file was gone;
        // a cached session inventory would repeat that mistake with processes.
        accessModel: "No bridge sandbox or path allowlist. Effective access equals the macOS account running tunnel-client/this server, subject to macOS TCC, Full Disk Access, ACLs, and sudo authentication.",
      };
      await audit(name, args, { ok: true });
      return status;
    }

    case "shell_exec":
    case "shell_start":
    case "shell_job_status":
    case "shell_job_list":
    case "shell_job_kill": return handleShell(name, args, context);
    case "fs_read":
    case "fs_write":
    case "fs_list":
    case "fs_stat":
    case "fs_manage": return handleFilesystem(name, args, context);
    case "apply_patch": return handlePatch(name, args, context);
    case "codex_thread_read":
    case "codex_thread_list":
    case "codex_thread_turns_list": return handleCodex(name, args, context);
    case "audit_tail": return handleAudit(name, args, context);
    case "pty_start":
    case "pty_read":
    case "pty_write":
    case "pty_resize":
    case "pty_signal":
    case "pty_close": return handlePty(name, args, context);





















    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

async function handleMessage(message) {
  if (!message || typeof message !== "object") return;
  const id = message.id;
  const method = message.method;

  if (typeof method !== "string") {
    if (id !== undefined) sendError(id, -32600, "Invalid Request");
    return;
  }

  if (method === "notifications/initialized" || method === "initialized") {
    legacyInitialized = true;
    return;
  }
  if (method === "notifications/cancelled" || method === "notifications/cancelled_request") return;

  if (method === "server/discover") {
    sendResult(id, {
      resultType: "complete",
      supportedVersions: [MODERN_PROTOCOL, "2025-11-25", "2025-06-18"],
      capabilities: { tools: { listChanged: false } },
      instructions: "This Core runtime has unrestricted access under the host macOS user. Prefer codex_thread_read over invoking Codex model turns. Use shell_start for long-running commands. Browser work is owned by Browser Workspace rather than Core tools. Do not print secrets unless the user explicitly requests them.",
      ttlMs: 3_600_000,
      cacheScope: "private",
      _meta: resultMeta(),
    });
    return;
  }

  if (method === "initialize") {
    const requested = message?.params?.protocolVersion;
    // Local, not module-level: this value is only echoed in the response below.
    // As a module global it looked like session state that a transport would
    // need to restore after a restart, which it is not. Only legacyInitialized
    // survives a request.
    const negotiatedProtocol = LEGACY_PROTOCOLS.has(requested) ? requested : "2025-11-25";
    sendResult(id, {
      protocolVersion: negotiatedProtocol,
      capabilities: { tools: { listChanged: false } },
      serverInfo: serverInfo(),
      instructions: "This Core runtime runs without a filesystem sandbox or command allowlist. Effective permissions equal the macOS user running it. Prefer codex_thread_read for persisted Codex history without model usage. Browser work belongs to Browser Workspace; Core does not expose browser automation tools.",
    });
    return;
  }

  const modern = isModernRequest(message);
  if (!modern && !legacyInitialized && method !== "ping") {
    sendError(id, -32002, "Server not initialized");
    return;
  }

  if (method === "ping") {
    sendResult(id, completeResult({}, modern));
    return;
  }

  if (method === "tools/list") {
    // Await the self-test before answering. tools/list is cached by the client for
    // 300s and capabilities.tools.listChanged is false, so a tool set that changed
    // after the first answer would be wrong for five minutes with no way to correct
    // it. Free after the first call: the probe is a settled promise.
    await ptyReady;
    sendResult(id, completeResult(
      { tools: advertisedTools() },
      modern,
      modern ? { ttlMs: 300_000, cacheScope: "private" } : null,
    ));
    return;
  }

  if (method === "tools/call") {
    const name = message?.params?.name;
    const args = message?.params?.arguments ?? {};
    if (typeof name !== "string") {
      sendError(id, -32602, "Invalid params: tool name is required");
      return;
    }
    await ptyReady;
    // The same set tools/list advertised. A pty tool that is not advertised must be
    // -32601 here too: "advertised but fails at call time" and "callable but
    // unadvertised" are both ways of reporting a capability the host does not have.
    if (!advertisedTools().some((tool) => tool.name === name)) {
      sendError(id, -32601, `Unknown tool: ${name}`);
      return;
    }
    try {
      const value = await dispatchTool(name, args);
      // Discriminated escape for federated results. toolTextResult flattens
      // everything into one text block plus structuredContent, which is right for
      // the bridge's own 22 tools and destroys image, audio and resource content
      // coming back from a child MCP server — a screenshot is two blocks, and the
      // second one is the picture. toolTextResult stays byte-identical for
      // everything that is not a federated result.
      sendResult(id, value && typeof value === "object" && Array.isArray(value.__mcpContent)
        ? completeResult(
          {
            content: value.__mcpContent,
            ...(value.__structured === undefined ? {} : { structuredContent: value.__structured }),
            isError: Boolean(value.__isError),
            ...(value.__meta === undefined ? {} : { _meta: value.__meta }),
          },
          modern,
        )
        : toolTextResult(value, { modern }));
    } catch (error) {
      stderr(`tool ${name} failed: ${error?.stack || error}`);
      await audit(name, args, {}, error);
      // Include `code`. The pty taxonomy (PTY_WRITE_CANON_LIMIT and 14 others) was
      // built, documented in README, and then discarded here — no client could ever see
      // one, and the tests had to regex English prose instead. `name` is dropped: it was
      // always the literal "Error", since these are plain Error objects. Federated tool
      // errors already carry a code, so without this the bridge's own tools and its
      // proxied tools returned differently shaped error envelopes.
      sendResult(id, toolTextResult(
        { error: String(error?.message || error), ...(error?.code ? { code: error.code } : {}) },
        { isError: true, modern },
      ));
    }
    return;
  }

  sendError(id, -32601, `Method not found: ${method}`);
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let message;
  try {
    message = JSON.parse(trimmed);
  } catch (error) {
    sendError(null, -32700, "Parse error", { detail: String(error?.message || error) });
    return;
  }
  handleMessage(message).catch((error) => {
    stderr(`unhandled request error: ${error?.stack || error}`);
    if (message?.id !== undefined) sendError(message.id, -32603, "Internal error", { detail: String(error?.message || error) });
  });
});

function teardownAll(reason) {
  try {
    teardownPty(reason);
  } catch (error) {
    stderr(`pty teardown failed: ${error?.message || error}`);
  }
  try {
    killInFlightCommands();
  } catch (error) {
    stderr(`in-flight teardown failed: ${error?.message || error}`);
  }
}

// All three exited with no cleanup, and detached pty groups survive every one.
// SIGTERM is exactly what scripts/disable.sh sends, and mcp-http.mjs sends it to
// this child on its own shutdown, so this path runs in normal operation: without
// teardownAll, disable.sh reclaimed the bridge and printed its containment verdict
// while the pty shells kept running.
rl.on("close", () => {
  teardownAll("transport_closed");
  process.exit(0);
});
process.on("SIGTERM", () => {
  teardownAll("sigterm");
  process.exit(0);
});
process.on("SIGINT", () => {
  teardownAll("sigint");
  process.exit(0);
});
process.on("uncaughtException", (error) => stderr(`uncaught exception: ${error?.stack || error}`));
process.on("unhandledRejection", (error) => stderr(`unhandled rejection: ${error?.stack || error}`));

stderr(`${SERVER_NAME} ${CORE_VERSION} started (pid ${process.pid}, audit=${AUDIT_MODE})`);
