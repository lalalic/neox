import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { XCHAT_LIFECYCLE_TOOLS, isXChatLifecycleTool, scheduleXChatLifecycle } from "../src/core/tools/xchat.mjs";

const call = (command, args = {}, options = {}) => scheduleXChatLifecycle("chatgpt", { command, args }, options);

test("declares one compact xchat lifecycle tool with exact help schemas", () => {
  assert.deepEqual(XCHAT_LIFECYCLE_TOOLS.map((tool) => tool.name), ["chatgpt"]);
  assert.deepEqual(XCHAT_LIFECYCLE_TOOLS[0].inputSchema.required, ["command"]);
  const payload = JSON.parse(call("help", { command: "turn" }).content[0].text);
  assert.deepEqual(payload.schema.required, ["thread_id", "message"]);
  assert.equal(XCHAT_LIFECYCLE_TOOLS[0].inputSchema.additionalProperties, false);
});

test("schedules same-thread Browser Workspace transfer", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "neoy-xchat-turn-"));
  let observed;
  const result = call("turn", {
    project_id: "g-p-12345678",
    thread_id: "thread_12345678",
    message: "Continue after refreshing the tool surface.",
    reason: "plugin tools changed",
  }, {
    dataDir: dir,
    transferId: "turn-1",
    spawnImpl: (command, args, options) => { observed = { command, args, options }; return { unref() {} }; },
    workerPath: "/tmp/worker.mjs",
  });
  const payload = JSON.parse(result.content[0].text);
  assert.equal(payload.status, "scheduled");
  assert.equal(payload.terminal, true);
  assert.equal(payload.mode, "new-turn");
  assert.equal(observed.args[1], "new-turn");
  assert.ok(fs.existsSync(path.join(dir, "xchat-lifecycle", "turn-1.json")));
});

test("schedules standalone same-thread transfer without project_id", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "neoy-xchat-turn-standalone-"));
  const result = call("turn", {
    thread_id: "thread_12345678",
    message: "Continue in the standalone thread.",
  }, { dataDir: dir, transferId: "turn-standalone", spawnImpl: () => ({ unref() {} }), workerPath: "/tmp/worker.mjs" });
  const payload = JSON.parse(result.content[0].text);
  assert.equal(payload.thread_id, "thread_12345678");
  assert.equal("project_id" in payload, false);
});

test("schedules new-thread transfer including temporary mode", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "neoy-xchat-thread-"));
  const result = call("thread", {
    message: "Check the refreshed tool surface.",
    temporary: true,
  }, { dataDir: dir, transferId: "temporary-1", spawnImpl: () => ({ unref() {} }), workerPath: "/tmp/worker.mjs" });
  const payload = JSON.parse(result.content[0].text);
  assert.equal(payload.mode, "new-thread");
  assert.equal(payload.temporary, true);
  assert.equal("project_id" in payload, false);

  assert.throws(() => call("thread", {
    project_id: "g-p-12345678",
    temporary: true,
    message: "x",
  }, { dataDir: dir, transferId: "temporary-invalid", spawnImpl: () => ({ unref() {} }), workerPath: "/tmp/worker.mjs" }), /cannot be combined/);
});

test("validates stable ids and facade commands", () => {
  assert.equal(isXChatLifecycleTool("chatgpt"), true);
  assert.equal(isXChatLifecycleTool("xchat.turn.new"), false);
  assert.throws(() => call("turn", { project_id: "bad", thread_id: "thread_12345678", message: "x" }), /project_id/);
  assert.throws(() => call("turn", { thread_id: "bad", message: "x" }), /thread_id/);
  assert.throws(() => call("nope", {}), /Unknown chatgpt command/);
});


test("worker invokes uvx with browser-workspace and does not require npm or local source", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "neoy-xchat-uvx-"));
  const config = path.join(dir, "config.json");
  const status = path.join(dir, "transfer.status.json");
  const fakeBin = path.join(dir, "uvx");
  const argvPath = path.join(dir, "argv.json");
  fs.writeFileSync(config, JSON.stringify({ message: "test" }));
  fs.writeFileSync(fakeBin, `#!/bin/sh\nprintf '%s\\n' "$@" > "${argvPath}"\nprintf '{"ok":true}\\n'\n`, { mode: 0o755 });
  const worker = fileURLToPath(new URL("../src/core/tools/xchat.mjs", import.meta.url));
  const ran = spawnSync(process.execPath, [worker, "new-turn", config, status], {
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, BROWSER_WORKSPACE_CLI: "", XCHAT_LIFECYCLE_TIMEOUT_MS: "2000" },
    encoding: "utf8",
  });
  assert.equal(ran.status, 0, ran.stderr);
  assert.deepEqual(fs.readFileSync(argvPath, "utf8").trim().split("\n"), [
    "browser-workspace", "platform", "run", "chatgpt", "new-turn", "--auto-session", "--config", config,
  ]);
  assert.equal(JSON.parse(fs.readFileSync(status, "utf8")).status, "completed");
  assert.equal(fs.existsSync(config), false);
});


test("context is discoverable and explicitly unavailable without verified caller binding", () => {
  const help = JSON.parse(call("help").content[0].text);
  assert.ok(help.commands.some((item) => item.command === "context"));
  const schema = JSON.parse(call("help", { command: "context" }).content[0].text);
  assert.deepEqual(schema.schema.properties, {});
  const context = JSON.parse(call("context").content[0].text);
  assert.deepEqual(context, { available: false, thread_id: null, project_id: null, verified: false, reason: "caller_context_unavailable" });
  assert.throws(() => call("context", { thread_id: "thread_12345678" }), /no arguments/);
  assert.deepEqual(JSON.parse(call("context").content[0].text), context);
});
