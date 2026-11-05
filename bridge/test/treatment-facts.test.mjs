import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('self-treatment facts require an owned supported wound and clean single-use supply', t => {
  const script=fileURLToPath(new URL('../test-support/treatment-facts.lua',import.meta.url));
  const directory=fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/shared',import.meta.url));
  const result=spawnSync('lua',[script,directory],{encoding:'utf8',timeout:5000});
  if(result.error?.code==='ENOENT'){t.skip('Lua unavailable');return;}
  assert.equal(result.status,0,`${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout,/passed 32 treatment facts Lua tests/);
  const json=result.stdout.split('\n').filter(line=>line.startsWith('JSON:')).map(line=>JSON.parse(line.slice(5)));
  assert.equal(json.length,3);assert.equal(json[0].eligibleWounds[0].index,0);
  assert.equal(json[0].supplies[0].key,'item:1');assert.equal(json[0].secret,undefined);
  assert.equal(json[1].valid,false);assert.deepEqual(json[1].supplies,[]);
  assert.equal(json[2].scannedParts,null);assert.equal(json[2].eligibleWounds[0].index,null);
  assert.equal(json[2].supplies[0].name.length,128);
});
