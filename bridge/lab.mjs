import crypto from 'node:crypto';

const identity = value => typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,180}$/.test(value);
const same = (left, right) => left && right && ['session', 'world', 'actor'].every(key => left[key] === right[key]);

function boundedInteger(env, name, fallback, maximum) {
  const raw = env[name] ?? String(fallback);
  if (typeof raw !== 'string' || !/^[1-9]\d*$/.test(raw) || Number(raw) > maximum) {
    throw new Error(`${name} must be an integer from 1 to ${maximum}.`);
  }
  return Number(raw);
}

export function labConfig(env = process.env) {
  if (env.PZ_LAB_ARM !== undefined && !['0', '1'].includes(env.PZ_LAB_ARM)) {
    throw new Error('PZ_LAB_ARM must be 0 or 1; only 1 explicitly arms a lab session.');
  }
  return Object.freeze({
    arm: env.PZ_LAB_ARM === '1',
    maxRequests: boundedInteger(env, 'PZ_MAX_REQUESTS', 10, 10),
    maxSeconds: boundedInteger(env, 'PZ_MAX_SECONDS', 120, 300),
  });
}

/** Pure run boundary; IO and model requests remain in the bridge. */
export class LabRun {
  constructor(config, { now = Date.now, token = crypto.randomUUID() } = {}) {
    this.config = config;
    this.now = now;
    this.token = token;
    this.startedAt = now();
    this.target = null;
    this.requests = 0;
    this.stopped = false;
    this.reason = config.arm ? 'waiting_for_game' : 'monitor_only';
  }

  valid(percept, { allowDead = false } = {}) {
    return percept?.labProtocol === 1 && ['session', 'world', 'actor'].every(key => identity(percept[key]))
      && typeof percept.armed === 'boolean' && typeof percept.dead === 'boolean' && (allowDead || !percept.dead)
      && Number.isSafeInteger(percept.observed_ms) && this.now() - percept.observed_ms <= 3000
      && percept.observed_ms <= this.now() + 500;
  }

  bind(percept) {
    if (!this.config.arm || this.stopped || !this.valid(percept)) return false;
    if (this.target && !same(this.target, percept)) {
      this.stop('game_session_changed');
      return false;
    }
    this.target ??= Object.fromEntries(['session', 'world', 'actor'].map(key => [key, percept[key]]));
    return true;
  }

  expired() { return this.now() - this.startedAt >= this.config.maxSeconds * 1000; }

  control(action = 'ARM') {
    if (!this.target) return null;
    const issued = this.now();
    const expires = action === 'DISARM' ? issued + 2000
      : Math.min(issued + 2000, this.startedAt + this.config.maxSeconds * 1000);
    return [1, this.target.session, this.target.world, this.target.actor, this.token, action, issued, expires].join('|');
  }

  ready(percept) {
    return !this.stopped && !this.expired() && this.bind(percept)
      && percept.armed && percept.labToken === this.token;
  }

  disarmObserved(percept, issuedAt) {
    return Boolean(this.target && this.valid(percept, { allowDead: true })
      && percept.world === this.target.world && percept.actor === this.target.actor
      && percept.armed === false && percept.qlen === 0 && percept.stopFailed === false
      && percept.observed_ms >= issuedAt);
  }

  beginRequest(percept) {
    if (!this.ready(percept)) return false;
    if (this.requests >= this.config.maxRequests) {
      this.stop('request_budget_exhausted');
      return false;
    }
    this.requests++; // Attempts count before IO, including HTTP errors and invalid JSON.
    this.reason = 'running';
    return true;
  }

  intent(percept, sequence, action, say = '', thought = '', goal = '') {
    if (!this.ready(percept)) throw new Error('Lab session is disarmed, changed, stale, or expired.');
    if (!Number.isSafeInteger(sequence) || sequence < 1 || sequence > 2147483647) throw new Error('Invalid sequence.');
    const type = action.type;
    if (!['MOVE', 'LOOT', 'EAT', 'DRINK', 'EQUIP', 'CLOSEDOOR', 'CONCEAL', 'BREAKIN', 'STOP', 'WAIT'].includes(type)) {
      throw new Error('Unsupported lab action.');
    }
    const dx = type === 'MOVE' ? action.dx : 0;
    const dy = type === 'MOVE' ? action.dy : 0;
    if (type === 'MOVE' && (!Number.isInteger(dx) || !Number.isInteger(dy) || dx*dx + dy*dy < 1 || dx*dx + dy*dy > 16)) {
      throw new Error('MOVE must be a nonzero integer offset within four tiles.');
    }
    const safe = value => String(value).replace(/[|\r\n\0]/g, ' ').slice(0, 200);
    const issued = this.now();
    const expires = Math.min(issued + 2000, this.startedAt + this.config.maxSeconds * 1000);
    return [sequence, type, dx, dy, safe(say), safe(thought), safe(goal), 'LAB1',
      this.target.session, this.target.world, this.target.actor, this.token, issued, expires].join('|');
  }

  stop(reason) { this.stopped = true; this.reason = reason; }

  snapshot() {
    return { armedOptIn: this.config.arm, target: this.target, requests: this.requests,
      maxRequests: this.config.maxRequests, maxSeconds: this.config.maxSeconds,
      stopped: this.stopped, reason: this.reason };
  }
}
