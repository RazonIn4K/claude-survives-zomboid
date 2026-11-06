import assert from 'node:assert/strict';
import test from 'node:test';
import { PriorityCoordinator } from '../priority.mjs';

const subject = { world: 'fixture-world', actor: '0', session: 'fixture-session' };
const supply = (id = 11) => ({ key: `item:${id}`, name: 'Bandage', fullType: 'Base.Bandage' });
const wound = (index = 1) => ({ index, name: `Part_${index}` });
const treatment = changes => ({ valid: true, status: 'observed', eligibleWounds: [wound()], supplies: [supply()], ...changes });
const command = (seq = 1, action = 'BANDAGE', changes = {}) => ({ ...subject, seq, action, ...changes });

function fixture({ enabled = true } = {}) {
  let now = 100000;
  const run = new PriorityCoordinator({ enabled, now: () => now });
  const percept = changes => ({ ...subject, labProtocol: 1, bodyRevision: 'priority-1',
    capabilities: { idleSelfCare: 'bandage_only' }, observed_ms: now, dead: false, armed: true,
    hp: 100, hunger: 0.3, thirst: 0.1, qlen: 0, nativeBusy: false, traversingWindow: false,
    threats: { valid: true }, zTotal: 0, zDist: -1, reflexed: false, lastSeq: 0,
    treatment: treatment(), ...changes });
  const publish = (seq = 1, changes = {}) => {
    const p = percept({ lastSeq: seq - 1, ...changes });
    const selected = run.candidate(p);
    assert.ok(selected, run.snapshot().localBlocker);
    assert.equal(run.published(command(seq), { origin: 'self_care', candidate: selected }), true);
    return selected;
  };
  const receipt = (seq = 1, status = 'observed_effect', changes = {}) => ({ ...command(seq), status,
    bandaged: true, consumed: true, bleedingAfter: true, partIndex: 1, supplyKey: 'item:11', ...changes });
  const complete = (seq = 1, changes = {}) => run.observe(percept({ lastSeq: seq,
    actionOutcome: receipt(seq), treatment: treatment({ eligibleWounds: [], supplies: [] }), ...changes }));
  return { run, percept, publish, receipt, complete, advance: ms => { now += ms; }, time: () => now };
}

test('a supported current wound and carried supply produce a bounded local candidate', () => {
  const { run, percept } = fixture();
  assert.deepEqual(run.candidate(percept()), { action: 'BANDAGE', reason: 'supported_bleeding_wound',
    partIndex: 1, supplyKey: 'item:11', signature: JSON.stringify(['fixture-world', '0', 'fixture-session', 1, 'item:11']) });
  assert.equal(run.busy(), false);
  assert.equal(run.epoch, 0);
});

test('disabled automatic care still reserves and acknowledges model commands', () => {
  const { run, percept } = fixture({ enabled: false });
  assert.equal(run.candidate(percept()), null);
  assert.equal(run.snapshot().localBlocker, 'automatic_care_disabled');
  assert.equal(run.published(command(1, 'WAIT'), { origin: 'model' }), true);
  assert.equal(run.busy(), true);
  assert.equal(run.observe(percept({ lastSeq: 1 })).status, 'acknowledged_idle');
  assert.equal(run.busy(), false);
  assert.equal(run.epoch, 0);
  assert.equal(run.published(command(2), { origin: 'self_care', candidate: {} }), false);
});

test('unknown, stale, disarmed, dead, invalid vitals and unsupported body never start automatic care', () => {
  const { run, percept, time } = fixture();
  const changes = [
    { observed_ms: time() - 3001 }, { observed_ms: time() + 501 }, { observed_ms: null },
    { labProtocol: 2 }, { world: '../invalid' }, { lastSeq: -1 }, { lastSeq: 1.5 },
    { armed: false }, { armed: null }, { dead: true }, { dead: null },
    { hp: NaN }, { hp: 0 }, { hp: 101 }, { hunger: -0.1 }, { hunger: Infinity }, { hunger: 1.1 },
    { thirst: null }, { thirst: -0.1 }, { thirst: 1.1 },
    { bodyRevision: 'nav-1' }, { capabilities: {} }, { capabilities: { idleSelfCare: true } },
  ];
  for (const change of changes) assert.equal(run.candidate(percept(change)), null, JSON.stringify(change));
  assert.equal(run.candidate(null), null);
  assert.ok(run.candidate(percept({ observed_ms: time() - 3000 })));
  assert.ok(run.candidate(percept({ observed_ms: time() + 500 })));
});

