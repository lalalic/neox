import {test} from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const ID='8aad68fe-8892-4f88-8c58-4459197afb29';
const H='a'.repeat(64);
const r={id:ID,title:'Review E2E',contentHash:H,revisionId:H,ownerCallbackTool:'chatgpt',ownerThreadId:'6ae92acc-cd28-83ea-8dc6-224653c9b433'};
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'neox-apns-test-'));
process.env.NEOX_APNS_HOME=temp;
const {validateRegistration,validateReview,payloadForReview,signingJWT,registerDevice,notifyReview,status}=await import('./apns.mjs');
const keys=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const privateKey=keys.privateKey.export({type:'pkcs8',format:'pem'});
fs.writeFileSync(path.join(temp,'key.p8'),privateKey,{mode:0o600});
fs.writeFileSync(path.join(temp,'config.json'),JSON.stringify({topic:'com.neox.app',keyId:'Z4YUMQ3P42',teamId:'JABNLDLN8G',keyPath:path.join(temp,'key.p8')}),{mode:0o600});
test('request validation',()=>{
 assert.equal(validateReview(r).id,ID);
 assert.throws(()=>validateReview({...r,ownerCallbackTool:'neo.shell.exec'}));
 assert.throws(()=>validateReview({...r,ownerThreadId:undefined}));
 assert.throws(()=>validateReview({...r,contentHash:'bad'}));
 assert.throws(()=>validateRegistration({deviceId:ID,token:'bad',environment:'sandbox'}));
 const p=payloadForReview(r);assert.equal(p.neoReview.contentHash,H);assert.equal(p.aps.alert.body,'Review E2E');
});
test('jwt ES256 validates with public key',()=>{
 const jwt=signingJWT('Z4YUMQ3P42','JABNLDLN8G',privateKey,1700000000);
 const [hdr,claims,sig]=jwt.split('.');
 assert.equal(JSON.parse(Buffer.from(hdr,'base64url').toString()).kid,'Z4YUMQ3P42');
 assert.equal(JSON.parse(Buffer.from(claims,'base64url').toString()).iat,1700000000);
 assert.ok(crypto.verify('sha256',Buffer.from(hdr+'.'+claims),{key:keys.publicKey,dsaEncoding:'ieee-p1363'},Buffer.from(sig,'base64url')));
});
test('register saves only device metadata and APNs status is not delivery',async()=>{
 const deviceId='00000000-0000-4000-8000-000000000001';
 const rr=registerDevice({deviceId,token:'b'.repeat(64),environment:'sandbox'});
 assert.equal(rr.registered,true);assert.equal(status().deviceCount,1);
 assert.ok(!JSON.stringify(rr).includes('bbbb'));
 let count=0;
 const result=await notifyReview(r, async ({host,headers,bytes})=>{
  count++;assert.equal(host,'api.sandbox.push.apple.com');assert.equal(headers['apns-topic'],'com.neox.app');
  assert.equal(headers['apns-push-type'],'alert');assert.equal(JSON.parse(bytes).neoReview.id,ID);
  return {accepted:true,status:200,apnsId:ID};
 });
 assert.equal(result.accepted,true);assert.equal(count,1);
 assert.equal(result.status,'apns_submission');
 assert.ok(!JSON.stringify(result).includes('bbbb'));
});

test('event review push retains bound metadata and rejects forged destinations',()=>{
 const t={type:'markcut.review.submitted',source:'job/j8/task/producer/execution/e8',data:{correlation:{jobId:'j8'}}};
 const event={...r,ownerCallbackTool:undefined,ownerThreadId:undefined,
   delivery:'event',eventTemplate:t,previewId:'rev-preview-8'};
 const validated=validateReview(event);
 assert.equal(validated.delivery,'event');
 assert.deepEqual(payloadForReview(event).neoReview.eventTemplate,t);
 assert.equal(validated.previewId,'rev-preview-8');
 assert.throws(()=>validateReview({...event,eventTemplate:{...t,type:'task.completed'}}));
 assert.throws(()=>validateReview({...event,eventTemplate:{...t,source:'job/j8/task/x/execution/forged/more'}}));
 assert.throws(()=>validateReview({...event,eventTemplate:{...t,data:{review:{decision:'approved'}}}}));
 assert.throws(()=>validateReview({...event,delivery:'unknown'}));
});
