import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

test('Core does not define or write a duplicate audit.jsonl', () => {
  const source = fs.readFileSync(new URL('../src/core/tools/index.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /AUDIT_LOG|AUDIT_MODE|NEO_CORE_AUDIT_LOG/);
  assert.doesNotMatch(source, /appendFile\([^\n]*audit/);
  assert.doesNotMatch(source, /auditLog:/);
});

test('tool-call history is documented in AGENTS.md', () => {
  const agents = fs.readFileSync(new URL('../../../../AGENTS.md', import.meta.url), 'utf8');
  assert.match(agents, /tool-calls\.jsonl/);
  assert.match(agents, /call_id/);
  assert.match(agents, /timeout_ms/);
});
