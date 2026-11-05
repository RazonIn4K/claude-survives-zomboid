import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const directories = ['mods/ClaudeSurvivor/42', 'mods/ClaudeSurvivor',
  'workshop/Contents/mods/ClaudeSurvivor/42', 'workshop/Contents/mods/ClaudeSurvivor'];
for (const name of ['ClaudeSurvivor.lua', 'ClaudeLabControl.lua', 'ClaudeHealthFacts.lua', 'ClaudeWindowPolicy.lua']) {
  test(`${name} matches in all distributed mod versions`, () => {
    const copies = directories.map(directory => new URL(`${directory}/media/lua/client/${name}`, root));
    const canonical = readFileSync(copies[0], 'utf8');
    for (const copy of copies.slice(1)) assert.equal(readFileSync(copy, 'utf8'), canonical);
  });
}
