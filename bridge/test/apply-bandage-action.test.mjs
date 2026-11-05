import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script=fileURLToPath(new URL('../test-support/apply-bandage-action.lua',import.meta.url));
const directory=fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/shared',import.meta.url));
function run(t,extra=[]) {
  const result=spawnSync('lua',[script,directory,...extra],{encoding:'utf8',timeout:5000});
  if(result.error?.code==='ENOENT'){t.skip('Lua unavailable');return;}
  assert.equal(result.status,0,`${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout,/passed 35 apply bandage action Lua tests/);
}
test('shared self-bandaging guards native mutation, consumption and retained callbacks',t=>run(t));
test('shared self-bandaging guards the installed native medical parent',t=>{
  const official=process.env.PZ_GAME_JAVA??`${homedir()}/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents/Java`;
  if(!existsSync(`${official}/media/lua/shared/TimedActions/ISApplyBandage.lua`)){
    t.skip('Installed native medical parent unavailable');return;
  }
  run(t,[official]);
});