test('native work, unknown queue, window traversal, and pending evidence block automatic care', () => {
  const { run, percept } = fixture();
  for (const change of [{ qlen: 1 }, { qlen: -1 }, { qlen: null }, { nativeBusy: true }, { nativeBusy: null },
    { traversingWindow: true }, { traversingWindow: null }, { actionOutcome: { status: 'pending' } }]) {
    assert.equal(run.candidate(percept(change)), null, JSON.stringify(change));
    assert.equal(run.snapshot().localBlocker, 'body_not_known_idle');
  }
});

test('known absence or distance beyond the full reflex radius is required', () => {
  const { run, percept } = fixture();
  for (const change of [{ threats: null }, { threats: { valid: false } }, { threats: { valid: 1 } },
    { zTotal: null }, { zTotal: -1 }, { zTotal: 1.5 }, { zTotal: 1000001 }, { zDist: NaN },
    { zTotal: 0, zDist: 20 }, { zTotal: 1, zDist: -1 }, { zTotal: 1, zDist: 10.5 },
    { zTotal: 1, zDist: 11 }, { reflexed: true }, { reflexed: undefined }]) {
    assert.equal(run.candidate(percept(change)), null, JSON.stringify(change));
    assert.equal(run.snapshot().localBlocker, 'known_clear_reflex_radius_required');
  }
  assert.ok(run.candidate(percept({ zTotal: 2, zDist: 11.01 })));
});

test('partial, malformed, duplicate and oversized treatment facts cannot select an item', () => {
  const { run, percept } = fixture();
  const changes = [null, treatment({ valid: false }), treatment({ status: 'partial' }),
    treatment({ eligibleWounds: null }), treatment({ supplies: {} }),
    treatment({ eligibleWounds: [wound(), wound()] }), treatment({ eligibleWounds: [wound(-1)] }),
    treatment({ eligibleWounds: [wound(32)] }), treatment({ eligibleWounds: [{ index: 1, name: '<part>' }] }),
    treatment({ supplies: [supply(), supply()] }), treatment({ supplies: [{ ...supply(), name: 'DirtyBandage' }] }),
    treatment({ supplies: [{ ...supply(), fullType: 'Mod.Bandage' }] }),
    treatment({ supplies: [{ ...supply(), key: 'item:01' }] }),
    treatment({ supplies: [{ ...supply(), key: 'item:9007199254740992' }] }),
    treatment({ supplies: [{ ...supply(), key: 'item:-1' }] }),
    treatment({ eligibleWounds: Array.from({ length: 33 }, (_, i) => wound(i)) }),
    treatment({ supplies: Array.from({ length: 17 }, (_, i) => supply(i)) }),
  ];
  for (const value of changes) {
    assert.equal(run.candidate(percept({ treatment: value })), null);
    assert.equal(run.snapshot().localBlocker, 'complete_treatment_observation_required');
  }
  assert.ok(run.candidate(percept({ treatment: treatment({ supplies: [supply(0)] }) })));
  assert.ok(run.candidate(percept({ treatment: treatment({ supplies: [supply(Number.MAX_SAFE_INTEGER)] }) })));
});

test('missing supplies and unsupported wounds remain useful model planning blockers', () => {
  const { run, percept } = fixture();
  assert.equal(run.candidate(percept({ treatment: treatment({ supplies: [] }) })), null);
  assert.equal(run.snapshot().localBlocker, 'no_supported_clean_bandage');
  assert.equal(run.candidate(percept({ treatment: treatment({ eligibleWounds: [] }) })), null);
  assert.equal(run.snapshot().localBlocker, 'no_supported_bleeding_wound');
  assert.equal(run.busy(), false);
});

test('an idle percept before command consumption cannot release or overwrite publication', () => {
  const { run, publish, percept, advance } = fixture();
  publish(); advance(250);
  assert.equal(run.observe(percept()), null);
  assert.equal(run.busy(), true);
  assert.equal(run.snapshot().blocker, 'command_not_acknowledged');
  assert.equal(run.published(command(2, 'MOVE'), { origin: 'model' }), false);
  assert.equal(run.candidate(percept()), null);
});

