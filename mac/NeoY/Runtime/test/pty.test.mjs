import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import fs from "node:fs/promises";
import path from "node:path";
import { configurePty, handlePty, ptyReady } from "../src/core/tools/pty.mjs";

test("PTY requires an initialized job directory", () => {
  assert.throws(() => configurePty({}), /PTY job directory is not configured/);
  assert.doesNotThrow(() => configurePty({ JOB_DIR: os.tmpdir() }));
});

test("real PTY lifecycle exercises job metadata path", async (t) => {
  if (!(await ptyReady)) return t.skip("PTY helper unavailable");
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "neoy-pty-"));
  const context = {
    HOME: root, JOB_DIR: root,
    requireString: (a, k) => { if (!a?.[k]) throw new Error(k + " required"); return a[k]; },
    optionalString: (a, k, d) => a?.[k] ?? d,
    optionalStringArray: (a, k, d) => a?.[k] ?? d,
    optionalInteger: (a, k, d) => a?.[k] ?? d,
    optionalBoolean: (a, k, d) => a?.[k] ?? d,
    normalizeEnv: v => v ?? {},
    mergedEnv: v => ({ ...process.env, ...v }),
    resolvePath: v => path.resolve(root, v),
    audit: async () => {},
    writeJobMetadata: async (data) => fs.writeFile(path.join(root, data.id + ".json"), JSON.stringify(data)),
  };
  configurePty(context);
  let id;
  try {
    const started = await handlePty("pty_start", { command: "/bin/sh", args: ["-i"], cwd: root }, context);
    id = started.sessionId;
    assert.match(id, /^pty_/);
    const initial = await handlePty("pty_read", { session_id: id, cursor: 0 }, context);
    await handlePty("pty_write", { session_id: id, data: "echo neoy_pty_test\n" }, context);
    let cursor = initial.nextCursor;
    let text = "";
    const deadline = Date.now() + 1500;
    while (!text.includes("neoy_pty_test") && Date.now() < deadline) {
      const output = await handlePty("pty_read", { session_id: id, cursor, wait_ms: 100 }, context);
      cursor = output.nextCursor;
      text += output.text;
    }
    assert.match(text, /neoy_pty_test/);
  } finally {
    if (id) await handlePty("pty_close", { session_id: id, force: true }, context);
    await fs.rm(root, { recursive: true, force: true });
  }
});
