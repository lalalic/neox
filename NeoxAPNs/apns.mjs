// Neo Mobile APNs sender. Stateless review messages, durable device tokens only.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import http2 from 'node:http2';

const BASE = process.env.NEOX_APNS_HOME ?? path.join(os.homedir(),'Library','Application Support','NeoY','apns');
const CONFIG_FILE = path.join(BASE,'config.json');
const TOKENS_FILE = path.join(BASE,'devices.json');
const HEX = /^[0-9a-f]{64,512}$/;
const SHA = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const THREAD = /^[a-zA-Z0-9_-]{8,160}$/;
const callback = x => x === 'chatgpt' || x === 'review.feedback' || /^[a-z0-9_-]+\.review\.feedback$/.test(x);

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
  assertValid(typeof a.contentHash === 'string' && SHA.test(a.contentHash),'Invalid content hash');
  assertValid(typeof a.revisionId === 'string' && a.revisionId.length >= 1 && a.revisionId.length <= 256,'Invalid revision');
  assertValid(typeof a.title === 'string' && a.title.trim().length >= 1 && a.title.length <= 180,'Invalid title');
  assertValid(typeof a.ownerCallbackTool === 'string' && callback(a.ownerCallbackTool),'Invalid owner callback');
  if (a.ownerCallbackTool === 'chatgpt') assertValid(typeof a.ownerThreadId === 'string' && THREAD.test(a.ownerThreadId),'ChatGPT owner thread required');
  const result={id:a.id.toLowerCase(),contentHash:a.contentHash,revisionId:a.revisionId,title:a.title,ownerCallbackTool:a.ownerCallbackTool};
  for(const k of ['ownerThreadId','groupId','groupTitle','jobId']) {
    if(a[k]===undefined || a[k]===null) continue;
    assertValid(typeof a[k]==='string' && a[k].length<=256,`Invalid ${k}`);
    result[k]=a[k];
  }
  return result;
}
export function payloadForReview(a) {
  const request=validateReview(a);
  const message={aps:{alert:{title:'Video ready for review',body:request.title},sound:'default'},neoReview:request};
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
  const d=devices();
  d.devices[r.deviceId]={token:r.token,environment:r.environment,updatedAt:new Date().toISOString()};
  // The device token never appears in tool results or notification logs.
  atomicJSON(TOKENS_FILE,d);
  return {registered:true,deviceId:r.deviceId,environment:r.environment};
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
    'apns-id':body.neoReview.id,'content-type':'application/json'};
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
export async function notifyReview(args,transport) {
  const body=payloadForReview(args), c=config(), all=devices();
  const ids=Object.keys(all.devices).filter(id=>!args.deviceId||id===args.deviceId.toLowerCase());
  if(ids.length===0) return {accepted:false,reason:'no registered device',deviceCount:0};
  const results=[];
  for(const id of ids){
    const dev=all.devices[id];
    try {
      const result=await sendAPNs(dev.token,dev.environment,body,c,transport);
      results.push({deviceId:id,accepted:result.accepted,status:result.status,reason:result.reason||undefined,apnsId:result.apnsId||undefined});
      if(result.status===410 || (result.status===400 && ['BadDeviceToken','DeviceTokenNotForTopic'].includes(result.reason))) {
        delete all.devices[id];atomicJSON(TOKENS_FILE,all);
      }
    } catch (error) {results.push({deviceId:id,accepted:false,reason:String(error.message).slice(0,150)});}
  }
  return {accepted:results.some(x=>x.accepted),status:'apns_submission',results};
}