test('all receipt-bearing commands require an exact terminal receipt even when acknowledged idle', () => {
  for (const action of ['LOOT', 'EAT', 'DRINK', 'BANDAGE', 'DRINKTAP', 'FILLBOTTLE', 'NAVIGATE']) {
    const { run, percept } = fixture();
    run.published(command(1, action), { origin: 'model' });
    assert.equal(run.observe(percept({ lastSeq: 1 })), null, action);
    assert.equal(run.snapshot().blocker, 'matching_terminal_receipt_required');
    assert.equal(run.busy(), true);
  }
});

test('foreign, replayed, pending and unknown status receipts cannot release a reservation', () => {
  const { run, publish, percept, receipt } = fixture();
  publish();
  for (const change of [{ world: 'elsewhere' }, { actor: 'other' }, { session: 'old' }, { seq: 2 },
    { action: 'EAT' }, { status: 'pending' }, { status: 'succeeded' }]) {
    assert.equal(run.observe(percept({ lastSeq: 1, actionOutcome: receipt(1, 'observed_effect', change) })), null);
    assert.equal(run.busy(), true);
  }
});

test('prepublication, stale and foreign-session percepts cannot acknowledge a command', () => {
  const { run, publish, percept, receipt, time, advance } = fixture();
  publish(); advance(10);
  for (const change of [{ observed_ms: time() - 11 }, { observed_ms: time() - 3001 },
    { observed_ms: time() + 501 }, { session: 'other' }, { actor: 'other' }, { world: 'other' }, { lastSeq: '1' }]) {
    assert.equal(run.observe(percept({ lastSeq: 1, actionOutcome: receipt(), ...change })), null);
    assert.equal(run.busy(), true);
  }
});

test('a matching terminal seen during native work is retained until a newer known-idle snapshot', () => {
  const { run, publish, percept, receipt, advance, time } = fixture();
  publish(); advance(10);
  assert.equal(run.observe(percept({ lastSeq: 1, qlen: 1, nativeBusy: true, actionOutcome: receipt(1, 'interrupted') })), null);
  const terminalAt = time();
  assert.equal(run.snapshot().reservation.receipt.status, 'interrupted');
  advance(10);
  assert.equal(run.observe(percept({ lastSeq: 1, observed_ms: terminalAt - 1 })), null, 'old idle snapshot must not release');
  assert.equal(run.observe(percept({ lastSeq: 1, actionOutcome: { status: 'pending' } })), null);
  advance(10);
  const ended = run.observe(percept({ lastSeq: 1 }));
  assert.equal(ended.status, 'interrupted');
  assert.equal(run.busy(), false);
  assert.equal(run.blockedBandage(percept({ lastSeq: 1 })), true);
});

test('first terminal result is immutable even if a later receipt changes its claim', () => {
  const { run, publish, percept, receipt, advance, complete } = fixture();
  publish();
  run.observe(percept({ lastSeq: 1, nativeBusy: true, actionOutcome: receipt(1, 'no_effect') }));
  advance(1);
  const ended = complete();
  assert.equal(ended.status, 'no_effect');
  assert.equal(run.snapshot().failedTargets, 1);
});

test('a higher consumed sequence is an authority discrepancy that never self-clears', () => {
  const { run, publish, percept, complete } = fixture();
  publish();
  assert.deepEqual(run.observe(percept({ lastSeq: 2 })), { type: 'blocked', reason: 'unexpected_sequence' });
  assert.equal(complete(), null);
  assert.equal(run.busy(), true);
  assert.equal(run.snapshot().authorityFault, true);
  assert.equal(run.published(command(3, 'WAIT'), { origin: 'model' }), false);
});

test('external sequence advancement after release also blocks further command ownership', () => {
  const { run, percept } = fixture();
  run.published(command(1, 'WAIT'), { origin: 'model' });
  run.observe(percept({ lastSeq: 1 }));
  assert.equal(run.busy(), false);
  assert.equal(run.observe(percept({ lastSeq: 2 })).type, 'blocked');
  assert.equal(run.busy(), true);
});

test('local timeout reports unverified and retains ownership until actual terminal idle evidence', () => {
  const { run, publish, percept, advance, complete } = fixture();
  publish(); advance(34999);
  assert.equal(run.observe(percept({ lastSeq: 1 })), null);
  advance(1);
  const timeout = run.observe(percept({ lastSeq: 1 }));
  assert.equal(timeout.type, 'timed_out');
  assert.equal(timeout.status, 'unverified');
  assert.equal(timeout.completedAt, null);
  assert.equal(run.busy(), true);
  assert.equal(run.snapshot().failedTargets, 1);
  assert.equal(run.observe(percept({ lastSeq: 1 })), null, 'timeout event emitted once');
  assert.equal(run.published(command(2, 'WAIT'), { origin: 'model' }), false);
  advance(10);
  const ended = complete();
  assert.equal(ended.type, 'completed');
  assert.equal(ended.timedOut, true);
  assert.equal(run.busy(), false);
  assert.equal(run.snapshot().failedTargets, 1, 'late result does not erase missing-evidence suppression');
});

