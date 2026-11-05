import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
test('self-bandaging requires dressing and exact supply-consumption observations', t => {
  const script=fileURLToPath(new URL('../test-support/treatment-skill.lua',import.meta.url));
  const directory=fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/client',import.meta.url));
  const result=spawnSync('lua',[script,directory],{encoding:'utf8',timeout:5000});
  if(result.error?.code==='ENOENT'){t.skip('Lua unavailable');return;}
  assert.equal(result.status,0,`${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout,/passed 19 treatment skill Lua tests/);
});
