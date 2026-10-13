import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import * as fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { FILESYSTEM_TOOLS, handleFilesystem } from "../src/core/tools/filesystem.mjs";
import { withPiFileMutationQueue } from "../src/core/tools/pi-filesystem-utils.mjs";

function context() {
  return {
    resolvePath: (value) => path.resolve(value),
    fsp, crypto, path, process,
    audit: async () => {},
    APP_SUPPORT_DIR: path.join(os.tmpdir(), "neoy-fs-test-data"),
  };
}

test("filesystem exposes edit, grep, and find as fs subcommands", () => {
  const names = new Set(FILESYSTEM_TOOLS.map((tool) => tool.name));
  assert.ok(names.has("fs_edit"));
  assert.ok(names.has("fs_grep"));
  assert.ok(names.has("fs_find"));
});

test("fs_edit applies multiple unique replacements atomically and preserves CRLF", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-fs-edit-"));
  const file = path.join(dir, "sample.txt");
  await fsp.writeFile(file, "alpha\r\nbeta\r\ngamma\r\n", "utf8");
  const result = await handleFilesystem("fs_edit", {
    path: file,
    edits: [
      { old_text: "alpha", new_text: "ALPHA" },
      { old_text: "gamma", new_text: "GAMMA" },
    ],
  }, context());
  assert.equal(result.replacements, 2);
  assert.equal(result.atomic, true);
  assert.equal(await fsp.readFile(file, "utf8"), "ALPHA\r\nbeta\r\nGAMMA\r\n");
  await fsp.rm(dir, { recursive: true, force: true });
});

test("fs_edit rejects ambiguous replacement text", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-fs-edit-"));
  const file = path.join(dir, "sample.txt");
  await fsp.writeFile(file, "same\nsame\n", "utf8");
  await assert.rejects(
    handleFilesystem("fs_edit", { path: file, edits: [{ old_text: "same", new_text: "new" }] }, context()),
    /2 occurrences/,
  );
  await fsp.rm(dir, { recursive: true, force: true });
});

test("same-file mutation queue serializes writers while different files remain independent", async () => {
  const events = [];
  let releaseFirst;
  const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
  const first = withPiFileMutationQueue("/tmp/neoy-same-file", async () => {
    events.push("first:start");
    await firstGate;
    events.push("first:end");
  });
  const second = withPiFileMutationQueue("/tmp/neoy-same-file", async () => {
    events.push("second:start");
    events.push("second:end");
  });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(events, ["first:start"]);
  releaseFirst();
  await Promise.all([first, second]);
  assert.deepEqual(events, ["first:start", "first:end", "second:start", "second:end"]);
});

test("fs_read supports line ranges and camelCase compatibility aliases", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "neoy-fs-read-lines-"));
  const file = path.join(dir, "sample.txt");
  await fsp.writeFile(file, "one\ntwo\nthree\nfour\n", "utf8");
  const base = { ...context(), DEFAULT_OUTPUT_BYTES: 1_000_000, MAX_OUTPUT_BYTES: 64_000_000,
    optionalString: (args, key, fallback) => args[key] ?? fallback,
    optionalInteger: (args, key, fallback) => args[key] ?? fallback,
    requireString: (args, key) => args[key],
  };
  const snake = await handleFilesystem("fs_read", { path: file, start_line: 2, end_line: 3 }, base);
  assert.equal(snake.content, "two\nthree\n");
  const camel = await handleFilesystem("fs_read", { path: file, startLine: 3, endLine: 4 }, base);
  assert.equal(camel.content, "three\nfour\n");
  const grepSchema = FILESYSTEM_TOOLS.find((tool) => tool.name === "fs_grep").inputSchema;
  assert.equal(grepSchema.properties.context.maximum, 20);
  await fsp.rm(dir, { recursive: true, force: true });
});
