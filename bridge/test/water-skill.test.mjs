import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('water skill approaches, revalidates, and observes effects without claiming queue success', t => {
  const script = fileURLToPath(new URL('../test-support/water-skill.lua', import.meta.url));
  const directory = fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/client', import.meta.url));
  const result = spawnSync('lua', [script, directory], { encoding: 'utf8', timeout: 5000 });
  if (result.error?.code === 'ENOENT') { t.skip('Lua unavailable'); return; }
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /passed 25 water skill Lua tests/);
});
