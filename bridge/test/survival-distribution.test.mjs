import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const directories = ['mods/ClaudeSurvivor/42', 'mods/ClaudeSurvivor',
  'workshop/Contents/mods/ClaudeSurvivor/42', 'workshop/Contents/mods/ClaudeSurvivor'];
for (const name of ['client/ClaudeSurvivor.lua', 'client/ClaudeLabControl.lua',
  'client/ClaudeHealthFacts.lua', 'client/ClaudeWindowPolicy.lua', 'client/ClaudeWaterSkill.lua',
  'shared/ClaudeWaterFacts.lua', 'shared/TimedActions/ClaudeTakeWaterAction.lua',
  'shared/ClaudeTreatmentFacts.lua', 'client/ClaudeTreatmentSkill.lua', 'shared/TimedActions/ClaudeApplyBandageAction.lua',
  'client/ClaudePlaceMemory.lua', 'client/ClaudeNavigationSkill.lua']) {
  test(`${name} matches in all distributed mod versions`, () => {
    const copies = directories.map(directory => new URL(`${directory}/media/lua/${name}`, root));
    const canonical = readFileSync(copies[0], 'utf8');
    for (const copy of copies.slice(1)) assert.equal(readFileSync(copy, 'utf8'), canonical);
  });
}
