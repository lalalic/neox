import test from 'node:test';
import assert from 'node:assert/strict';
import { PATCH_TOOLS, handlePatch } from '../src/core/tools/patch.mjs';

const unified = 'diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n';
const codex = '*** Begin Patch\n*** Update File: file.txt\n@@\n-before\n+after\n*** End Patch\n';
function fixture() {
  const calls = [];
  return { calls, context: {
    DEFAULT_OUTPUT_BYTES: 4096,
    requireString(args, key) { if (typeof args[key] !== 'string' || !args[key]) throw new Error(`missing ${key}`); return args[key]; },
    optionalBoolean(args, key, fallback) { return args[key] ?? fallback; },
    runCommand: async (args) => { calls.push(args); return { exitCode: 0, durationMs: 1, stderr: '', stdout: '' }; },
    audit: async () => {},
  } };
}
test('publishes only explicit Git patch contract', () => {
  assert.equal(PATCH_TOOLS[0].name, 'apply_file_patch');
  assert.deepEqual(PATCH_TOOLS[0].inputSchema.required, ['patch', 'cwd']);
  assert.match(PATCH_TOOLS[0].description, /Begin Patch/);
});
test('accepts unified Git diff and runs git apply in cwd', async () => {
  const { calls, context } = fixture();
  const result = await handlePatch('apply_file_patch', { patch: unified, cwd: '/tmp', check_only: true }, context);
  assert.equal(result.exitCode, 0);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].cwd, '/tmp');
  assert.equal(calls[0].stdin, unified);
  assert.match(calls[0].command, /--check/);
});
test('rejects Codex patch before execution', async () => {
  const { calls, context } = fixture();
  const result = await handlePatch('apply_file_patch', { patch: codex, cwd: '/tmp' }, context);
  assert.equal(result.error.code, 'INVALID_PATCH_FORMAT');
  assert.equal(calls.length, 0);
});
test('requires cwd and rejects patch without hunks', async () => {
  const { calls, context } = fixture();
  await assert.rejects(handlePatch('apply_file_patch', { patch: unified }, context), /cwd/);
  const result = await handlePatch('apply_file_patch', { patch: 'diff --git a/x b/x\n', cwd: '/tmp' }, context);
  assert.equal(result.error.code, 'INVALID_PATCH_FORMAT');
  assert.equal(calls.length, 0);
});
