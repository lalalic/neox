import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { collectJobGarbage, JOB_GC_MAX_COMPLETED, JOB_GC_MAX_AGE_MS } from "../src/core/tools/job-gc.mjs";

async function withFixture(callback) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "neoy-gc-test-"));
  try { await callback(root); }
  finally { await fs.rm(root, { recursive: true, force: true }); }
}
async function createJob(root, id, { now, finished = now - 1000, started = now - 2000,
  pid = 99999999, stdoutPath, stderrPath, kind } = {}) {
  const stdout = stdoutPath || path.join(root, `${id}.stdout.log`);
  const stderr = stderrPath || path.join(root, `${id}.stderr.log`);
  const doc = { id, pid, processGroupId: pid, startedAt: new Date(started).toISOString(),
    finishedAt: finished === null ? null : new Date(finished).toISOString(),
    stdoutPath:stdout, stderrPath:stderr, command:"true", cwd:root, label:"test",
    exitCode:finished===null?null:0, signal:null };
  if (kind) doc.kind = kind;
  await Promise.all([
    fs.writeFile(path.join(root,`${id}.json`),JSON.stringify(doc)),
    stdout.startsWith(root + path.sep) ? fs.writeFile(stdout,`out-${id}`) : Promise.resolve(),
    stderr.startsWith(root + path.sep) ? fs.writeFile(stderr,`err-${id}`) : Promise.resolve(),
  ]);
  return doc;
}

test("GC keeps recent 2000, deletes oldest plus older-than-72h with owned stdout/stderr",async()=>{
  await withFixture(async root=>{
    const now=Date.now();
    for(let i=0;i<JOB_GC_MAX_COMPLETED+5;i++) {
      await createJob(root,`job-${String(i).padStart(5,'0')}`,{now,finished:now-i*1000});
    }
    await createJob(root,'job-ancient',{now,finished:now-JOB_GC_MAX_AGE_MS-1000});
    const dry=await collectJobGarbage({jobDir:root,now,dryRun:true,maxDeletes:5000,processStartTimes:new Map()});
    assert.equal(dry.completed,JOB_GC_MAX_COMPLETED+6);
    assert.equal(dry.eligible,6);
    assert.equal(dry.verified,6);
    assert.equal((await fs.readdir(root)).length,(JOB_GC_MAX_COMPLETED+6)*3);
    const sweep=await collectJobGarbage({jobDir:root,now,maxDeletes:5000,processStartTimes:new Map()});
    assert.equal(sweep.verified,6);
    const after=(await fs.readdir(root)).filter(x=>x.endsWith('.json'));
    assert.equal(after.length,JOB_GC_MAX_COMPLETED);
    assert.equal((await fs.readdir(root)).length,JOB_GC_MAX_COMPLETED*3);
    assert.ok(!after.includes('job-ancient.json'));
  });
});

test("GC protects active identity, uncertain PID snapshot and recent unfinished jobs",async()=>{
  await withFixture(async root=>{
    const now=Date.now(),old=now-JOB_GC_MAX_AGE_MS-10_000;
    await createJob(root,'active',{now,started:old,finished:null,pid:420001});
    await createJob(root,'abandoned',{now,started:old,finished:null,pid:420002});
    await createJob(root,'recent',{now,started:now-60000,finished:null,pid:420003});
    let dry=await collectJobGarbage({jobDir:root,now,dryRun:true,maxDeletes:10,processStartTimes:null});
    assert.equal(dry.verified,0,'when ps fails all unfinished jobs remain');
    dry=await collectJobGarbage({jobDir:root,now,maxDeletes:10,
      processStartTimes:new Map([[420001,old],[420002,old-600_000]])});
    assert.equal(dry.verified,1,'recycled PID is not original process');
    assert.ok((await fs.readdir(root)).includes('active.json'));
    assert.ok((await fs.readdir(root)).includes('recent.json'));
    assert.ok(!(await fs.readdir(root)).includes('abandoned.json'));
  });
});

test("GC never unlinks foreign log paths, symlinks or recent PTY sessions",async()=>{
  await withFixture(async root=>{
    const now=Date.now();
    const other=await fs.mkdtemp(path.join(os.tmpdir(),'neoy-gc-foreign-'));
    try {
      const foreign=path.join(other,'important.txt');
      await fs.writeFile(foreign,'preserve');
      await createJob(root,'old-valid',{now,finished:now-JOB_GC_MAX_AGE_MS-20_000,
        stdoutPath:foreign});
      await createJob(root,'pty_old',{now,finished:null,started:now-8*24*60*60*1000,kind:'pty'});
      await createJob(root,'pty_recent',{now,finished:null,started:now-2*24*60*60*1000,kind:'pty'});
      await fs.writeFile(path.join(root,'bad-target.json'),'do not follow');
      await fs.symlink(foreign,path.join(root,'evil.json'));
      const result=await collectJobGarbage({jobDir:root,now,maxDeletes:100,
        processStartTimes:new Map()});
      assert.equal(result.verified,2);
      assert.equal(await fs.readFile(foreign,'utf8'),'preserve');
      assert.ok((await fs.readdir(root)).includes('pty_recent.json'));
      assert.ok((await fs.readdir(root)).includes('evil.json'));
      assert.ok(!(await fs.readdir(root)).includes('old-valid.json'));
    } finally {await fs.rm(other,{recursive:true,force:true});}
  });
});

test("recycled process-group leader is not mistaken for a surviving job", async () => {
  await withFixture(async root => {
    const now=Date.now(), original=now-10*24*3600_000;
    await createJob(root,'recycled',{now,pid:431000,started:original,finished:original+10_000});
    await createJob(root,'orphaned',{now,pid:431001,started:original,finished:original+10_000});
    await createJob(root,'original',{now,pid:431002,started:original,finished:original+10_000});
    const snapshot=new Map([[431000,now-3600_000],[431002,original]]);
    snapshot.groups=new Map([[431000,now-3600_000],[431001,null],[431002,original]]);
    const dry=await collectJobGarbage({jobDir:root,dryRun:true,now,maxDeletes:20,processStartTimes:snapshot});
    assert.equal(dry.eligible,3);
    assert.equal(dry.verified,1,'only proven-recycled PGID may be deleted');
    const applied=await collectJobGarbage({jobDir:root,now,maxDeletes:20,processStartTimes:snapshot});
    assert.equal(applied.verified,1);
    assert.ok(!(await fs.readdir(root)).includes('recycled.json'));
    assert.ok((await fs.readdir(root)).includes('orphaned.json'));
    assert.ok((await fs.readdir(root)).includes('original.json'));
  });
});
