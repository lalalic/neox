import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
test('audit logging remains internal and is not exposed as an MCP tool', () => {
  const source = fs.readFileSync(new URL('../src/core/tools/index.mjs', import.meta.url), 'utf8');
  assert.match(source, /const AUDIT_LOG =/);
  assert.match(source, /async function audit\(/);
  assert.match(source, /await fsp\.appendFile\(AUDIT_LOG/);
  assert.doesNotMatch(source, /auditFacade/);
  assert.doesNotMatch(source, /case "audit"/);
  assert.doesNotMatch(source, /case "audit_tail"/);
});

test('non-zero command exit is classified as command_failure', async () => {
  const source = fs.readFileSync(new URL('../src/core/tools/index.mjs', import.meta.url), 'utf8');
  assert.match(source, /const commandFailed = Number\.isInteger\(summary\?\.exitCode\) && summary\.exitCode !== 0;/);
  assert.match(source, /commandFailed \? "command_failure" : "success"/);
  assert.match(source, /commandFailed \? "command_failure" : "tool_call"/);
});
