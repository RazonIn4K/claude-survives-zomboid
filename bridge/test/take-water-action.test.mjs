import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = fileURLToPath(new URL('../test-support/take-water-action.lua', import.meta.url));
const directory = fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/shared', import.meta.url));
function run(t, extra = []) {
  const result = spawnSync('lua', [script, directory, ...extra], { encoding: 'utf8', timeout: 5000 });
  if (result.error?.code === 'ENOENT') {
    t.skip('Lua is not installed; shared water action checks were not run.');
    return;
  }
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /passed 28 take water action Lua tests/);
}
test('shared water action checks authority and current facts at native mutation', t => run(t));
test('shared water action guards the installed native parent when available', t => {
  const official = process.env.PZ_GAME_JAVA ?? `${homedir()}/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents/Java`;
  if (!existsSync(`${official}/media/lua/shared/TimedActions/ISTakeWaterAction.lua`)) {
    t.skip('Installed Project Zomboid native parent unavailable; portable checks still run.');
    return;
  }
  run(t, [official]);
});
