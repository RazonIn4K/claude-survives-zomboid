import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

test('water facts require local clean source, real reach and owned compatible vessel', t => {
  const module = fileURLToPath(new URL('../../mods/ClaudeSurvivor/42/media/lua/shared/ClaudeWaterFacts.lua', import.meta.url));
  const script = fileURLToPath(new URL('../test-support/water-facts.lua', import.meta.url));
  const result = spawnSync('lua', [script, module], { encoding: 'utf8', timeout: 10000 });
  if (result.error?.code === 'ENOENT') { t.skip('Lua is unavailable; water API fixtures were not tested.'); return; }
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /passed 39 water facts Lua tests/);
  const samples = new Map(result.stdout.split('\n').filter(line => line.startsWith('JSON ')).map(line => {
    const [, label, ...body] = line.split(' ');
    const encoded = body.join(' ');
    assert.ok(encoded.length <= 16384);
    return [label, JSON.parse(encoded)];
  }));
  assert.equal(samples.get('complete').sources[0].key, '100:100:0:0');
  assert.equal(samples.get('complete').sources[0].reachable, true);
  assert.equal(samples.get('complete').fillableVessels[0].key, 'item:42');
  assert.equal('source' in samples.get('complete').sources[0], false);
  assert.equal(samples.get('partial').valid, false);
  assert.equal(samples.get('partial').sources.length, 1);
  assert.equal(samples.get('unknown_reach').sources[0].reachable, null);
  assert.equal(samples.get('bounded').scannedItems, null);
  assert.equal(samples.get('bounded').sources.length, 8);
  assert.equal(samples.get('bounded').fillableVessels.length, 16);
  assert.equal(samples.get('bounded').sources[0].key, 'é'.repeat(128));
  assert.equal(samples.get('bounded').sources[0].x, null);
  assert.equal(samples.get('bounded').status, 'q"\\\n\r\t\0\x01');
  assert.equal('extra' in samples.get('bounded'), false);
  assert.equal(samples.get('missing').valid, false);
});
