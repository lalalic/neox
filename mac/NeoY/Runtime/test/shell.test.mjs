import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

import { handleShell } from "../src/core/tools/shell.mjs";

async function makeContext(root, overrides = {}) {
  const jobs = path.join(root, "jobs");
  await fsp.mkdir(jobs, { recursive: true });
  const metadata = async (value) => {
    const file = path.join(jobs, `${value.id}.json`);
    await fsp.writeFile(`${file}.tmp`, `${JSON.stringify(value)}\n`);
    await fsp.rename(`${file}.tmp`, file);
  };
  return {
    HOME: root,
    SHELL: "/bin/sh",
    JOB_DIR: jobs,
    DEFAULT_OUTPUT_BYTES: 100_000,
    MAX_OUTPUT_BYTES: 1_000_000,
    SHELL_EXEC_DEFAULT_TIMEOUT_MS: 10_000,
    GUI_FOCUS_POLICY: "background-first",
    readOperatorSettings: async () => ({ strictApprovals: false }),
    guiFocusRisk: () => null,
    consumeForegroundGuiApproval: async () => null,
    normalizeEnv: (value) => value || {},
    optionalString: (args, key, fallback) => args?.[key] ?? fallback,
    optionalInteger: (args, key, fallback) => args?.[key] ?? fallback,
    resolvePath: (value) => path.resolve(root, value),
    validateWorkingDirectory: async (cwd) => {
      const stat = await fsp.stat(cwd);
      if (!stat.isDirectory()) throw new Error(`Working directory '${cwd}' is not a directory`);
    },
    crypto,
    fs,
    fsp,
    path,
    spawn,
    mergedEnv: (env) => ({ ...process.env, ...env }),
    nowIso: () => new Date().toISOString(),
    writeJobMetadata: metadata,
    readJobMetadata: async (id) => JSON.parse(await fsp.readFile(path.join(jobs, `${id}.json`), "utf8")),
    processRunning: (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } },
    tailFile: async (file) => ({ text: await fsp.readFile(file, "utf8"), size: 0, returnedBytes: 0, truncated: false }),
    killProcessGroup: (pid, signal) => { try { process.kill(-pid, signal); return null; } catch (error) { return error?.code || String(error); } },
    audit: async () => {},
    runCommand: async () => ({}),
    requireString: (args, key) => {
      if (typeof args?.[key] !== "string" || args[key].length === 0) throw new Error(`'${key}' must be a non-empty string`);
      return args[key];
    },
    ...overrides,
  };
}

async function waitForExit(context, id) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await handleShell("shell_job_status", { job_id: id }, context);
    if (result.finishedAt) return result;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("job did not finish");
}

test("shell_start records output and the child's exit code", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-shell-"));
  const context = await makeContext(root);
  const started = await handleShell("shell_start", {
    command: "printf out; printf err >&2; exit 7",
    label: "regression",
  }, context);
  const finished = await waitForExit(context, started.id);

  assert.equal(finished.exitCode, 7);
  assert.equal(finished.signal, null);
  assert.match(finished.stdout.text, /out/);
  assert.match(finished.stderr.text, /err/);
  assert.equal(finished.running, false);
});

test("shell_start rejects a missing cwd before spawning", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-shell-"));
  const context = await makeContext(root);
  await assert.rejects(
    () => handleShell("shell_start", { command: "echo never", cwd: "missing" }, context),
    /ENOENT|unusable/,
  );
  assert.deepEqual((await fsp.readdir(context.JOB_DIR)).sort(), []);
});

test("shell_start cleans log files when the shell cannot spawn", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-shell-"));
  const context = await makeContext(root, { SHELL: "/definitely/missing-shell" });
  await assert.rejects(
    () => handleShell("shell_start", { command: "echo never" }, context),
    /ENOENT|spawn/,
  );
  assert.deepEqual((await fsp.readdir(context.JOB_DIR)).sort(), []);
});

test("shell_job_kill preserves the terminating signal", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-shell-"));
  const context = await makeContext(root);
  const started = await handleShell("shell_start", { command: "sleep 10", label: "kill" }, context);
  const killed = await handleShell("shell_job_kill", { job_id: started.id }, context);
  assert.equal(killed.killed, true);
  const finished = await waitForExit(context, started.id);
  assert.equal(finished.signal, "SIGTERM");
  assert.equal(finished.exitCode, null);
});

