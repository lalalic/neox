import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { XCHAT_LIFECYCLE_TOOLS, isXChatLifecycleTool, scheduleXChatLifecycle } from "../src/xchat/lifecycle.mjs";

test("declares terminal turn and thread lifecycle tools", () => {
  assert.deepEqual(XCHAT_LIFECYCLE_TOOLS.map((tool) => tool.name), ["xchat.turn.new", "xchat.thread.new"]);
  const turnSchema=XCHAT_LIFECYCLE_TOOLS.find((tool)=>tool.name==="xchat.turn.new").inputSchema;
  assert.deepEqual(turnSchema.required, ["thread_id", "message"]);
  for (const tool of XCHAT_LIFECYCLE_TOOLS) {
    assert.match(tool.description, /Terminal control transfer/);
    assert.equal(tool.inputSchema.additionalProperties, false);
  }
});

test("schedules same-thread Browser Workspace transfer", () => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),"neoy-xchat-turn-"));
  let observed;
  const spawnImpl=(command,args,options)=>{
    observed={command,args,options};
    return { unref(){} };
  };
  const result=scheduleXChatLifecycle("xchat.turn.new",{
    project_id:"g-p-12345678",
    thread_id:"thread_12345678",
    message:"Continue after refreshing the tool surface.",
    reason:"plugin tools changed",
  },{dataDir:dir,transferId:"turn-1",spawnImpl,workerPath:"/tmp/worker.mjs"});
  const payload=JSON.parse(result.content[0].text);
  assert.equal(payload.status,"scheduled");
  assert.equal(payload.terminal,true);
  assert.equal(payload.mode,"new-turn");
  assert.equal(observed.args[1],"new-turn");
  assert.ok(fs.existsSync(path.join(dir,"xchat-lifecycle","turn-1.json")));
});

test("schedules standalone same-thread transfer without project_id", () => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),"neoy-xchat-turn-standalone-"));
  const result=scheduleXChatLifecycle("xchat.turn.new",{
    thread_id:"thread_12345678",
    message:"Continue in the standalone thread.",
  },{dataDir:dir,transferId:"turn-standalone",spawnImpl:()=>({unref(){}}),workerPath:"/tmp/worker.mjs"});
  const payload=JSON.parse(result.content[0].text);
  assert.equal(payload.thread_id,"thread_12345678");
  assert.equal("project_id" in payload,false);
  const config=JSON.parse(fs.readFileSync(path.join(dir,"xchat-lifecycle","turn-standalone.json"),"utf8"));
  assert.equal("project_id" in config,false);
});

test("schedules new-thread Browser Workspace transfer", () => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),"neoy-xchat-thread-"));
  let observed;
  const spawnImpl=(command,args,options)=>{
    observed={command,args,options};
    return { unref(){} };
  };
  const result=scheduleXChatLifecycle("xchat.thread.new",{
    project_id:"g-p-12345678",
    source_thread_id:"thread_12345678",
    message:"Continue in a clean thread.",
  },{dataDir:dir,transferId:"thread-1",spawnImpl,workerPath:"/tmp/worker.mjs"});
  const payload=JSON.parse(result.content[0].text);
  assert.equal(payload.terminal,true);
  assert.equal(payload.mode,"new-thread");
  assert.equal(observed.args[1],"new-thread");
});

test("supports projectless and temporary new threads", () => {
  const schema=XCHAT_LIFECYCLE_TOOLS.find((tool)=>tool.name==="xchat.thread.new").inputSchema;
  assert.deepEqual(schema.required, ["message"]);
  assert.equal(schema.properties.temporary.type, "boolean");

  const dir=fs.mkdtempSync(path.join(os.tmpdir(),"neoy-xchat-temporary-"));
  const spawnImpl=()=>({ unref(){} });
  const result=scheduleXChatLifecycle("xchat.thread.new",{
    message:"Check the refreshed tool surface.",
    temporary:true,
  },{dataDir:dir,transferId:"temporary-1",spawnImpl,workerPath:"/tmp/worker.mjs"});
  const payload=JSON.parse(result.content[0].text);
  assert.equal(payload.temporary,true);
  assert.equal("project_id" in payload,false);
  const config=JSON.parse(fs.readFileSync(path.join(dir,"xchat-lifecycle","temporary-1.json"),"utf8"));
  assert.equal(config.temporary,true);
  assert.equal("project_id" in config,false);

  assert.throws(()=>scheduleXChatLifecycle("xchat.thread.new",{
    project_id:"g-p-12345678",
    temporary:true,
    message:"x",
  },{dataDir:dir,transferId:"temporary-invalid",spawnImpl,workerPath:"/tmp/worker.mjs"}),/cannot be combined/);
});

test("supports projectless persistent new threads", () => {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),"neoy-xchat-projectless-"));
  const result=scheduleXChatLifecycle("xchat.thread.new",{
    message:"Continue in a standalone chat.",
  },{dataDir:dir,transferId:"projectless-1",spawnImpl:()=>({unref(){}}),workerPath:"/tmp/worker.mjs"});
  const payload=JSON.parse(result.content[0].text);
  assert.equal(payload.temporary,false);
  assert.equal("project_id" in payload,false);
});

test("rejects invalid stable ids and unknown tools", () => {
  assert.equal(isXChatLifecycleTool("xchat.turn.new"),true);
  assert.equal(isXChatLifecycleTool("xchat.nope"),false);
  assert.throws(()=>scheduleXChatLifecycle("xchat.turn.new",{project_id:"bad",thread_id:"thread_12345678",message:"x"}),/project_id/);
  assert.throws(()=>scheduleXChatLifecycle("xchat.turn.new",{project_id:"g-p-12345678",thread_id:"bad",message:"x"}),/thread_id/);
});
