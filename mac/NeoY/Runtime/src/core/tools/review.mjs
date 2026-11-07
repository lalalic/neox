// Neo Master durable review inbox and APNs pointer-only notification transport.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import http2 from 'node:http2';
import {fileURLToPath} from 'node:url';

const BASE = process.env.NEO_APNS_HOME ?? path.join(os.homedir(),'Library','Application Support','NeoY','apns');
const CONFIG_FILE = path.join(BASE,'config.json');
const TOKENS_FILE = path.join(BASE,'devices.json');
const REVIEWS_FILE = path.join(BASE,'reviews.json');
const HEX = /^[0-9a-f]{64,512}$/;
const SHA = /^[0-9a-f]{64}$/;
const GIT_SHA = /^[0-9a-f]{40}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const THREAD = /^[a-zA-Z0-9_-]{8,160}$/;
const callback = x => x === 'chatgpt' || x === 'review.feedback' || /^[a-z0-9_-]+\.review\.feedback$/.test(x);
const SOURCE=/^job\/([A-Za-z0-9_-]+)\/task\/([A-Za-z0-9_-]+)\/execution\/([A-Za-z0-9_-]+)$/;
const RESERVED=['decision','feedback','comments','revision','revisionId','contentHash','commitSha','previewId','requestId','idempotencyKey'];

function assertValid(ok, message) { if (!ok) throw new Error(message); }
export function validateRegistration(a) {
  assertValid(a && typeof a === 'object','Registration required');
  assertValid(typeof a.deviceId === 'string' && UUID.test(a.deviceId),'Invalid device ID');
  assertValid(typeof a.token === 'string' && HEX.test(a.token),'Invalid APNs device token');
  assertValid(['sandbox','production'].includes(a.environment),'Invalid APNs environment');
  return {deviceId:a.deviceId.toLowerCase(),token:a.token,environment:a.environment};
}
export function validateReview(a) {
  assertValid(a && typeof a === 'object','Review request required');
  assertValid(typeof a.id === 'string' && UUID.test(a.id),'Invalid request UUID');
  assertValid(typeof a.title === 'string' && a.title.trim().length >= 1 && a.title.length <= 180,'Invalid title');
  const delivery=a.delivery||'text';
  assertValid(delivery==='text'||delivery==='event','Unsupported review delivery');
  if(delivery==='event'){
    assertValid(typeof a.commitSha==='string' && GIT_SHA.test(a.commitSha),'Invalid Git Commit SHA');
    assertValid(typeof a.mediaHash==='string' && SHA.test(a.mediaHash),'Invalid compiled media hash');
    assertValid(a.contentHash===undefined && a.revisionId===undefined,'Event review must use Git SHA only');
    const t=a.eventTemplate;
    assertValid(t && typeof t==='object' && !Array.isArray(t),'Missing event template');
    assertValid(t.type==='task.interactive_decision','Unsafe review event type');
    const match=typeof t.source==='string' ? t.source.match(SOURCE) : null;
    assertValid(Boolean(match),'Invalid event source');
    assertValid(t.data && typeof t.data==='object' && !Array.isArray(t.data),'Invalid event data');
    const fixed=t.data.interactive;
    assertValid(fixed && typeof fixed==='object' && !Array.isArray(fixed) &&
      fixed.jobId===match[1] && fixed.taskId===match[2] && fixed.executionId===match[3] &&
      typeof fixed.invocationId==='string' && /^[A-Za-z0-9_-]{1,128}$/.test(fixed.invocationId) &&
      RESERVED.every(k=>!Object.hasOwn(fixed,k)),'Invalid interactive identity or reserved fields');
    assertValid(Object.keys(t).every(k=>['type','source','data'].includes(k)),'Invalid event template fields');
    assertValid(a.ownerCallbackTool===undefined && a.ownerThreadId===undefined,'Event cannot carry owner callback');
  }else{
    assertValid(typeof a.contentHash === 'string' && SHA.test(a.contentHash),'Invalid content hash');
    assertValid(typeof a.revisionId === 'string' && a.revisionId.length >= 1 && a.revisionId.length <= 256,'Invalid revision');
    assertValid(a.commitSha===undefined && a.mediaHash===undefined,'Text reviews use standalone preview identity');
    assertValid(a.eventTemplate===undefined,'Text mode cannot carry event template');
    // Standalone ChatGPT text previews are still mirrored to iPhone for viewing;
    // without an owner thread they are read-only in the mobile inbox.
    assertValid(a.ownerCallbackTool===undefined || callback(a.ownerCallbackTool),'Invalid owner callback');
    if(a.ownerCallbackTool==='chatgpt'){
      assertValid(typeof a.ownerThreadId==='string' && THREAD.test(a.ownerThreadId),'ChatGPT owner thread required');
    }
  }
  const result={id:a.id.toLowerCase(),title:a.title,
    ...(delivery==='event'?{commitSha:a.commitSha,mediaHash:a.mediaHash}:{contentHash:a.contentHash,revisionId:a.revisionId})};
  if(a.delivery)result.delivery=delivery;
  if(a.ownerCallbackTool)result.ownerCallbackTool=a.ownerCallbackTool;
  if(a.eventTemplate)result.eventTemplate=JSON.parse(JSON.stringify(a.eventTemplate));
  if(a.previewId){
    assertValid(typeof a.previewId==='string' && a.previewId.length<=256,'Invalid previewId');
    result.previewId=a.previewId;
  }
  for(const k of ['ownerThreadId','groupId','groupTitle','jobId']) {
    if(a[k]===undefined || a[k]===null) continue;
    assertValid(typeof a[k]==='string' && a[k].length<=256,`Invalid ${k}`);
    result[k]=a[k];
  }
  return result;
}
export function payloadForReview(a) {
  const request=validateReview(a);
  // APNs is a wake-up hint; the full request and immutable template are stored
  // on Neo Master and fetched via the phone's authenticated MCP connection.
  const actionable=request.delivery==='event' || Boolean(request.ownerCallbackTool||request.ownerThreadId);
  const message={aps:{alert:{title:actionable?'Video ready for review':'Video preview ready',body:request.title},sound:'default'},neoReviewRequestId:request.id};
  assertValid(Buffer.byteLength(JSON.stringify(message))<=4096,'APNs payload too large');
  return message;
}

