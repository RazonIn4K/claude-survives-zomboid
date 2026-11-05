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
  const mode = env.PZ_RUN_MODE === undefined ? 'lab' : env.PZ_RUN_MODE;
  if (!['lab', 'autonomous', 'continuous'].includes(mode)) {
    throw new Error('PZ_RUN_MODE must be lab, autonomous or continuous.');
  }
  if (env.PZ_LAB_ARM !== undefined && !['0', '1'].includes(env.PZ_LAB_ARM)) {
    throw new Error('PZ_LAB_ARM must be 0 or 1; only 1 explicitly arms a lab session.');
  }
  const autonomous = mode === 'autonomous';
  const continuous = mode === 'continuous';
  if (continuous && ['PZ_MAX_REQUESTS', 'PZ_MAX_SECONDS'].some(name => env[name] !== undefined)) {
    throw new Error('Continuous mode does not accept PZ_MAX_REQUESTS or PZ_MAX_SECONDS.');
  }
  const expectedNames = ['PZ_EXPECTED_SESSION', 'PZ_EXPECTED_WORLD', 'PZ_EXPECTED_ACTOR'];
  let expectedIdentity = null;
  if (expectedNames.some(name => env[name] !== undefined)) {
    if (!expectedNames.every(name => identity(env[name]))) {
      throw new Error('Expected session, world and actor must all be valid identities.');
    }
    expectedIdentity = Object.freeze({session:env.PZ_EXPECTED_SESSION,world:env.PZ_EXPECTED_WORLD,actor:env.PZ_EXPECTED_ACTOR});
  }
  return Object.freeze({
    mode,
    expectedIdentity,
    arm: env.PZ_LAB_ARM === '1',
    maxRequests: continuous ? null : boundedInteger(env, 'PZ_MAX_REQUESTS', autonomous ? 120 : 10, autonomous ? 300 : 10),
    maxSeconds: continuous ? null : boundedInteger(env, 'PZ_MAX_SECONDS', autonomous ? 1800 : 120, autonomous ? 3600 : 300),
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
    if (!this.target && this.config.expectedIdentity && !same(this.config.expectedIdentity, percept)) {
      this.stop('initial_session_changed');
      return false;
    }
    if (this.target && !same(this.target, percept)) {
      this.stop('game_session_changed');
      return false;
    }
    this.target ??= Object.fromEntries(['session', 'world', 'actor'].map(key => [key, percept[key]]));
    return true;
  }

  expired() { return this.config.maxSeconds !== null && this.now() - this.startedAt >= this.config.maxSeconds * 1000; }

  control(action = 'ARM') {
    if (!this.target) return null;
    const issued = this.now();
    const expires = action === 'DISARM' || this.config.maxSeconds === null ? issued + 2000
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
      && percept.armed === false && percept.qlen === 0 && percept.nativeBusy === false && percept.stopFailed === false
      && percept.observed_ms >= issuedAt);
  }

  beginRequest(percept) {
    if (!this.ready(percept)) return false;
    if (this.config.maxRequests !== null && this.requests >= this.config.maxRequests) {
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
    if (!['MOVE', 'NAVIGATE', 'LOOT', 'EAT', 'DRINK', 'DRINKTAP', 'FILLBOTTLE', 'BANDAGE', 'EQUIP', 'CLOSEDOOR', 'CONCEAL', 'BREAKIN', 'STOP', 'WAIT'].includes(type)) {
      throw new Error('Unsupported lab action.');
    }
    let targetId = 0;
    if (type === 'NAVIGATE') {
      targetId = action.targetId;
      const nav = percept.navigation;
      if (!Number.isInteger(targetId) || targetId < 1 || targetId > 2147483647
          || nav?.scope !== 'current_session' || nav.valid !== true || !same(nav, percept)
          || !Array.isArray(nav.anchors) || nav.anchors.length > 24) {
        throw new Error('NAVIGATE requires a current remembered destination ID.');
      }
      const ids = new Set();
      for (const anchor of nav.anchors) {
        if (!Number.isInteger(anchor?.id) || anchor.id < 1 || anchor.id > 2147483647 || ids.has(anchor.id)) {
          throw new Error('Navigation destination identities are unreadable or duplicated.');
        }
        ids.add(anchor.id);
      }
      if (!nav.anchors.some(anchor => anchor.id === targetId && anchor.canNavigate === true)) {
        throw new Error('NAVIGATE destination is unavailable in the current observation.');
      }
    }
    const dx = type === 'MOVE' ? action.dx : (type === 'NAVIGATE' ? targetId : 0);
    const dy = type === 'MOVE' ? action.dy : 0;
    if (type === 'MOVE' && (!Number.isInteger(dx) || !Number.isInteger(dy) || dx*dx + dy*dy < 1 || dx*dx + dy*dy > 16)) {
      throw new Error('MOVE must be a nonzero integer offset within four tiles.');
    }
    const safe = value => String(value).replace(/[|\r\n\0]/g, ' ').slice(0, 200);
    const issued = this.now();
    const expires = this.config.maxSeconds === null ? issued + 2000
      : Math.min(issued + 2000, this.startedAt + this.config.maxSeconds * 1000);
    return [sequence, type, dx, dy, safe(say), safe(thought), safe(goal), 'LAB1',
      this.target.session, this.target.world, this.target.actor, this.token, issued, expires].join('|');
  }

  stop(reason) { this.stopped = true; this.reason = reason; }

  snapshot() {
    return { mode: this.config.mode, armedOptIn: this.config.arm, target: this.target, requests: this.requests,
      maxRequests: this.config.maxRequests, maxSeconds: this.config.maxSeconds,
      stopped: this.stopped, reason: this.reason };
  }
}
