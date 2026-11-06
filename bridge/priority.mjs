// One command owner for both model plans and continuous-mode idle self-care.
// This module does not grant authority or write files. The bridge must check
// LabRun.ready(), publish atomically, then immediately reserve with published().
const ACTIONS = new Set(['MOVE', 'NAVIGATE', 'LOOT', 'EAT', 'DRINK', 'DRINKTAP',
  'FILLBOTTLE', 'BANDAGE', 'EQUIP', 'CLOSEDOOR', 'CONCEAL', 'BREAKIN', 'STOP', 'WAIT']);
const RECEIPT_ACTIONS = new Set(['NAVIGATE', 'LOOT', 'EAT', 'DRINK', 'DRINKTAP', 'FILLBOTTLE', 'BANDAGE']);
const TERMINAL = new Set(['observed_effect', 'arrived', 'no_effect', 'unverified', 'interrupted', 'native_failed']);
const SUPPLIES = new Set(['Bandage', 'AlcoholBandage', 'Bandaid', 'RippedSheets', 'AlcoholRippedSheets']);
const MAX_SEQUENCE = 2147483647;
const MAX_FAILURES = 256;
const copy = value => value === null ? null : JSON.parse(JSON.stringify(value));
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const integer = (value, low, high) => Number.isSafeInteger(value) && value >= low && value <= high;
const label = value => typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,180}$/.test(value);
const same = (left, right) => left && right && ['world', 'actor', 'session'].every(key => left[key] === right[key]);
const namespace = value => record(value) && ['world', 'actor', 'session'].every(key => label(value[key]));
const identity = value => namespace(value) && integer(value.seq, 1, MAX_SEQUENCE) && ACTIONS.has(value.action);
const sameCommand = (left, right) => same(left, right) && left.seq === right.seq && left.action === right.action;
const knownIdle = value => value.qlen === 0 && value.nativeBusy === false
  && value.traversingWindow === false && value.actionOutcome?.status !== 'pending';
const keyFor = (subject, partIndex, supplyKey) => JSON.stringify([
  subject.world, subject.actor, subject.session, partIndex, supplyKey,
]);

function wound(value) {
  return record(value) && integer(value.index, 0, 31)
    && typeof value.name === 'string' && /^[A-Za-z0-9_]{1,48}$/.test(value.name);
}

function supply(value) {
  if (!record(value) || !SUPPLIES.has(value.name) || value.fullType !== `Base.${value.name}`
      || typeof value.key !== 'string' || !/^item:(0|[1-9]\d{0,15})$/.test(value.key)) return false;
  return integer(Number(value.key.slice(5)), 0, Number.MAX_SAFE_INTEGER);
}

// Validate the complete bounded public observation, including duplicates. The
// first candidates must match the body's selection order; never skip a failed
// first item and pretend that the current BANDAGE protocol can select another.
function treatment(value) {
  if (!record(value) || value.valid !== true || value.status !== 'observed'
      || !Array.isArray(value.eligibleWounds) || value.eligibleWounds.length > 32
      || !Array.isArray(value.supplies) || value.supplies.length > 16) return false;
  const parts = new Set(), items = new Set();
  for (const part of value.eligibleWounds) {
    if (!wound(part) || parts.has(part.index)) return false;
    parts.add(part.index);
  }
  for (const item of value.supplies) {
    if (!supply(item) || items.has(item.key)) return false;
    items.add(item.key);
  }
  return true;
}

function fresh(value, now) {
  return namespace(value) && value.labProtocol === 1 && typeof value.dead === 'boolean'
    && typeof value.armed === 'boolean' && integer(value.observed_ms, 0, Number.MAX_SAFE_INTEGER)
    && value.observed_ms <= now + 500 && now - value.observed_ms <= 3000
    && integer(value.lastSeq, 0, MAX_SEQUENCE);
}