export function signingJWT(keyId, teamId, key, now=Math.floor(Date.now()/1000)) {
  assertValid(/^[A-Z0-9]{10}$/.test(keyId) && /^[A-Z0-9]{10}$/.test(teamId),'Invalid APNs key/team ID');
  const b64=obj=>Buffer.from(JSON.stringify(obj)).toString('base64url');
  const message=b64({alg:'ES256',kid:keyId})+'.'+b64({iss:teamId,iat:now});
  const signature=crypto.sign('sha256',Buffer.from(message),{key,dsaEncoding:'ieee-p1363'});
  return message+'.'+signature.toString('base64url');
}
function atomicJSON(file,obj) {
  fs.mkdirSync(path.dirname(file),{recursive:true,mode:0o700});
  const tmp=file+'.tmp-'+process.pid;
  fs.writeFileSync(tmp,JSON.stringify(obj),{mode:0o600});
  fs.renameSync(tmp,file);
  fs.chmodSync(file,0o600);
}
function readJSON(file,fallback) {try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch(e){if(e.code==='ENOENT')return fallback;throw e;}}
function config() {
  const c=readJSON(CONFIG_FILE,{});
  assertValid(c.topic==='com.neox.app','APNs topic is not configured');
  assertValid(typeof c.keyPath==='string' && fs.existsSync(c.keyPath),'APNs private key is unavailable');
  return c;
}
function devices() {const d=readJSON(TOKENS_FILE,{version:1,devices:{}});return d;}
export function registerDevice(arguments_) {
  const r=validateRegistration(arguments_);
  return withDeviceLock(()=>{
    const d=devices();
    d.devices[r.deviceId]={token:r.token,environment:r.environment,updatedAt:new Date().toISOString()};
    // The device token never appears in tool results or notification logs.
    atomicJSON(TOKENS_FILE,d);
    return {registered:true,deviceId:r.deviceId,environment:r.environment};
  });
}
export function status() {
  const d=devices();const c=readJSON(CONFIG_FILE,{});
  return {configured:Boolean(c.keyPath&&fs.existsSync(c.keyPath)&&c.keyId&&c.teamId),deviceCount:Object.keys(d.devices).length,deviceIDs:Object.keys(d.devices)};
}
export async function sendAPNs(token,environment,body,c,transport) {
  const host=environment==='sandbox'?'api.sandbox.push.apple.com':'api.push.apple.com';
  const jwt=signingJWT(c.keyId,c.teamId,fs.readFileSync(c.keyPath,'utf8'));
  const bytes=Buffer.from(JSON.stringify(body));
  const headers={':method':'POST',':path':'/3/device/'+token,'authorization':'bearer '+jwt,
    'apns-topic':c.topic,'apns-push-type':'alert','apns-priority':'10',
    'apns-expiration':String(Math.floor(Date.now()/1000)+86400),
    'apns-id':body.neoReviewRequestId,'apns-collapse-id':body.neoReviewRequestId,'content-type':'application/json'};
  if(transport) return transport({host,headers,bytes});
  return await new Promise((resolve,reject)=>{
    const conn=http2.connect('https://'+host);let responseStatus=0,apnsId='',data='';
    const timer=setTimeout(()=>{conn.destroy();reject(new Error('APNs timeout'));},12000);
    const cleanup=()=>{clearTimeout(timer);conn.close();};
    conn.on('error',e=>{cleanup();reject(e);});
    const stream=conn.request(headers);
    stream.on('response',h=>{responseStatus=h[':status'];apnsId=h['apns-id']||'';});
    stream.on('data',x=>{if(data.length<2000)data+=x;});
    stream.on('end',()=>{cleanup();let reason='';try{reason=JSON.parse(data).reason||'';}catch{}
      resolve({status:responseStatus,accepted:responseStatus===200,apnsId,reason});
    });
    stream.on('error',e=>{cleanup();reject(e);});
    stream.end(bytes);
  });
}
// The resident Core process and the Neo wrapper's short-lived CLI process
// share durable data; serialize read/modify/write by file across processes.
function withFileLock(file,action){
  fs.mkdirSync(BASE,{recursive:true,mode:0o700});
  const lock=file+'.lock';
  let fd;
  for(let i=0;i<100;i++){
    try{fd=fs.openSync(lock,'wx',0o600);break;}
    catch(error){
      if(error.code!=='EEXIST')throw error;
      try{if(Date.now()-fs.statSync(lock).mtimeMs>30000)fs.unlinkSync(lock);}catch{}
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,20);
    }
  }
  if(fd===undefined)throw new Error('Neo Core storage is busy');
  try{return action();}
  finally{fs.closeSync(fd);try{fs.unlinkSync(lock);}catch{}}
}
function withReviewLock(action){return withFileLock(REVIEWS_FILE,action);}
function withDeviceLock(action){return withFileLock(TOKENS_FILE,action);}
function reviewStore(){
  const value=readJSON(REVIEWS_FILE,{version:1,requests:{},completed:{}});
  assertValid(value && value.version===1 && value.requests && typeof value.requests==='object', 'Corrupt persisted reviews');
  value.completed??={};
  return value;
}
// One Neo Master account owns its review inbox. All registered devices can
// synchronize it; the existing authenticated MCP gateway controls access.
export function pendingReviews(){
  const store=reviewStore();
  const cutoff=Date.now()-30*86400000;
  return {requests:Object.values(store.requests)
    .filter(x=>Date.parse(x.createdAt)>=cutoff)
    .sort((a,b)=>b.createdAt.localeCompare(a.createdAt))
    .slice(0,500).map(x=>({...x.review,createdAt:x.createdAt}))};
}
export function completeReview({id}){
  assertValid(typeof id==='string' && UUID.test(id),'Invalid review request ID');
  return withReviewLock(()=>{
    const store=reviewStore(),key=id.toLowerCase();
    const existed=Boolean(store.requests[key]);
    if(existed){
      delete store.requests[key];
      store.completed[key]=new Date().toISOString();
      const cutoff=Date.now()-30*86400000;
      for(const [old,date] of Object.entries(store.completed)){
        if(Date.parse(date)<cutoff)delete store.completed[old];
      }
      atomicJSON(REVIEWS_FILE,store);
    }
    return {acknowledged:true,id:key,wasPending:existed};
  });
}
export async function notifyReview(args,transport){
  const review=validateReview(args), body=payloadForReview(review);
  const duplicate=withReviewLock(()=>{
    const store=reviewStore();
    assertValid(!store.completed[review.id], 'Review request was already completed');
    const prior=store.requests[review.id];
    if(prior){
      assertValid(JSON.stringify(prior.review)===JSON.stringify(review),'Conflicting request ID');
    }else{
      store.requests[review.id]={createdAt:new Date().toISOString(),review};
      const cutoff=Date.now()-30*86400000;
      for(const [id,record] of Object.entries(store.requests)){
        if(Date.parse(record.createdAt)<cutoff)delete store.requests[id];
      }
      atomicJSON(REVIEWS_FILE,store);
    }
    return Boolean(prior);
  });
  // A repeated request ID after an uncertain ACK retries the wake-up only;
  // the durable inbox never duplicates the request.
  let c,all;
  try{c=config();all=devices();}catch(error){
    return {stored:true,accepted:false,duplicate,reason:String(error.message).slice(0,150),requestId:review.id};
  }
  const ids=Object.keys(all.devices).filter(id=>!args.deviceId||id===args.deviceId.toLowerCase());
  if(ids.length===0)return {stored:true,accepted:false,duplicate,reason:'no registered device',deviceCount:0,requestId:review.id};
  const results=[];
  for(const id of ids){
    const dev=all.devices[id];
    try{
      const result=await sendAPNs(dev.token,dev.environment,body,c,transport);
      results.push({deviceId:id,accepted:result.accepted,status:result.status,reason:result.reason||undefined,apnsId:result.apnsId||undefined});
      if(result.status===410 || (result.status===400 && ['BadDeviceToken','DeviceTokenNotForTopic'].includes(result.reason))){
        // Only remove the exact token rejected by Apple. A registration may
        // have refreshed this device during the network request.
        withDeviceLock(()=>{
          const current=devices();
          if(current.devices[id]?.token===dev.token &&
             current.devices[id]?.environment===dev.environment){
            delete current.devices[id];atomicJSON(TOKENS_FILE,current);
          }
        });
      }
    }catch(error){results.push({deviceId:id,accepted:false,reason:String(error.message).slice(0,150)});}
  }
  return {stored:true,accepted:results.some(x=>x.accepted),duplicate,
    requestId:review.id,status:'apns_submission',results};
}

// Private Core service driver. Neo.app's HTTP router owns transport and auth.
// This script is never federated or exposed as an MCP Tool.
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const action=process.argv[2];
  if(!['register','pending','complete','notify'].includes(action)){
    process.stderr.write('Unknown Core mobile review service action\n');
    process.exitCode=2;
  }else{
    try{
      const input=action==='pending'?{}:JSON.parse(fs.readFileSync(0,'utf8'));
      const result=action==='register' ? registerDevice(input)
        : action==='pending' ? pendingReviews()
        : action==='complete' ? completeReview(input)
        : await notifyReview(input);
      process.stdout.write(JSON.stringify(result)+'\n');
    }catch(error){
      process.stderr.write('Core mobile review: '+String(error?.message||error).slice(0,300)+'\n');
      process.exitCode=1;
    }
  }
}
