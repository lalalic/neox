#!/usr/bin/env node
// Local Neo Master delivery bridge used by Markcut MCP and CLI; no phone listener.
import {readFileSync} from 'node:fs';
import {notifyReview} from './apns.mjs';
if(process.argv[2]!=='notify'){
  process.stderr.write('Usage: neox-apns review-cli.mjs notify < request.json\n');
  process.exit(2);
}
try{
  const input=JSON.parse(readFileSync(0,'utf8'));
  const result=await notifyReview(input);
  process.stdout.write(JSON.stringify(result)+'\n');
}catch(error){
  process.stderr.write('APNs review delivery: '+String(error?.message||error)+'\n');
  process.exitCode=1;
}
