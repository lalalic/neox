import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
const runtime=fileURLToPath(new URL('../src/core/tools/index.mjs',import.meta.url));
const review=fileURLToPath(new URL('../src/core/tools/review.mjs',import.meta.url));
const UID='5d79c254-92e0-4b93-9b42-8d8d5f5830c3', HASH='d'.repeat(64);
test('Core review operations are REST-only, never published as Agent MCP tools',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'neo-core-mobile-review-'));
 const env={...process.env,NEO_APNS_HOME:dir,NEO_CORE_DATA_DIR:join(dir,'core'),NEO_CORE_FULL_ACCESS_ACK:'I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS'};
 const child=spawn(process.execPath,[runtime],{env,stdio:['pipe','pipe','pipe']});
 let next=0,buffer='',stderr='';const wait=new Map();
 child.stdout.on('data',chunk=>{
   buffer+=chunk.toString();let i;
   while((i=buffer.indexOf('\n'))>=0){
     const line=buffer.slice(0,i);buffer=buffer.slice(i+1);
     if(!line)continue;
     let message;try{message=JSON.parse(line)}catch{continue;}
     const w=wait.get(message.id);if(w){wait.delete(message.id);w.resolve(message)}
   }
 });
 child.stderr.on('data',part=>{if(stderr.length<5000)stderr+=part});
 function rpc(method,params={}){
  const id=++next;
  return new Promise((resolve,reject)=>{
    const timeout=setTimeout(()=>{wait.delete(id);reject(Error('Core RPC timeout '+method+' '+stderr))},8000);
    wait.set(id,{resolve:(v)=>{clearTimeout(timeout);resolve(v)}});
    child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');
  });
 }
 const service=(action,args={})=>JSON.parse(execFileSync(process.execPath,[review,action],{
   input:JSON.stringify(args),env,encoding:'utf8'}));
 try{
   await rpc('initialize',{protocolVersion:'2025-06-18'});
   child.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');
   const list=(await rpc('tools/list')).result.tools.map(x=>x.name);
   assert.ok(!list.includes('review'));
   assert.ok(!list.some(name=>name.startsWith('review.')));
   assert.equal((await rpc('tools/call',{name:'review',arguments:{command:'pending'}})).error.code,-32601);
   assert.equal(service('register',{deviceId:UID,token:'b'.repeat(64),environment:'sandbox'}).registered,true);
   const obj={id:UID,title:'Core Test Preview',contentHash:HASH,revisionId:HASH,delivery:'text'};
   const stored=service('notify',obj);
   assert.equal(stored.stored,true);
   assert.equal(stored.requestId,UID);
   assert.equal(service('pending').requests[0].id,UID);
   assert.equal(service('complete',{id:UID}).acknowledged,true);
   assert.deepEqual(service('pending').requests,[]);
 }finally{child.kill();rmSync(dir,{recursive:true,force:true});}
});
