import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const diff = 'diff --git a/no-such-file.txt b/no-such-file.txt\n--- a/no-such-file.txt\n+++ b/no-such-file.txt\n@@ -1 +1 @@\n-old\n+new\n';
async function callCore(args) {
  const messages = [
    { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25' } },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'apply_file_patch', arguments: args } },
  ];
  const child = spawn(process.execPath, [new URL('../src/core/tools/index.mjs', import.meta.url).pathname], {
    env: { ...process.env, NEO_CORE_FULL_ACCESS_ACK: 'I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS' },
  });
  return await new Promise((resolve, reject) => {
    let pending = '';
    const timer = setTimeout(() => { child.kill(); reject(new Error('Core MCP response timed out')); }, 5000);
    child.stdout.on('data', (chunk) => {
      pending += chunk.toString();
      while (pending.includes('\n')) {
        const split = pending.indexOf('\n');
        const line = pending.slice(0, split);
        pending = pending.slice(split + 1);
        if (!line) continue;
        const row = JSON.parse(line);
        if (row.id === 2) {
          clearTimeout(timer);
          child.kill();
          resolve(row);
          return;
        }
      }
    });
    child.on('error', (error) => { clearTimeout(timer); reject(error); });
    child.on('exit', (code) => { if (code !== null && code !== 0) { clearTimeout(timer); reject(new Error(`Core exited ${code}`)); } });
    child.stdin.write(messages.map((message) => JSON.stringify(message)).join('\n') + '\n');
  });
}

test('MCP rejects missing required patch and cwd before handler', async () => {
  const missingBoth = await callCore({});
  assert.equal(missingBoth.error.code, -32602);
  assert.deepEqual(missingBoth.error.data.missing, ['patch', 'cwd']);
  const missingCwd = await callCore({ patch: diff });
  assert.equal(missingCwd.error.code, -32602);
  assert.deepEqual(missingCwd.error.data.missing, ['cwd']);
});

test('MCP marks failed git apply as error while preserving exitCode', async () => {
  const failed = await callCore({ patch: diff, cwd: '/tmp', check_only: true });
  assert.equal(failed.result.isError, true);
  assert.equal(failed.result.structuredContent.exitCode, 1);
});