function receipt(value) {
  if (!identity(value) || !TERMINAL.has(value.status)) return null;
  // Never retain the percept, raw detail text, or controller token.
  return { ...Object.fromEntries(['world', 'actor', 'session', 'seq', 'action'].map(key => [key, value[key]])),
    status: value.status, partIndex: integer(value.partIndex, 0, 31) ? value.partIndex : null,
    supplyKey: typeof value.supplyKey === 'string' && /^item:(0|[1-9]\d{0,15})$/.test(value.supplyKey)
      && integer(Number(value.supplyKey.slice(5)), 0, Number.MAX_SAFE_INTEGER) ? value.supplyKey : null,
    bandaged: typeof value.bandaged === 'boolean' ? value.bandaged : null,
    consumed: typeof value.consumed === 'boolean' ? value.consumed : null,
    bleedingAfter: typeof value.bleedingAfter === 'boolean' ? value.bleedingAfter : null };
}

export class PriorityCoordinator {
  #enabled; #now; #epoch = 0; #namespace = null; #highestSequence = 0;
  #reservation = null; #lastResult = null; #blocker = null; #localBlocker = null;
  #failed = new Set(); #failuresFull = false; #settleUntil = 0; #authorityFault = false;
  #regressedAt = null;

  constructor({ enabled = false, now = Date.now } = {}) {
    if (typeof enabled !== 'boolean' || typeof now !== 'function') throw new TypeError('Invalid priority configuration.');
    this.#enabled = enabled; this.#now = now;
  }

