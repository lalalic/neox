import {test} from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const ID='8aad68fe-8892-4f88-8c58-4459197afb29',H='a'.repeat(64);
const r={id:ID,title:'Review E2E',contentHash:H,revisionId:H,delivery:'text'};
const template={type:'task.interactive_decision',source:'job/j8/task/producer/execution/e8',
  data:{interactive:{jobId:'j8',taskId:'producer',executionId:'e8'}}};
const event={id:ID,title:r.title,mediaHash:H,delivery:'event',eventTemplate:template,previewId:H};
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'neox-apns-test-'));
process.env.NEO_APNS_HOME=temp;
const {validateRegistration,validateReview,payloadForReview,signingJWT,registerDevice,
  notifyReview,pendingReviews,completeReview,status}=await import('../src/core/tools/review.mjs');
const keys=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const privateKey=keys.privateKey.export({type:'pkcs8',format:'pem'});
fs.writeFileSync(path.join(temp,'key.p8'),privateKey,{mode:0o600});
fs.writeFileSync(path.join(temp,'config.json'),JSON.stringify({topic:'com.neox.app',keyId:'Z4YUMQ3P42',teamId:'JABNLDLN8G',keyPath:path.join(temp,'key.p8')}),{mode:0o600});
test('Core transports arbitrary caller events without interpreting Relay identity',()=>{
 const arbitrary={type:'sample.review.finished',source:'custom/owner-channel',responseKey:'result',
   data:{result:{opaque:'business-owned'},metadata:{workflow:'unrelated'}}};
 assert.deepEqual(validateReview({...event,eventTemplate:arbitrary}).eventTemplate,arbitrary);
 assert.equal(validateReview(event).eventTemplate.type,'task.interactive_decision');
 assert.throws(()=>validateReview({...event,eventTemplate:{...arbitrary,source:'bad\nsource'}}));
 assert.throws(()=>validateReview({...event,eventTemplate:{...arbitrary,responseKey:'__proto__'}}));
 assert.throws(()=>validateReview({...event,eventTemplate:{...arbitrary,data:{result:{decision:'prefilled'}}}}));
 assert.throws(()=>validateReview({...event,eventTemplate:{...arbitrary,data:JSON.parse('{"__proto__":{}}')}}));
 assert.throws(()=>validateReview({...event,ownerCallbackTool:'chatgpt'}));
 assert.throws(()=>validateReview({...event,delivery:'other'}));
 assert.equal(validateReview({...event,unrelatedCallerMetadata:'opaque'}).unrelatedCallerMetadata,undefined);
 assert.throws(()=>validateReview({...event,revisionId:'old'}));
 assert.throws(()=>validateReview({...r,contentHash:'bad'}));
 assert.throws(()=>validateRegistration({deviceId:ID,token:'bad',environment:'sandbox'}));
});
test('text without a thread can mirror preview to phone as view-only',()=>{
 assert.equal(validateReview(r).delivery,'text');
 assert.equal(payloadForReview(r).neoReviewRequestId,ID);
 assert.equal(payloadForReview(r).neoReview,undefined);
 assert.equal(payloadForReview(r).aps.alert.title,'Video preview ready');
 assert.equal(payloadForReview(event).aps.alert.title,'Video ready for review');
});
test('jwt ES256 signs APNs authorization',()=>{
 const jwt=signingJWT('Z4YUMQ3P42','JABNLDLN8G',privateKey,1700000000);
 const [head,payload,sig]=jwt.split('.');
 assert.equal(JSON.parse(Buffer.from(head,'base64url').toString()).kid,'Z4YUMQ3P42');
 assert.equal(JSON.parse(Buffer.from(payload,'base64url').toString()).iat,1700000000);
 assert.ok(crypto.verify('sha256',Buffer.from(head+'.'+payload),{key:keys.publicKey,dsaEncoding:'ieee-p1363'},Buffer.from(sig,'base64url')));
});
test('Master persists full review; APNs sends pointer only; phone fetches and completes',async()=>{
 const deviceId='00000000-0000-4000-8000-000000000001';
 const rr=registerDevice({deviceId,token:'b'.repeat(64),environment:'sandbox'});
 assert.equal(rr.registered,true);assert.equal(status().deviceCount,1);
 let count=0;
 const transport=async({host,headers,bytes})=>{
  count++;assert.equal(host,'api.sandbox.push.apple.com');
  assert.equal(headers['apns-push-type'],'alert');
  assert.equal(headers['apns-collapse-id'],ID);
  const payload=JSON.parse(bytes);
  assert.equal(payload.neoReviewRequestId,ID);
  assert.equal(payload.neoReview,undefined);
  assert.ok(!JSON.stringify(payload).includes('interactive'));
  return {accepted:true,status:200,apnsId:ID};
 };
 const receipt=await notifyReview(event,transport);
 assert.equal(receipt.stored,true);assert.equal(receipt.accepted,true);assert.equal(count,1);
 assert.equal(pendingReviews().requests.length,1);
 assert.deepEqual(pendingReviews().requests[0].eventTemplate,template);
 assert.equal((await notifyReview(event,transport)).duplicate,true);
 assert.equal(pendingReviews().requests.length,1);
 assert.throws(()=>validateReview({...event,id:'invalid'}));
 await assert.rejects(()=>notifyReview({...event,title:'changed'},transport),/Conflicting/);
 const acknowledged=completeReview({id:ID});
 assert.equal(acknowledged.acknowledged,true);assert.equal(acknowledged.wasPending,true);
 assert.equal(pendingReviews().requests.length,0);
 assert.equal(completeReview({id:ID}).wasPending,false);
 await assert.rejects(()=>notifyReview(event,transport),/already completed/);
});
test('pending previews expose persisted creation times in newest-first order',async()=>{
 const older={...r,id:'acdd68fe-8892-4f88-8c58-4459197afb29',title:'Earlier Vlog'};
 const newer={...r,id:'bdd68afe-8892-4f88-8c58-4459197afb29',title:'Later Vlog'};
 const noAPNs=async()=>({accepted:false,status:503,reason:'offline'});
 await notifyReview(older,noAPNs);
 await new Promise(resolve=>setTimeout(resolve,10));
 await notifyReview(newer,noAPNs);
 const requests=pendingReviews().requests;
 assert.deepEqual(requests.slice(0,2).map(x=>x.id),[newer.id,older.id]);
 assert.ok(Date.parse(requests[0].createdAt) > Date.parse(requests[1].createdAt));
 assert.equal(requests[0].title,'Later Vlog');
 assert.equal(requests[0].delivery,'text');
 completeReview({id:older.id});
 completeReview({id:newer.id});
});
test('offline APNs still yields a durable review for later phone sync',async()=>{
 const req={...event,id:'c1ad68fe-8892-4f88-8c58-4459197afb29'};
 const saved=await notifyReview(req,async()=>({accepted:false,status:503,reason:'unavailable'}));
 assert.equal(saved.stored,true);assert.equal(saved.accepted,false);
 assert.equal(pendingReviews().requests.length,1);
 completeReview({id:req.id});
});

