import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { handleAudit } from '../src/core/tools/audit.mjs';

test('audit_tail filters tool quality telemetry', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-audit-'));
  const log = path.join(dir, 'audit.jsonl');
  const entries = [
    { event: 'tool_input_error', category: 'missing_parameter', tool: 'chatgpt', command: 'thread' },
    { event: 'tool_input_error', category: 'wrong_type', tool: 'fs', command: 'read' },
    { event: 'platform_rejection', category: 'auth_error', tool: null, platform: 'chatgpt' },
  ];
  fs.writeFileSync(log, entries.map(JSON.stringify).join('\n') + '\n');
  const context = {
    AUDIT_LOG: log,
    optionalInteger: (args, key, fallback) => args[key] ?? fallback,
    optionalString: (args, key, fallback) => args[key] ?? fallback,
    tailFile: async (file, maxBytes) => {
      const text = fs.readFileSync(file, 'utf8');
      return { text, size: Buffer.byteLength(text), returnedBytes: Math.min(Buffer.byteLength(text), maxBytes), truncated: false };
    },
    audit: async () => {},
  };
  const result = await handleAudit('audit_tail', { category: 'missing_parameter' }, context);
  assert.equal(result.matched, 1);
  assert.match(result.text, /"tool":"chatgpt"/);
  assert.doesNotMatch(result.text, /"tool":"fs"/);
});

test('non-zero command exit is classified as command_failure', async () => {
  const source = fs.readFileSync(new URL('../src/core/tools/index.mjs', import.meta.url), 'utf8');
  assert.match(source, /const commandFailed = Number\.isInteger\(summary\?\.exitCode\) && summary\.exitCode !== 0;/);
  assert.match(source, /commandFailed \? "command_failure" : "success"/);
  assert.match(source, /commandFailed \? "command_failure" : "tool_call"/);
});
