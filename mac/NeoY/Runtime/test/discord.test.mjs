import test from 'node:test';
import assert from 'node:assert/strict';
import { DISCORD_TOOLS, handleDiscord } from '../src/core/tools/discord.mjs';

test('discord reply only delivers an authorized correlation to loopback gateway',async()=>{
  assert.deepEqual(DISCORD_TOOLS[0].inputSchema.required,['correlationId','text']);
  let requested;
  const receipt=await handleDiscord('discord_reply',{correlationId:'a'.repeat(36),text:'hello'},{
    fetchImpl:async(url,options)=>{
      requested={url:String(url),options};
      return {ok:true,json:async()=>({ok:true,messageId:'123'})};
    }
  });
  assert.equal(receipt.messageId,'123');
  assert.match(requested.url,/127\.0\.0\.1/);
  assert.equal(JSON.parse(requested.options.body).text,'hello');
  await assert.rejects(handleDiscord('discord_reply',{correlationId:'a',text:'test'},{
    endpoint:'https://example.com/discord',fetchImpl:async()=>{throw Error('must not call network');}
  }),/loopback/);
});
