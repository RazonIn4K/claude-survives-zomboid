import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const modulePath = 'media/lua/client/ClaudeThreatFacts.lua';
const directories = ['mods/ClaudeSurvivor/42', 'mods/ClaudeSurvivor',
  'workshop/Contents/mods/ClaudeSurvivor/42', 'workshop/Contents/mods/ClaudeSurvivor'];

test('complete bounded threat observations distinguish all-clear from unknown and partial scans', t => {
  const module = fileURLToPath(new URL(`${directories[0]}/${modulePath}`, root));
  const script = fileURLToPath(new URL('../test-support/threat-facts.lua', import.meta.url));
  const result = spawnSync('lua', [script, module], { encoding: 'utf8', timeout: 5000 });
  if (result.error?.code === 'ENOENT') { t.skip('Lua unavailable; threat observations were not tested.'); return; }
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /passed 22 threat facts Lua tests/);
  const samples = new Map(result.stdout.split('\n').filter(line => line.startsWith('JSON ')).map(line => {
    const [, label, ...body] = line.split(' ');
    return [label, JSON.parse(body.join(' '))];
  }));
  assert.deepEqual(samples.get('empty'), { valid: true, status: 'observed', scanned: 0, limit: 16384, error: null });
  assert.equal(samples.get('missing').valid, false);
  assert.equal(samples.get('missing').status, 'unknown');
  assert.equal(samples.get('partial').valid, false);
  assert.equal(samples.get('partial').status, 'partial');
  assert.equal(samples.get('bounded').scanned, 16384);
  assert.equal(samples.get('bounded').error, 'threat_scan_bounded');
});

test('threat facts are identical in all four distributed mod versions', () => {
  const canonical = readFileSync(new URL(`${directories[0]}/${modulePath}`, root), 'utf8');
  for (const directory of directories.slice(1)) {
    assert.equal(readFileSync(new URL(`${directory}/${modulePath}`, root), 'utf8'), canonical);
  }
});
