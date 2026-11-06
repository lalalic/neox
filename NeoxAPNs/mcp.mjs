#!/usr/bin/env node
// NeoY federated provider, no second listening port or authentication surface.
import readline from 'node:readline';
import {registerDevice, notifyReview, pendingReviews, completeReview, status} from './apns.mjs';
const descriptors=[
  {name:'review.push.register',description:'Register the calling Neo Mobile app APNs token with Neo Master.',
    inputSchema:{type:'object',additionalProperties:false,required:['deviceId','token','environment'],properties:{deviceId:{type:'string'},token:{type:'string'},environment:{type:'string',enum:['sandbox','production']}}}},
  {name:'review.push.notify',description:'Persist an immutable Markcut review on Neo Master, then notify registered iPhones through Apple APNs. Push receipt is not user delivery.',
    inputSchema:{type:'object',additionalProperties:false,required:['id','contentHash','revisionId','title'],properties:{
      id:{type:'string'},contentHash:{type:'string'},revisionId:{type:'string'},title:{type:'string'},
      delivery:{type:'string',enum:['text','event']},previewId:{type:'string'},eventTemplate:{type:'object'},
      ownerCallbackTool:{type:'string'},ownerThreadId:{type:'string'},groupId:{type:'string'},groupTitle:{type:'string'},jobId:{type:'string'},deviceId:{type:'string'}}}},
  {name:'review.push.pending',description:'Fetch durable outstanding reviews from Neo Master on foreground or push notification.',inputSchema:{type:'object',properties:{},additionalProperties:false}},
  {name:'review.push.complete',description:'Acknowledge an accepted human review decision and retire the pending request.',inputSchema:{type:'object',required:['id'],properties:{id:{type:'string'}},additionalProperties:false}},
  {name:'review.push.status',description:'Read APNs configuration and registered device count without exposing tokens or private keys.',inputSchema:{type:'object',properties:{},additionalProperties:false}}
];
function respond(id,result){process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\n');}
function asResult(data){return {content:[{type:'text',text:JSON.stringify(data)}],structuredContent:data,isError:false};}
function fail(id,error){respond(id,{content:[{type:'text',text:String(error.message)}],isError:true});}
const transport=readline.createInterface({input:process.stdin,crlfDelay:Infinity});
for await(const line of transport){
  let msg;try{msg=JSON.parse(line);}catch{continue;}
  if(msg.id===undefined)continue;
  const {method,params={},id}=msg;
  try{
    if(method==='initialize'){
      respond(id,{protocolVersion:params.protocolVersion||'2025-06-18',capabilities:{tools:{listChanged:false}},serverInfo:{name:'neox-apns',version:'1.0.0'}});
    } else if(method==='ping')respond(id,{});
    else if(method==='tools/list')respond(id,{tools:descriptors});
    else if(method==='tools/call'){
      const a=params.arguments||{};
      if(params.name==='review.push.register')respond(id,asResult(registerDevice(a)));
      else if(params.name==='review.push.notify')respond(id,asResult(await notifyReview(a)));
      else if(params.name==='review.push.pending')respond(id,asResult(pendingReviews()));
      else if(params.name==='review.push.complete')respond(id,asResult(completeReview(a)));
      else if(params.name==='review.push.status')respond(id,asResult(status()));
      else fail(id,new Error('Unknown tool'));
    } else process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,error:{code:-32601,message:'Unknown method'}})+'\n');
  }catch(error){fail(id,error);}
}
