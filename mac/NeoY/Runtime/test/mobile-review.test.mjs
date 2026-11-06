import {test} from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const ID='8aad68fe-8892-4f88-8c58-4459197afb29',H='a'.repeat(64);
const r={id:ID,title:'Review E2E',contentHash:H,revisionId:H,delivery:'text'};
const template={type:'task.interactive_decision',source:'job/j8/task/producer/execution/e8',
  data:{interactive:{jobId:'j8',taskId:'producer',executionId:'e8',invocationId:'review-r8'}}};
const event={...r,delivery:'event',eventTemplate:template,previewId:H};
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'neox-apns-test-'));
process.env.NEO_APNS_HOME=temp;
const {validateRegistration,validateReview,payloadForReview,signingJWT,registerDevice,
  notifyReview,pendingReviews,completeReview,status}=await import('../src/core/tools/review.mjs');
const keys=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const privateKey=keys.privateKey.export({type:'pkcs8',format:'pem'});
fs.writeFileSync(path.join(temp,'key.p8'),privateKey,{mode:0o600});
fs.writeFileSync(path.join(temp,'config.json'),JSON.stringify({topic:'com.neox.app',keyId:'Z4YUMQ3P42',teamId:'JABNLDLN8G',keyPath:path.join(temp,'key.p8')}),{mode:0o600});
test('event validation accepts generic Relay contract, rejects old types and forged identities',()=>{
 assert.equal(validateReview(event).eventTemplate.type,'task.interactive_decision');
 assert.throws(()=>validateReview({...event,eventTemplate:{...template,type:'markcut.review.submitted'}}));
 assert.throws(()=>validateReview({...event,eventTemplate:{...template,type:'task.completed'}}));
 assert.throws(()=>validateReview({...event,eventTemplate:{...template,source:'job/j8/task/x/execution/e8'}}));
 assert.throws(()=>validateReview({...event,eventTemplate:{...template,data:{interactive:{...template.data.interactive,decision:'approved'}}}}));
 assert.throws(()=>validateReview({...event,ownerCallbackTool:'chatgpt'}));
 assert.throws(()=>validateReview({...event,delivery:'other'}));
 assert.throws(()=>validateReview({...r,contentHash:'bad'}));
 assert.throws(()=>validateRegistration({deviceId:ID,token:'bad',environment:'sandbox'}));
});
test('text without a thread can mirror preview to phone as view-only',()=>{
 assert.equal(validateReview(r).delivery,'text');
 assert.equal(payloadForReview(r).neoReviewRequestId,ID);
 assert.equal(payloadForReview(r).neoReview,undefined);
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
