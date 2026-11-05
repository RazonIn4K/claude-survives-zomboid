import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root=new URL('../../',import.meta.url);
const copies=['mods/ClaudeSurvivor/42','mods/ClaudeSurvivor',
  'workshop/Contents/mods/ClaudeSurvivor/42','workshop/Contents/mods/ClaudeSurvivor']
  .map(directory=>new URL(`${directory}/media/lua/client/ClaudeActionEvidence.lua`,root));
test('action evidence distribution copies remain identical',()=>{
  const canonical=readFileSync(copies[0],'utf8');
  for(const copy of copies.slice(1)) assert.equal(readFileSync(copy,'utf8'),canonical);
});
test('action evidence requires observable effects rather than queue completion',t=>{
  const script=fileURLToPath(new URL('../test-support/action-evidence.lua',import.meta.url));
  const result=spawnSync('lua',[script,fileURLToPath(copies[0])],{encoding:'utf8',timeout:5000});
  if(result.error?.code==='ENOENT') { t.skip('Lua is unavailable; observation receipts were not tested.'); return; }
  assert.equal(result.status,0,`${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout,/passed 13 action evidence Lua tests/);
});
