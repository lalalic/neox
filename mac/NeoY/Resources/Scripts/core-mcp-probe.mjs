#!/usr/bin/env node
// Read-only MCP handshake: no tools/call, only initialize and tools/list.
import { spawn } from 'node:child_process';
import readline from 'node:readline';
const entry = process.argv[2];
if (!entry) process.exit(2);
const child = spawn(process.execPath, [entry], {
  env: { ...process.env, NEO_CORE_FULL_ACCESS_ACK: 'I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS',
    NEO_CORE_DATA_DIR: process.env.NEO_CORE_DATA_DIR || `${process.env.HOME}/Library/Application Support/NeoY/core` },
  stdio: ['pipe', 'pipe', 'pipe']
});
let settled = false;
function finish(ok, message) {
  if (settled) return;
  settled = true;
  clearTimeout(timeout);
  child.kill('SIGTERM');
  console.log(message);
  process.exitCode = ok ? 0 : 1;
}
const timeout = setTimeout(() => finish(false, 'Core MCP handshake timed out'), 10000);
child.on('error', e => finish(false, `Core failed to spawn: ${e.message}`));
child.on('exit', code => { if (!settled) finish(false, `Core exited early: ${code}`); });
const lines = readline.createInterface({ input: child.stdout });
child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-11-25',capabilities:{},clientInfo:{name:'neoy-core-probe',version:'1'}}})+'\n');
lines.on('line', line => {
  let response;
  try { response = JSON.parse(line); } catch { return; }
  if (response.id === 1) {
    if (response.error || !response.result?.serverInfo) return finish(false, 'Core initialize failed');
    child.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized',params:{}})+'\n');
    child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:2,method:'tools/list',params:{}})+'\n');
  }
  if (response.id === 2) finish(Array.isArray(response.result?.tools) && response.result.tools.length > 0,
    `Core MCP tools/list: ${response.result?.tools?.length ?? 0} tools`);
});
