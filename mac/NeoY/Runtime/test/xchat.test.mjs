import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {XCHAT_LIFECYCLE_TOOLS,scheduleXChatLifecycle,parsePlatformReceipt} from '../src/core/tools/xchat.mjs';
const call=(command,args={},options={})=>JSON.parse(scheduleXChatLifecycle('chatgpt',{command,args},options).content[0].text);
const thread={status:'submitted',mode:'new-thread',temporary:false,thread_id:'6acfc12e-c1a0-83ea-bfa3-5b5c609ec588',thread_url:'https://chatgpt.com/c/6acfc12e-c1a0-83ea-bfa3-5b5c609ec588',verified_by:'composer-cleared'};
test('only synchronous commands exposed, no status',()=>{
 assert.deepEqual(call('help').commands.map(x=>x.command),['turn','thread']);
 assert.throws(()=>call('status',{transfer_id:'receipt-123'}),/Unknown chatgpt command/);
 assert.equal(XCHAT_LIFECYCLE_TOOLS.length,1);
});
test('new-thread synchronously returns platform thread id and URL',()=>{
 let observed;
 const result=call('thread',{message:'Verify player'}, {cli:'browser-workspace',spawnSyncImpl:(cli,args)=>{observed={cli,args,config:JSON.parse(fs.readFileSync(args.at(-1),'utf8'))};return {status:0,stdout:JSON.stringify({result:{ok:true,stdout:JSON.stringify(thread)}})};}});
 assert.equal(result.thread_id,thread.thread_id);assert.equal(result.thread_url,thread.thread_url);
 assert.equal(result.status,'submitted');assert.equal(result.transfer_id,undefined);
 assert.deepEqual(observed.args.slice(0,5),['platform','run','chatgpt','new-thread','--auto-session']);
 assert.equal(observed.config.message,'Verify player');
});
test('new-turn synchronously returns verified platform receipt',()=>{
 const receipt={status:'submitted',mode:'new-turn',thread_id:'thread_12345678',verified_by:'composer-cleared'};
 const got=call('turn',{thread_id:'thread_12345678',message:'Continue'}, {cli:'browser-workspace',spawnSyncImpl:()=>({status:0,stdout:JSON.stringify({result:{ok:true,stdout:JSON.stringify(receipt)}})})});
 assert.deepEqual(got,receipt);
});
test('errors propagate without false-positive success',()=>{
 assert.throws(()=>call('thread',{message:'x'},{cli:'test',spawnSyncImpl:()=>({status:1,stderr:'browser failed'})}),/browser failed/);
 assert.throws(()=>call('thread',{message:'x'},{cli:'test',spawnSyncImpl:()=>({status:0,stdout:JSON.stringify({result:{ok:true,stdout:'{"status":"submitted","mode":"new-thread"}'}})})}),/durable/);
 assert.throws(()=>parsePlatformReceipt({result:{ok:false,stderr:'blocked'}},'new-thread'),/blocked/);
});