test('APNs stale-token cleanup never overwrites a concurrently renewed device token',async()=>{
 const deviceId='00000000-0000-4000-8000-000000000003';
 const older='c'.repeat(64),newer='d'.repeat(64);
 registerDevice({deviceId,token:older,environment:'sandbox'});
 const req={...r,id:'b1ad68fe-8892-4f88-8c58-4459197afb29'};
 await notifyReview({...req,deviceId},async()=>{
   registerDevice({deviceId,token:newer,environment:'production'});
   return {accepted:false,status:410,reason:'Unregistered'};
 });
 const store=JSON.parse(fs.readFileSync(path.join(temp,'devices.json'),'utf8'));
 assert.equal(store.devices[deviceId].token,newer);
 assert.equal(store.devices[deviceId].environment,'production');
 completeReview({id:req.id});
});

test('malformed Event records remain durable but cannot block current execution-bound inbox sync',()=>{
 const file=path.join(temp,'reviews.json');
 const before=fs.existsSync(file)?fs.readFileSync(file):null;
 const legacy={id:'c7a9a9fe-8892-4f88-8c58-4459197afb29',title:'Legacy Event',
   contentHash:H,revisionId:'old-review',delivery:'event',eventTemplate:template};
 const current={...event,id:'d7a9a9fe-8892-4f88-8c58-4459197afb29'};
 const text={...r,id:'e7a9a9fe-8892-4f88-8c58-4459197afb29'};
 const now=new Date().toISOString();
 const store={version:1,requests:{
  [legacy.id]:{review:legacy,createdAt:now},
  [current.id]:{review:current,createdAt:now},
  [text.id]:{review:text,createdAt:now}
 },completed:{}};
 try{
  fs.writeFileSync(file,JSON.stringify(store),{mode:0o600});
  const result=pendingReviews();
  assert.equal(result.unsupportedCount,1);
  assert.equal(result.requests.length,2);
  assert.ok(!result.requests.some(x=>x.id===legacy.id));
  assert.ok(result.requests.some(x=>x.id===current.id&&x.mediaHash===current.mediaHash));
  assert.ok(result.requests.some(x=>x.id===text.id&&x.contentHash===H));
  for(const item of result.requests)assert.doesNotThrow(()=>validateReview(item));
  assert.deepEqual(JSON.parse(fs.readFileSync(file,'utf8')),store,'All raw review records remain unchanged');
 }finally{
  if(before===null)fs.rmSync(file,{force:true});else fs.writeFileSync(file,before);
 }
});