  get epoch() { return this.#epoch; }

  #time() {
    try { const now = this.#now(); return integer(now, 0, Number.MAX_SAFE_INTEGER) ? now : null; }
    catch { return null; }
  }

  busy() { return this.#reservation !== null || this.#authorityFault || this.#regressedAt !== null; }

  #suppress(signature) {
    if (this.#failed.has(signature)) return;
    if (this.#failed.size >= MAX_FAILURES) { this.#failuresFull = true; return; }
    this.#failed.add(signature);
    if (this.#failed.size === MAX_FAILURES) this.#failuresFull = true;
  }

  #suppressAttempt(active) {
    this.#suppress(active.candidate.signature);
    // The body reselects its first supported pair at execution time. If that
    // changed during file transit, an unsuccessful/mismatched result must not
    // make the actual attempted pair look untried to the next heartbeat.
    if (active.receipt?.partIndex !== null && active.receipt?.partIndex !== undefined
        && active.receipt?.supplyKey !== null && active.receipt?.supplyKey !== undefined) {
      this.#suppress(keyFor(active.command, active.receipt.partIndex, active.receipt.supplyKey));
    }
  }

  #wait(reason, now) {
    const active = this.#reservation;
    this.#blocker = this.#authorityFault ? 'unexpected_sequence' : reason;
    if (active && !active.timedOut && now - active.publishedAt >= active.deadlineMs) {
      active.timedOut = true;
      if (active.origin === 'self_care') this.#suppressAttempt(active);
      this.#blocker = this.#authorityFault ? 'unexpected_sequence' : 'receipt_timeout_unverified';
      this.#lastResult = { ...active.command, origin: active.origin, status: 'unverified',
        reason: 'receipt_timeout_unverified', completedAt: null, observedAt: now };
      return { type: 'timed_out', ...this.#lastResult };
    }
    if (active?.timedOut && !this.#authorityFault) this.#blocker = 'receipt_timeout_unverified';
    return null;
  }

  observe(percept) {
    const now = this.#time();
    if (now === null) { this.#blocker = 'clock_unavailable'; return null; }
    if (this.#authorityFault) return this.#wait('unexpected_sequence', now);
    const active = this.#reservation;
    if (!active) {
      // A command from another publisher must not silently become our new base.
      if (this.#namespace && fresh(percept, now) && same(this.#namespace, percept)) {
        if (percept.lastSeq > this.#highestSequence) {
          this.#authorityFault = true; this.#blocker = 'unexpected_sequence';
          return { type: 'blocked', reason: 'unexpected_sequence' };
        }
        if (percept.lastSeq < this.#highestSequence) {
          const first = this.#regressedAt === null;
          this.#regressedAt = Math.max(this.#regressedAt ?? 0, percept.observed_ms);
          this.#blocker = 'sequence_regressed';
          return first ? { type: 'blocked', reason: 'sequence_regressed' } : null;
        }
        if (this.#regressedAt !== null && percept.observed_ms > this.#regressedAt) {
          this.#regressedAt = null; this.#blocker = null;
          return { type: 'resumed', reason: 'sequence_caught_up' };
        }
      }
      return null;
    }
    if (!fresh(percept, now)) return this.#wait('fresh_observation_required', now);
    if (!same(active.command, percept)) return this.#wait('command_session_mismatch', now);
    if (percept.observed_ms < active.publishedAt || percept.observed_ms < active.lastObservedAt)
      return this.#wait('post_publication_observation_required', now);
    active.lastObservedAt = percept.observed_ms;
    if (percept.lastSeq > active.command.seq) {
      this.#authorityFault = true; this.#blocker = 'unexpected_sequence';
      return { type: 'blocked', reason: 'unexpected_sequence' };
    }
    if (percept.lastSeq !== active.command.seq) return this.#wait('command_not_acknowledged', now);
    const current = receipt(percept.actionOutcome);
    if (!active.receipt && current && sameCommand(active.command, current)) {
      active.receipt = current;
      active.receiptAt = percept.observed_ms;
    }
    if (!knownIdle(percept)) {
      active.lastBusyAt = percept.observed_ms;
      return this.#wait('body_not_known_idle', now);
    }
    if (active.lastBusyAt !== null && percept.observed_ms <= active.lastBusyAt)
      return this.#wait('newer_idle_observation_required', now);
    if (RECEIPT_ACTIONS.has(active.command.action) && !active.receipt)
      return this.#wait('matching_terminal_receipt_required', now);

    const result = { ...active.command, origin: active.origin, publishedAt: active.publishedAt,
      completedAt: now, observedAt: percept.observed_ms, timedOut: active.timedOut,
      status: active.receipt?.status ?? 'acknowledged_idle',
      reason: active.receipt ? 'matching_terminal_receipt_observed' : 'command_acknowledged_and_idle',
      receipt: copy(active.receipt) };
    if (active.origin === 'self_care') {
      const selected = active.candidate;
      const applied = active.receipt?.status === 'observed_effect'
        && active.receipt.bandaged === true && active.receipt.consumed === true
        && active.receipt.partIndex === selected.partIndex && active.receipt.supplyKey === selected.supplyKey
        && treatment(percept.treatment)
        && !percept.treatment.eligibleWounds.some(part => part.index === selected.partIndex)
        && !percept.treatment.supplies.some(item => item.key === selected.supplyKey);
      if (applied) {
        result.reason = 'dressing_and_supply_consumption_observed';
        this.#settleUntil = now + 2000;
      } else {
        if (active.receipt?.status === 'observed_effect' || active.receipt?.status === 'arrived') result.status = 'unverified';
        result.reason = result.status === 'unverified' ? 'treatment_effect_unverified' : `treatment_${result.status}`;
        this.#suppressAttempt(active);
      }
    }
    this.#reservation = null;
    this.#blocker = null;
    this.#lastResult = result;
    return { type: 'completed', ...copy(result) };
  }

  candidate(percept) {
    const deny = reason => { this.#localBlocker = reason; return null; };
    if (!this.#enabled) return deny('automatic_care_disabled');
    if (this.busy()) return deny(this.#blocker ?? 'command_outstanding');
    if (this.#failuresFull) return deny('failed_target_memory_full');
    const now = this.#time();
    if (now === null) return deny('clock_unavailable');
    if (now < this.#settleUntil) return deny('settling_after_dressing');
    if (!fresh(percept, now)) return deny('fresh_observation_required');
    if (this.#namespace && (!same(this.#namespace, percept) || percept.lastSeq !== this.#highestSequence))
      return deny('command_session_or_sequence_changed');
    if (percept.armed !== true || percept.dead !== false) return deny('living_armed_survivor_required');
    if (![percept.hp, percept.hunger, percept.thirst].every(Number.isFinite)
        || percept.hp <= 0 || percept.hp > 100 || percept.hunger < 0 || percept.hunger > 1
        || percept.thirst < 0 || percept.thirst > 1) return deny('survivor_vitals_unknown');
    if (percept.bodyRevision !== 'priority-1' || percept.capabilities?.idleSelfCare !== 'bandage_only')
      return deny('automatic_care_body_unsupported');
    if (!knownIdle(percept)) return deny('body_not_known_idle');
    if (percept.threats?.valid !== true || !integer(percept.zTotal, 0, 1000000)
        || !Number.isFinite(percept.zDist)
        || !(percept.zTotal === 0 ? percept.zDist === -1 : percept.zDist > 11)
        || percept.reflexed !== false) return deny('known_clear_reflex_radius_required');
    if (!treatment(percept.treatment)) return deny('complete_treatment_observation_required');
    const part = percept.treatment.eligibleWounds[0], item = percept.treatment.supplies[0];
    if (!part) return deny('no_supported_bleeding_wound');
    if (!item) return deny('no_supported_clean_bandage');
    const signature = keyFor(percept, part.index, item.key);
    if (this.#failed.has(signature)) return deny('unchanged_failed_treatment');
    this.#localBlocker = null;
    return { action: 'BANDAGE', reason: 'supported_bleeding_wound', partIndex: part.index,
      supplyKey: item.key, signature };
  }

  // Strategic planning can continue after a failed treatment, but a model must
  // not bypass the same unchanged local failure latch with another BANDAGE.
  blockedBandage(percept) {
    if (this.#failuresFull) return true;
    if (this.#failed.size === 0) return false;
    // Unknown facts cannot demonstrate a change from an already failed pair.
    // Lua selects again at execution, so accepting a model command here would
    // let transient missing/partial observations bypass retry suppression.
    if (!namespace(percept) || !same(this.#namespace, percept) || !treatment(percept.treatment)) return true;
    const part = percept?.treatment?.eligibleWounds?.[0], item = percept?.treatment?.supplies?.[0];
    return wound(part) && supply(item) ? this.#failed.has(keyFor(percept, part.index, item.key)) : true;
  }

  // Call synchronously after the one atomic write, before any await. A failed
  // write must never call this method or advance the plan epoch.
  published(command, { origin, candidate = null } = {}) {
    const now = this.#time();
    if (now === null || this.busy() || !identity(command) || !['model', 'self_care'].includes(origin)
        || command.seq <= this.#highestSequence || (this.#namespace && !same(this.#namespace, command))) return false;
    if (origin === 'self_care' && (!this.#enabled || command.action !== 'BANDAGE'
        || !record(candidate) || candidate.action !== 'BANDAGE' || candidate.reason !== 'supported_bleeding_wound'
        || !integer(candidate.partIndex, 0, 31) || typeof candidate.supplyKey !== 'string'
        || !/^item:(0|[1-9]\d{0,15})$/.test(candidate.supplyKey)
        || !integer(Number(candidate.supplyKey.slice(5)), 0, Number.MAX_SAFE_INTEGER)
        || candidate.signature !== keyFor(command, candidate.partIndex, candidate.supplyKey)
        || this.#failed.has(candidate.signature) || this.#failuresFull || now < this.#settleUntil)) return false;
    this.#namespace ??= Object.fromEntries(['world', 'actor', 'session'].map(key => [key, command[key]]));
    this.#highestSequence = command.seq;
    this.#reservation = { command: Object.fromEntries(['world', 'actor', 'session', 'seq', 'action'].map(key => [key, command[key]])),
      origin, candidate: origin === 'self_care' ? { action: 'BANDAGE', reason: candidate.reason,
        partIndex: candidate.partIndex, supplyKey: candidate.supplyKey, signature: candidate.signature } : null,
      publishedAt: now, lastObservedAt: now, lastBusyAt: null, receiptAt: null, receipt: null,
      deadlineMs: origin === 'self_care' ? 35000 : 65000, timedOut: false };
    this.#blocker = 'command_not_acknowledged';
    if (origin === 'self_care') this.#epoch++;
    return true;
  }

  snapshot() {
    return copy({ enabled: this.#enabled, epoch: this.#epoch, namespace: this.#namespace,
      highestSequence: this.#highestSequence, reservation: this.#reservation,
      lastResult: this.#lastResult, blocker: this.#blocker, localBlocker: this.#localBlocker,
      failedTargets: this.#failed.size, failedTargetMemoryFull: this.#failuresFull,
      settleUntil: this.#settleUntil, authorityFault: this.#authorityFault, regressedAt: this.#regressedAt });
  }
}
