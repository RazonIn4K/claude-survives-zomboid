import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('health facts report actual supported injury states and explicit unknowns',t=>{
  const module=fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/client/ClaudeHealthFacts.lua',import.meta.url));
  const script=fileURLToPath(new URL('../test-support/health-facts.lua',import.meta.url));
  const result=spawnSync('lua',[script,module],{encoding:'utf8',timeout:5000});
  if(result.error?.code==='ENOENT'){t.skip('Lua is unavailable; health API fixtures were not tested.');return;}
  assert.equal(result.status,0,`${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout,/passed 24 health facts Lua tests/);
  const samples=new Map(result.stdout.split('\n').filter(line=>line.startsWith('JSON ')).map(line=>{
    const [,label,...body]=line.split(' ');
    const encoded=body.join(' ');assert.ok(encoded.length<=32768);
    return [label,JSON.parse(encoded)];
  }));
  assert.deepEqual(samples.get('healthy').injuries,[]);
  assert.equal(samples.get('injured').injuries[1].glass,true);
  assert.equal(samples.get('partial').valid,false);
  assert.equal(samples.get('healthy').expectedParts,17);
  assert.equal(samples.get('partial').summary.unknownParts,16);
  assert.equal(samples.get('truncated').valid,false);
  assert.equal(samples.get('truncated').expectedParts,17);
  assert.equal(samples.get('truncated').summary.unknownParts,16);
  assert.equal(samples.get('escaped').injuries[0].name,'q"\\\n\r\t\0\x01\x1f');
  assert.equal(samples.get('nonfinite').partCount,null);
  assert.equal(samples.get('nonfinite').injuries[0].index,null);
  assert.equal(samples.get('nonfinite').summary.glassParts,null);
  assert.equal('extra' in samples.get('nonfinite'),false);
  assert.equal(samples.get('bounded').injuries.length,32);
  assert.equal(samples.get('bounded').injuries[0].name,'é'.repeat(128));
  assert.equal(samples.get('malformed_text').injuries[0].name,'�'.repeat(3));
  assert.equal(samples.get('missing').valid,false);
});
