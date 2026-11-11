#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const nodeCore = process.argv[2];
if (!nodeCore) {
  process.stderr.write("Usage: node scripts/update-node-contract-fixtures.mjs PATH_TO_NODE_CORE_INDEX_MJS\n");
  process.exit(2);
}

const dataDir = await mkdtemp(path.join(os.tmpdir(), "neoy-node-help-"));
const child = spawn(process.execPath, [path.resolve(nodeCore)], {
  env: {
    ...process.env,
    NEO_CORE_DATA_DIR: dataDir,
    NEO_CORE_FULL_ACCESS_ACK: "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
  },
  stdio: ["pipe", "pipe", "ignore"],
});
const lines = createInterface({ input: child.stdout });
let id = 0;
const pending = new Map();
lines.on("line", (line) => {
  try {
    const message = JSON.parse(line);
    if (!pending.has(message.id)) return;
    const resolve = pending.get(message.id);
    pending.delete(message.id);
    resolve(message);
  } catch {}
});

function request(method, params = {}) {
  const requestId = ++id;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`Timed out waiting for ${method}`));
    }, 5_000);
    pending.set(requestId, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: requestId, method, params })}\n`);
  });
}

try {
  await request("initialize", { protocolVersion: "2025-11-25" });
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
  const listed = await request("tools/list");
  if (!Array.isArray(listed.result?.tools)) throw new Error("Node Core returned no tools/list inventory");
  const fixture = {};
  for (const facade of ["shell", "fs", "codex", "discord", "terminal", "chatgpt"]) {
    const help = await request("tools/call", {
      name: facade,
      arguments: { command: "help" },
    });
    const value = help.result?.structuredContent;
    if (!value) throw new Error(`Node Core returned no help for ${facade}`);
    fixture[facade] = { help: value, named: {} };
    for (const item of value.commands || []) {
      const named = await request("tools/call", {
        name: facade,
        arguments: { command: "help", args: { command: item.command } },
      });
      const namedValue = named.result?.structuredContent;
      if (!namedValue) throw new Error(`Node Core returned no help for ${facade}.${item.command}`);
      fixture[facade].named[item.command] = namedValue;
    }
  }
  await mkdir(path.join(root, "fixtures"), { recursive: true });
  await writeFile(path.join(root, "fixtures/node-help.json"), `${JSON.stringify(fixture, null, 2)}\n`);
  await writeFile(path.join(root, "fixtures/node-tools.json"), `${JSON.stringify(listed.result.tools, null, 2)}\n`);
} finally {
  child.kill("SIGTERM");
  await new Promise((resolve) => child.once("exit", resolve));
  await rm(dataDir, { recursive: true, force: true });
}