test('model tasks get their existing longer native deadline and missing receipt never releases', () => {
  const { run, percept, advance } = fixture();
  run.published(command(1, 'NAVIGATE'), { origin: 'model' });
  advance(35000);
  assert.equal(run.observe(percept({ lastSeq: 1 })), null);
  advance(30000);
  assert.equal(run.observe(percept({ lastSeq: 1 })).type, 'timed_out');
  assert.equal(run.busy(), true);
  assert.equal(run.snapshot().failedTargets, 0);
});

test('valid dressing and consumed supply are observed without claiming the bleeding stopped', () => {
  const { run, publish, advance, complete, percept } = fixture();
  publish(); advance(100);
  const ended = complete();
  assert.equal(ended.status, 'observed_effect');
  assert.equal(ended.reason, 'dressing_and_supply_consumption_observed');
  assert.equal(ended.receipt.bleedingAfter, true);
  assert.equal(run.busy(), false);
  assert.equal(run.snapshot().failedTargets, 0);
  assert.equal(run.candidate(percept({ lastSeq: 1, treatment: treatment({ eligibleWounds: [wound(2)], supplies: [supply(12)] }) })), null);
  assert.equal(run.snapshot().localBlocker, 'settling_after_dressing');
  advance(2000);
  assert.ok(run.candidate(percept({ lastSeq: 1, treatment: treatment({ eligibleWounds: [wound(2)], supplies: [supply(12)] }) })));
  assert.equal(JSON.stringify(ended).includes('healed'), false);
});

test('claimed effects without exact dressing, supply and fresh target disappearance are unverified', () => {
  const cases = [
    { receipt: { bandaged: false } }, { receipt: { bandaged: undefined } }, { receipt: { consumed: false } },
    { receipt: { partIndex: 2 } }, { receipt: { supplyKey: 'item:12' } },
    { treatment: treatment({ valid: false, eligibleWounds: [], supplies: [] }) },
    { treatment: treatment({ eligibleWounds: [wound()], supplies: [] }) },
    { treatment: treatment({ eligibleWounds: [], supplies: [supply()] }) },
    { receipt: { status: 'arrived' } },
  ];
  for (const value of cases) {
    const { run, publish, complete, receipt } = fixture();
    publish();
    const ended = complete(1, { actionOutcome: receipt(1, 'observed_effect', value.receipt),
      ...(value.treatment ? { treatment: value.treatment } : {}) });
    assert.equal(ended.status, 'unverified', JSON.stringify(value));
    assert.ok(run.snapshot().failedTargets >= 1);
    assert.equal(run.blockedBandage(fixture().percept()), true);
    assert.equal(run.busy(), false);
  }
});

test('changed execution targets are suppressed alongside the originally selected wound and supply', () => {
  for (const status of ['observed_effect', 'no_effect', 'interrupted']) {
    const { run, publish, complete, receipt, percept } = fixture();
    publish();
    complete(1, { actionOutcome: receipt(1, status, { partIndex: 2, supplyKey: 'item:22' }) });
    assert.equal(run.snapshot().failedTargets, 2);
    assert.equal(run.blockedBandage(percept({ lastSeq: 1 })), true);
    const actualPair = percept({ lastSeq: 1,
      treatment: treatment({ eligibleWounds: [wound(2)], supplies: [supply(22)] }) });
    assert.equal(run.blockedBandage(actualPair), true);
    assert.equal(run.candidate(actualPair), null);
    assert.equal(run.snapshot().localBlocker, 'unchanged_failed_treatment');
  }
});

