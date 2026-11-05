import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
const script=fileURLToPath(new URL('../test-support/navigation-skill.lua',import.meta.url));
const directory=fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/client',import.meta.url));
function run(t,extra=[]) {
  const result=spawnSync('lua',[script,directory,...extra],{encoding:'utf8',timeout:5000});
  if(result.error?.code==='ENOENT'){t.skip('Lua unavailable');return;}
  assert.equal(result.status,0,`${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout,/passed 34 navigation skill Lua tests/);
}
test('navigation requires measured arrival, bounded progress and current queue ownership',t=>run(t));
test('navigation wraps the installed vanilla path action when available',t=>{
  const official=process.env.PZ_GAME_JAVA??`${homedir()}/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents/Java`;
  if(!existsSync(`${official}/media/lua/client/Vehicles/TimedActions/ISPathFindAction.lua`)){t.skip('Installed native path action unavailable');return;}
  run(t,[official]);
});
