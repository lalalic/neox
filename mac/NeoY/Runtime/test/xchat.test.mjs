import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
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
