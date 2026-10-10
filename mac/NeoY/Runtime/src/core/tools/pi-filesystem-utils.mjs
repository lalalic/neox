// Adapted from @mariozechner/pi-coding-agent 0.73.1 filesystem tools.
// Original project: https://github.com/badlogic/pi-mono (MIT, Copyright 2025 Mario Zechner).
import { createHash } from "node:crypto";
import { constants as fsConstants, realpathSync } from "node:fs";
import * as fsp from "node:fs/promises";
import { arch, platform } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

export const PI_MAX_RESULT_BYTES = 50 * 1024;
export const PI_GREP_MAX_LINE_LENGTH = 500;

const TOOLS = {
  rg: {
    binary: "rg",
    systemNames: ["rg"],
    assets: {
      arm64: {
        url: "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz",
        sha256: "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4",
      },
      x64: {
        url: "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-apple-darwin.tar.gz",
        sha256: "af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1",
      },
    },
  },
  fd: {
    binary: "fd",
    systemNames: ["fd", "fdfind"],
    assets: {
      arm64: {
        url: "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-apple-darwin.tar.gz",
        sha256: "b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12",
      },
      x64: {
        url: "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-x86_64-apple-darwin.tar.gz",
        sha256: "7e31028c62c6955877735d0406807aa484c2a5e6f86235a59e26c29c301da590",
      },
    },
  },
};

const downloads = new Map();
const mutationQueues = new Map();

function commandExists(command) {
  const result = spawnSync(command, ["--version"], { stdio: "ignore" });
  return !result.error && result.status === 0;
}

async function findBinary(root, binary) {
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    for (const entry of await fsp.readdir(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isFile() && entry.name === binary) return full;
      if (entry.isDirectory()) stack.push(full);
    }
  }
  return null;
}

async function downloadTool(name, toolsDir) {
  const config = TOOLS[name];
  if (!config) throw new Error(`Unknown native tool: ${name}`);
  if (platform() !== "darwin") throw new Error(`${name} auto-install is only supported on macOS`);
  const asset = config.assets[arch()];
  if (!asset) throw new Error(`${name} auto-install is unsupported on architecture ${arch()}`);

  await fsp.mkdir(toolsDir, { recursive: true, mode: 0o700 });
  const binaryPath = path.join(toolsDir, config.binary);
  const tempRoot = await fsp.mkdtemp(path.join(toolsDir, `.${name}-`));
  const archivePath = path.join(tempRoot, "tool.tar.gz");
  const extractPath = path.join(tempRoot, "extract");
  try {
    const response = await fetch(asset.url, { signal: AbortSignal.timeout(120_000) });
    if (!response.ok) throw new Error(`download failed with HTTP ${response.status}`);
    const archive = Buffer.from(await response.arrayBuffer());
    const digest = createHash("sha256").update(archive).digest("hex");
    if (digest !== asset.sha256) throw new Error(`SHA-256 mismatch for ${name}`);
    await fsp.writeFile(archivePath, archive, { mode: 0o600 });
    await fsp.mkdir(extractPath, { mode: 0o700 });
    const extracted = spawnSync("/usr/bin/tar", ["xzf", archivePath, "-C", extractPath], { stdio: "pipe" });
    if (extracted.error || extracted.status !== 0) {
      throw new Error(extracted.error?.message || extracted.stderr?.toString().trim() || `tar exited ${extracted.status}`);
    }
    const found = await findBinary(extractPath, config.binary);
    if (!found) throw new Error(`${config.binary} not found in downloaded archive`);
    const staged = `${binaryPath}.${process.pid}.tmp`;
    await fsp.copyFile(found, staged);
    await fsp.chmod(staged, 0o755);
    await fsp.rename(staged, binaryPath);
    return binaryPath;
  } finally {
    await fsp.rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}

export async function ensurePiNativeTool(name, toolsDir) {
  const config = TOOLS[name];
  if (!config) throw new Error(`Unknown native tool: ${name}`);
  const localPath = path.join(toolsDir, config.binary);
  try {
    await fsp.access(localPath, fsConstants.X_OK);
    return localPath;
  } catch {}
  for (const command of config.systemNames) {
    if (commandExists(command)) return command;
  }
  if (process.env.NEO_CORE_OFFLINE === "1") throw new Error(`${name} is unavailable while NEO_CORE_OFFLINE=1`);
  if (!downloads.has(name)) downloads.set(name, downloadTool(name, toolsDir).finally(() => downloads.delete(name)));
  return downloads.get(name);
}

export function truncatePiLine(line, maxChars = PI_GREP_MAX_LINE_LENGTH) {
  if (line.length <= maxChars) return { text: line, truncated: false };
  return { text: `${line.slice(0, maxChars)}... [truncated]`, truncated: true };
}

export function appendWithinByteLimit(items, item, bytesRef, maxBytes = PI_MAX_RESULT_BYTES) {
  const bytes = Buffer.byteLength(typeof item === "string" ? item : JSON.stringify(item), "utf8");
  if (bytesRef.value + bytes > maxBytes) return false;
  items.push(item);
  bytesRef.value += bytes;
  return true;
}

function mutationKey(filePath) {
  const resolved = path.resolve(filePath);
  try { return realpathSync.native(resolved); }
  catch { return resolved; }
}

export async function withPiFileMutationQueue(filePath, fn) {
  const key = mutationKey(filePath);
  const current = mutationQueues.get(key) || Promise.resolve();
  let release;
  const next = new Promise((resolve) => { release = resolve; });
  const chained = current.then(() => next);
  mutationQueues.set(key, chained);
  await current;
  try { return await fn(); }
  finally {
    release();
    if (mutationQueues.get(key) === chained) mutationQueues.delete(key);
  }
}