test("shell_start persists exit when child finishes before metadata write", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-shell-fast-"));
  const base = await makeContext(root);
  const originalWrite = base.writeJobMetadata;
  const context = { ...base, writeJobMetadata: async (value) => {
    if (!value.finishedAt) await new Promise((resolve) => setTimeout(resolve, 60));
    return originalWrite(value);
  }};
  try {
    const started = await handleShell("shell_start", { command: "exit 17" }, context);
    const finished = await waitForExit(context, started.id);
    assert.equal(finished.exitCode, 17);
    assert.ok(finished.finishedAt);
  } finally {
    await fsp.rm(root, { recursive: true, force: true });
  }
});

test("shell_start kills an unrecordable child and removes orphan logs", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-shell-fail-"));
  let killed = false;
  const base = await makeContext(root);
  const context = { ...base,
    writeJobMetadata: async () => { throw new Error("metadata storage unavailable"); },
    killProcessGroup: (pid, signal) => {
      killed = true;
      return base.killProcessGroup(pid, signal);
    },
  };
  try {
    await assert.rejects(
      () => handleShell("shell_start", { command: "sleep 20" }, context),
      /Could not record job metadata/,
    );
    assert.equal(killed, true);
    assert.deepEqual(await fsp.readdir(context.JOB_DIR), []);
  } finally {
    await fsp.rm(root, { recursive: true, force: true });
  }
});

test("shell_exec spills large output to system temp and retains full content", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-spill-test-"));
  const context = await makeContext(root);
  const result = await handleShell("shell_exec", { command: "yes x | head -c 2000", max_output_bytes: 512 }, context);
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdoutFile !== null, true);
  assert.equal(result.capturedStdoutBytes, 2000);
  assert.equal((await fsp.readFile(result.stdoutFile)).length, 2000);
  assert.equal(result.stdout.length, 512);
  assert.ok(result.stdoutFile.startsWith(os.tmpdir()));
});

test("shell_exec promotes the existing process without restart", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-promote-test-"));
  const context = await makeContext(root, { SHELL_PROMOTION_MS: 80 });
  const result = await handleShell("shell_exec", { command: "sleep 2" }, context);
  assert.equal(result.status, "running");
  const metadata = await context.readJobMetadata(result.jobId);
  assert.equal(metadata.pid, result.pid);
  await handleShell("shell_job_kill", { job_id: result.jobId }, context);
});

test("shell_exec passes stdin through the durable process supervisor", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-stdin-test-"));
  const context = await makeContext(root);
  const result = await handleShell("shell_exec", { command: "cat", stdin: "hello stdin" }, context);
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, "hello stdin");
});

test("shell_exec audits failed commands with original arguments, job ID and stderr diagnostic", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-diagnostics-test-"));
  const calls = [];
  const context = await makeContext(root, { audit: async (name, args, summary) => calls.push({ name, args, summary }) });
  const command = "printf 'failure detail' >&2; exit 17";
  const result = await handleShell("shell_exec", { command }, context);
  assert.equal(result.exitCode, 17);
  const event = calls.find(call => call.name === "shell_exec" && call.summary.exitCode === 17);
  assert.equal(event.args.command, command);
  assert.ok(event.summary.jobId);
  assert.equal(event.summary.stderrPreview, "failure detail");
});

test("shell_exec wait expiry preserves process and exposes the same durable job", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-wait-test-"));
  try {
    const context = await makeContext(root);
    const marker = path.join(root, "marker");
    const result = await handleShell("shell_exec", { command: `sleep 0.2; echo done > '${marker}'`, timeout: 10 }, context);
    assert.equal(result.status, "running");
    assert.ok(result.jobId);
    assert.equal(result.timedOut, undefined);
    await new Promise(resolve => setTimeout(resolve, 450));
    assert.equal((await fsp.readFile(marker, "utf8")).trim(), "done");
    const metadata = await context.readJobMetadata(result.jobId);
    assert.equal(metadata.exitCode, 0);
  } finally { await fsp.rm(root, { recursive: true, force: true }); }
});

test("shell_exec timeout=0 returns a running job immediately", async () => {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-nowait-test-"));
  const context = await makeContext(root);
  try {
    const result = await handleShell("shell_exec", { command: "sleep 3", timeout: 0 }, context);
    assert.equal(result.status, "running");
    assert.ok(result.jobId);
    await handleShell("shell_job_kill", { job_id: result.jobId }, context);
    await new Promise(resolve => setTimeout(resolve, 150));
  } finally { await fsp.rm(root, { recursive: true, force: true }); }
});
