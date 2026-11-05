import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('place memory records only bounded session-scoped visited anchors and temporary route failures', t => {
  const script=fileURLToPath(new URL('../test-support/place-memory.lua',import.meta.url));
  const directory=fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/client',import.meta.url));
  const result=spawnSync('lua',[script,directory],{encoding:'utf8',timeout:5000});
  if(result.error?.code==='ENOENT'){t.skip('Lua unavailable');return;}
  assert.equal(result.status,0,`${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout,/passed 31 place memory Lua tests/);
  const snapshots=result.stdout.split('\n').filter(line=>line.startsWith('JSON:')).map(line=>JSON.parse(line.slice(5)));
  assert.equal(snapshots.length,4);
  assert.equal(snapshots[0].scope,'current_session');
  assert.equal(snapshots[0].anchorCount,2);
  assert.equal(snapshots[0].anchors[0].room,'kitchen');
  assert.equal(snapshots[0].secret,undefined);
  assert.equal(snapshots[0].anchors[0].engine,undefined);
  assert.equal(snapshots[1].valid,false);
  assert.deepEqual(snapshots[1].anchors,[]);
  assert.equal(snapshots[2].anchorCount,null);
  assert.equal(snapshots[2].valid,null);
  assert.equal(snapshots[2].anchors[0].id,null);
  assert.equal(snapshots[2].anchors[0].x,null);
  assert.equal(snapshots[2].anchors[0].canNavigate,null);
  assert.equal(snapshots[2].anchors[0].origin,null);
  assert.equal(snapshots[2].anchors[0].room.length,128);
  assert.ok(snapshots[3].anchors.length<=24);
  assert.ok(snapshots[3].failures.length<=64);
});