test('failed care latches the selected pair despite elapsed time, disappearance or unrelated inventory changes', () => {
  for (const status of ['no_effect', 'unverified', 'interrupted', 'native_failed']) {
    const { run, publish, complete, receipt, percept, advance } = fixture();
    publish();
    assert.equal(complete(1, { actionOutcome: receipt(1, status) }).status, status);
    assert.equal(run.busy(), false, 'strategic planning may resume');
    assert.equal(run.candidate(percept({ lastSeq: 1 })), null);
    assert.equal(run.snapshot().localBlocker, 'unchanged_failed_treatment');
    advance(1000000);
    run.candidate(percept({ lastSeq: 1, treatment: treatment({ eligibleWounds: [], supplies: [] }) }));
    const unchanged = percept({ lastSeq: 1, treatment: treatment({ supplies: [supply(), supply(99)] }), inventoryCount: 999 });
    assert.equal(run.candidate(unchanged), null);
    assert.equal(run.blockedBandage(unchanged), true);
    assert.ok(run.candidate(percept({ lastSeq: 1, treatment: treatment({ supplies: [supply(12)] }) })));
    assert.equal(run.blockedBandage(percept({ lastSeq: 1, treatment: treatment({ supplies: [supply(12)] }) })), false);
    assert.ok(run.candidate(percept({ lastSeq: 1, treatment: treatment({ eligibleWounds: [wound(2)] }) })));
  }
});

test('failure memory is bounded and saturation blocks automatic/model bandaging without blocking strategy', () => {
  const { run, percept, publish, receipt, complete } = fixture();
  for (let seq = 1; seq <= 256; seq++) {
    publish(seq, { treatment: treatment({ supplies: [supply(seq)] }) });
    complete(seq, { actionOutcome: receipt(seq, 'no_effect', { supplyKey: `item:${seq}` }) });
  }
  assert.equal(run.snapshot().failedTargets, 256);
  assert.equal(run.snapshot().failedTargetMemoryFull, true);
  assert.equal(run.candidate(percept({ lastSeq: 256, treatment: treatment({ supplies: [supply(1000)] }) })), null);
  assert.equal(run.snapshot().localBlocker, 'failed_target_memory_full');
  assert.equal(run.blockedBandage(percept()), true);
  assert.equal(run.busy(), false);
  assert.equal(run.published(command(257, 'WAIT'), { origin: 'model' }), true);
});

test('missing or partial treatment facts cannot bypass a prior failed-pair latch', () => {
  const { run, publish, complete, receipt, percept } = fixture();
  assert.equal(run.blockedBandage(percept({ treatment: null })), false, 'unchanged legacy policy before a local failure');
  publish();complete(1, { actionOutcome: receipt(1, 'no_effect') });
  for (const facts of [null, {}, treatment({ valid: false }), treatment({ status: 'partial' }),
    treatment({ eligibleWounds: [] }), treatment({ supplies: [] }),
    treatment({ supplies: [supply(12)], eligibleWounds: [{ index: 1 }] })]) {
    assert.equal(run.blockedBandage(percept({ lastSeq: 1, treatment: facts })), true);
  }
  assert.equal(run.blockedBandage(percept({ lastSeq: 1, session: 'foreign' })), true);
  assert.equal(run.blockedBandage(percept({ lastSeq: 1, treatment: treatment({ supplies: [supply(12)] }) })), false);
});

test('local publication invalidates an older model generation even after care completes', () => {
  const { run, publish, complete, percept } = fixture();
  const modelGeneration = run.epoch;
  publish();
  assert.equal(run.epoch, modelGeneration + 1);
  complete();
  assert.equal(run.busy(), false);
  assert.notEqual(run.epoch, modelGeneration, 'caller must reject the delayed response before intent/memory acceptance');
  run.published(command(2, 'WAIT'), { origin: 'model' });
  run.observe(percept({ lastSeq: 2 }));
  assert.equal(run.epoch, modelGeneration + 1, 'model publications do not invent local interruptions');
});

test('a failed write leaves generation and reservation unchanged when published is not called', () => {
  const { run, percept } = fixture();
  const selected = run.candidate(percept());
  assert.ok(selected);
  const write = () => { throw new Error('fixture write failure'); };
  assert.throws(() => { write(); run.published(command(), { origin: 'self_care', candidate: selected }); });
  assert.equal(run.epoch, 0);
  assert.equal(run.busy(), false);
  assert.equal(run.snapshot().highestSequence, 0);
});

