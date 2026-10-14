import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../../Resources/Scripts/neo-node/neo-node.mjs', import.meta.url));

test('neo-node status reconciles stale PID files without killing unrelated processes', () => {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'neo-node-pid-test-'));
  const executable=path.join(root,'neo-node.mjs');
  fs.copyFileSync(script,executable);
  const run=path.join(root,'run');fs.mkdirSync(run);
  for(const component of ['supervisor','server','tunnel']) fs.writeFileSync(path.join(run,component+'.pid'),'99999999');
  const config=path.join(root,'node.env');
  fs.writeFileSync(config,`NODE_NAME=isolated-test\nNODE_ROOT=${root}\nNODE_BIN=${process.execPath}\nLOCAL_MCP_PORT=59781\nHUB_MCP_PORT=59782\nHUB_SSH_TARGET=test@example.invalid\n`);
  const result=spawnSync(process.execPath,[executable,'status'],{encoding:'utf8',env:{...process.env,NEO_NODE_CONFIG:config}});
  assert.equal(result.status,0,result.stderr);
  assert.match(result.stdout,/supervisor pid: missing/);
  assert.match(result.stdout,/server pid: missing/);
  assert.match(result.stdout,/tunnel pid: missing/);
  for(const component of ['supervisor','server','tunnel']) assert.equal(fs.existsSync(path.join(run,component+'.pid')),false);
  fs.rmSync(root,{recursive:true,force:true});
});
