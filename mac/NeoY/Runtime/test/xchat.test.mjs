import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {XCHAT_LIFECYCLE_TOOLS,scheduleXChatLifecycle,parsePlatformReceipt} from '../src/core/tools/xchat.mjs';
const call=(command,args={},options={})=>JSON.parse(scheduleXChatLifecycle('chatgpt',{command,args},options).content[0].text);
const thread={status:'submitted',mode:'new-thread',temporary:false,thread_id:'6acfc12e-c1a0-83ea-bfa3-5b5c609ec588',thread_url:'https://chatgpt.com/c/6acfc12e-c1a0-83ea-bfa3-5b5c609ec588',verified_by:'composer-cleared'};
test('turn modes documented, no separate status command',()=>{
 assert.deepEqual(call('help').commands.map(x=>x.command),['turn','thread']);
 assert.throws(()=>call('status',{transfer_id:'receipt-123'}),/Unknown chatgpt command/);
 assert.equal(XCHAT_LIFECYCLE_TOOLS.length,1);
 assert.deepEqual(call('help',{command:'turn'}).schema.properties.mode.enum,['async','sync']);
});
test('new-thread synchronously returns platform thread id and URL',()=>{
 let observed;
 const result=call('thread',{message:'Verify player'}, {cli:'browser-workspace',spawnSyncImpl:(cli,args)=>{observed={cli,args,config:JSON.parse(fs.readFileSync(args.at(-1),'utf8'))};return {status:0,stdout:JSON.stringify({result:{ok:true,stdout:JSON.stringify(thread)}})};}});
 assert.equal(result.thread_id,thread.thread_id);assert.equal(result.thread_url,thread.thread_url);
 assert.equal(result.status,'submitted');assert.equal(result.transfer_id,undefined);
 assert.deepEqual(observed.args.slice(0,5),['platform','run','chatgpt','new-thread','--auto-session']);
 assert.equal(observed.config.message,'Verify player');
});
test('new-turn defaults to async and preserves submitted receipt',()=>{
 const receipt={status:'submitted',mode:'new-turn',thread_id:'thread_12345678',queue_id:'q123',verified_by:'durable-queue'};
 let observed;
 const got=call('turn',{thread_id:'thread_12345678',message:'Continue'}, {cli:'browser-workspace',spawnSyncImpl:(cli,args)=>{observed={args,config:JSON.parse(fs.readFileSync(args.at(-1),'utf8'))};return {status:0,stdout:JSON.stringify({result:{ok:true,stdout:JSON.stringify(receipt)}})};}});
 assert.deepEqual(got,receipt);
 assert.deepEqual(observed.args.slice(0,6),['platform','run','chatgpt','new-turn','--mode','async']);
 assert.equal(observed.args.includes('--auto-session'),false);
 assert.equal(observed.config.mode,'async');
});
test('mergeable is opt-in and reaches WebHelm',()=>{
 let config;
 const receipt={status:'submitted',mode:'new-turn',thread_id:'thread_12345678',queue_id:'q123',verified_by:'durable-queue'};
 const options={cli:'browser-workspace',spawnSyncImpl:(_cli,args)=>{config=JSON.parse(fs.readFileSync(args.at(-1),'utf8'));return {status:0,stdout:JSON.stringify({result:{ok:true,stdout:JSON.stringify(receipt)}})};}};
 call('turn',{thread_id:'thread_12345678',message:'one'},options);
 assert.equal(config.mergeable,false);
 call('turn',{thread_id:'thread_12345678',message:'two',mergeable:true},options);
 assert.equal(config.mergeable,true);
 assert.throws(()=>call('turn',{thread_id:'thread_12345678',message:'x',mergeable:'true'}),/mergeable must be a boolean/);
 assert.throws(()=>call('turn',{thread_id:'thread_12345678',message:'x',mergeable:true,mode:'sync',session_id:'s'}),/requires async/);
});
test('new-turn sync uses caller-owned session',()=>{
 const receipt={status:'submitted',mode:'new-turn',thread_id:'thread_12345678',verified_by:'composer-cleared'};
 let observed;
 const got=call('turn',{thread_id:'thread_12345678',message:'Continue',mode:'sync',session_id:'owned-session'}, {cli:'browser-workspace',spawnSyncImpl:(cli,args)=>{observed={args,config:JSON.parse(fs.readFileSync(args.at(-1),'utf8'))};return {status:0,stdout:JSON.stringify({result:{ok:true,stdout:JSON.stringify(receipt)}})};}});
 assert.deepEqual(got,receipt);
 assert.deepEqual(observed.args.slice(0,8),['platform','run','chatgpt','new-turn','--mode','sync','--session-id','owned-session']);
 assert.equal(observed.config.mode,'sync');
 assert.equal(observed.args.includes('--auto-session'),false);
});
test('invalid mode and session ownership fail before invoking browser',()=>{
 assert.throws(()=>call('turn',{thread_id:'thread_12345678',message:'x',mode:'sync'}),/caller-owned session_id/);
 assert.throws(()=>call('turn',{thread_id:'thread_12345678',message:'x',session_id:'s'}),/does not accept session_id/);
 assert.throws(()=>call('turn',{thread_id:'thread_12345678',message:'x',mode:'other'}),/mode must be async or sync/);
});
test('errors propagate without false-positive success',()=>{
 assert.throws(()=>call('thread',{message:'x'},{cli:'test',spawnSyncImpl:()=>({status:1,stderr:'browser failed'})}),/browser failed/);
 assert.throws(()=>call('thread',{message:'x'},{cli:'test',spawnSyncImpl:()=>({status:0,stdout:JSON.stringify({result:{ok:true,stdout:'{"status":"submitted","mode":"new-thread"}'}})})}),/durable/);
 assert.throws(()=>parsePlatformReceipt({result:{ok:false,stderr:'blocked'}},'new-thread'),/blocked/);
});

test('default uses the global webhelm launcher',()=>{
 let executable;
 const response=call('thread',{message:'Global CLI check'},{spawnSyncImpl:(cli)=>{
   executable=cli;
   return {status:0,stdout:JSON.stringify({result:{ok:true,stdout:JSON.stringify(thread)}})};
 }});
 assert.equal(response.status,'submitted');
 assert.equal(executable,path.join(os.homedir(),'.local','bin','webhelm'));
});