test('invalid publications cannot change namespace, sequence, epoch or reservation', () => {
  const { run, percept } = fixture();
  const selected = run.candidate(percept());
  for (const [value, options] of [
    [command(0), { origin: 'model' }], [command(1.5), { origin: 'model' }],
    [command(2147483648), { origin: 'model' }], [command(1, 'UNSUPPORTED'), { origin: 'model' }],
    [command(1, 'WAIT', { world: 'bad/world' }), { origin: 'model' }], [command(), { origin: 'unknown' }],
    [command(), { origin: 'self_care' }], [command(1, 'EAT'), { origin: 'self_care', candidate: selected }],
    [command(), { origin: 'self_care', candidate: { ...selected, signature: 'changed' } }],
    [command(), { origin: 'self_care', candidate: { ...selected, partIndex: -1 } }],
  ]) assert.equal(run.published(value, options), false);
  assert.equal(run.epoch, 0); assert.equal(run.busy(), false);
  assert.equal(run.snapshot().namespace, null);
});

test('namespace and high-water sequence persist after completion', () => {
  const { run, percept } = fixture();
  run.published(command(5, 'WAIT'), { origin: 'model' });
  run.observe(percept({ lastSeq: 5 }));
  assert.equal(run.published(command(5, 'STOP'), { origin: 'model' }), false);
  assert.equal(run.published(command(4, 'WAIT'), { origin: 'model' }), false);
  assert.equal(run.published(command(6, 'WAIT', { session: 'new' }), { origin: 'model' }), false);
  assert.equal(run.candidate(percept({ lastSeq: 5, session: 'new' })), null);
  assert.equal(run.candidate(percept({ lastSeq: 4 })), null);
  assert.equal(run.published(command(6, 'WAIT'), { origin: 'model' }), true);
});

test('a regressed idle sequence blocks both publishers until a newer observation catches up', () => {
  const { run, percept, advance } = fixture();
  run.published(command(1, 'WAIT'), { origin: 'model' });run.observe(percept({ lastSeq: 1 }));
  advance(1);
  assert.equal(run.observe(percept({ lastSeq: 0 })).reason, 'sequence_regressed');
  assert.equal(run.busy(), true);assert.equal(run.candidate(percept({ lastSeq: 0 })), null);
  assert.equal(run.published(command(2, 'WAIT'), { origin: 'model' }), false);
  run.observe(percept({ lastSeq: 1 }));assert.equal(run.busy(), true, 'same timestamp is not newer evidence');
  advance(1);assert.equal(run.observe(percept({ lastSeq: 1 })).reason, 'sequence_caught_up');
  assert.equal(run.busy(), false);assert.ok(run.candidate(percept({ lastSeq: 1 })));
  assert.equal(run.published(command(2, 'WAIT'), { origin: 'model' }), true);
});

test('snapshots and inputs cannot mutate owned reservation or expose controller credentials', () => {
  const { run, percept, receipt, advance } = fixture();
  const p = percept({ labToken: 'fixture-secret' });
  const selected = run.candidate(p);
  const cmd = { ...command(), labToken: 'fixture-secret' };
  run.published(cmd, { origin: 'self_care', candidate: selected });
  cmd.seq = 99; selected.partIndex = 9;
  const r = receipt(1, 'interrupted', { rawDetail: 'fixture-secret', labToken: 'fixture-secret' });
  run.observe(percept({ lastSeq: 1, nativeBusy: true, actionOutcome: r }));
  r.status = 'observed_effect';
  const view = run.snapshot(); view.reservation.command.seq = 20; view.reservation.receipt.status = 'observed_effect';
  assert.equal(run.snapshot().reservation.command.seq, 1);
  assert.equal(run.snapshot().reservation.candidate.partIndex, 1);
  assert.equal(run.snapshot().reservation.receipt.status, 'interrupted');
  assert.equal(JSON.stringify(run.snapshot()).includes('fixture-secret'), false);
  advance(1);
  assert.equal(run.observe(percept({ lastSeq: 1 })).status, 'interrupted');
});

test('unknown clocks fail closed and never publish or infer fresh facts', () => {
  assert.throws(() => new PriorityCoordinator({ enabled: 'yes' }));
  assert.throws(() => new PriorityCoordinator({ now: 1 }));
  const { percept } = fixture();
  for (const now of [() => NaN, () => null, () => -1, () => { throw new Error('unreadable clock'); }]) {
    const run = new PriorityCoordinator({ enabled: true, now });
    assert.equal(run.candidate(percept()), null);
    assert.equal(run.published(command(1, 'WAIT'), { origin: 'model' }), false);
    assert.equal(run.observe(percept()), null);
    assert.equal(run.snapshot().blocker, 'clock_unavailable');
  }
});
