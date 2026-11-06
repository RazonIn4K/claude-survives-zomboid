// Local accounting only. Provider responses, published intents and game receipts
// are separate evidence; none of these numbers establishes an account charge.
import { randomUUID } from 'node:crypto';

const BACKENDS = new Set(['anthropic', 'openai', 'openai-compat', 'ollama', 'gemini', 'claude-cli']);
const AUTH_MODES = new Set(['keyless_loopback', 'api_key', 'cli_subscription_or_login', 'none']);
const ACTIONS = new Set(['MOVE', 'NAVIGATE', 'LOOT', 'EAT', 'DRINK', 'DRINKTAP', 'FILLBOTTLE',
  'BANDAGE', 'EQUIP', 'CLOSEDOOR', 'CONCEAL', 'BREAKIN', 'STOP', 'WAIT']);
const TERMINAL_STATUSES = ['observed_effect', 'arrived', 'no_effect', 'unverified', 'interrupted', 'native_failed'];
const DECISION_REASONS = new Set(['invalid_json', 'unsupported_action', 'intent_rejected', 'intent_write_failed',
  'stale_percept', 'unreadable_percept', 'survivor_dead', 'session_changed', 'body_busy', 'pending_outcome',
  'percept_replaced', 'controller_stopping', 'survivor_guard', 'local_action_superseded', 'command_pending',
  'unchanged_self_care_failure']);
const LOCAL_REASONS = new Set(['supported_bleeding_wound']);
const FAILURE_CODES = new Set(['configuration_error', 'invalid_configuration', 'missing_credentials',
  'timeout', 'aborted', 'transport_error', 'network_error', 'http_error', 'invalid_response',
  'invalid_response_json', 'invalid_json', 'cli_error', 'unsupported_backend', 'provider_error']);
const TOKEN_FIELDS = ['inputTokens', 'outputTokens', 'totalTokens'];
const MAX = Number.MAX_SAFE_INTEGER;
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const integer = value => Number.isSafeInteger(value) && value >= 0 ? value : null;
const number = value => Number.isFinite(value) && value >= 0 && value <= MAX ? value : null;
const namespace = value => typeof value === 'string' && /^[A-Za-z0-9_.:-]{1,180}$/.test(value);
const copy = value => JSON.parse(JSON.stringify(value));

// Deliberately accept identifiers rather than free-form provider text. The
// adapter also strips known credential values before supplying metadata here.
function identifier(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,179}$/.test(value)
      || value.includes('://') || /(?:^|[/:])(?:sk[-_]|gh[pousr]_|github_pat_|AIza|bearer)/i.test(value)) return null;
  return value;
}

function origin(value) {
  if (typeof value !== 'string' || value.length > 2048) return null;
  try {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password ? url.origin : null;
  } catch { return null; }
}

function configSummary(value) {
  const config = record(value) ? value : {};
  return {
    backend: BACKENDS.has(config.backend) ? config.backend : null,
    requestedModel: identifier(config.requestedModel),
    endpointOrigin: origin(config.endpointOrigin),
    authMode: AUTH_MODES.has(config.authMode) ? config.authMode : null,
  };
}

function metadataSummary(value) {
  const metadata = record(value) ? value : {};
  const usage = record(metadata.usage) ? metadata.usage : {};
  return {
    backend: BACKENDS.has(metadata.backend) ? metadata.backend : null,
    requestedModel: identifier(metadata.requestedModel),
    returnedModel: identifier(metadata.returnedModel),
    requestId: identifier(metadata.requestId),
    responseId: identifier(metadata.responseId),
    latencyMs: number(metadata.latencyMs),
    httpStatus: Number.isInteger(metadata.httpStatus) && metadata.httpStatus >= 100 && metadata.httpStatus <= 599
      ? metadata.httpStatus : null,
    usage: Object.fromEntries(TOKEN_FIELDS.map(field => [field, integer(usage[field])])),
  };
}

function commandIdentity(value) {
  if (!record(value) || !['world', 'actor', 'session'].every(key => namespace(value[key]))
      || !Number.isSafeInteger(value.seq) || value.seq < 1 || value.seq > 2147483647
      || !ACTIONS.has(value.action)) return null;
  return Object.fromEntries(['world', 'actor', 'session', 'seq', 'action'].map(key => [key, value[key]]));
}

const commandKey = value => JSON.stringify([value.world, value.actor, value.session, value.seq, value.action]);
const sameNamespace = (left, right) => ['world', 'actor', 'session'].every(key => left[key] === right[key]);

function outcomeSummary(value, observedAt) {
  const result = { status: value.status, observedAt };
  // No detail/reason/dialogue/provider text or object references are archived.
  for (const key of ['added', 'hungerDrop', 'thirstDrop', 'amountGain', 'distanceRemaining']) {
    if (number(value[key]) !== null) result[key] = value[key];
  }
  for (const key of ['finalX', 'finalY', 'finalZ']) {
    if (Number.isFinite(value[key]) && Math.abs(value[key]) <= (key === 'finalZ' ? 100 : 1000000)) result[key] = value[key];
  }
  if (Number.isInteger(value.targetId) && value.targetId >= 1 && value.targetId <= 2147483647) result.targetId = value.targetId;
  for (const key of ['bandaged', 'consumed', 'bleedingAfter']) if (typeof value[key] === 'boolean') result[key] = value[key];
  return result;
}

// Like LabRun, one bridge process can publish for one bound game namespace.
// A retained high-water sequence prevents an evicted command from ever being
// republished/recounted, without keeping an unbounded set of old command IDs.
export class RunTelemetry {
  #now; #runId; #startedAt; #config; #limit; #nextId = 1;
  #attempts = new Map(); #commands = new Map();
  #publishedNamespace = null; #highestPublishedSequence = 0;
  #correlationsEvicted = 0; #unresolvedEvicted = 0; #counterOverflow = false;
  #counters = { attempts: 0, responses: 0, providerFailures: 0, invalidDecisions: 0,
    discardedDecisions: 0, publicationFailures: 0, intentsPublished: 0,
    modelIntentsPublished: 0, localIntentsPublished: 0,
    matchedReceipts: 0, observedEffects: 0, arrivals: 0 };
  #receiptStatuses = Object.fromEntries(TERMINAL_STATUSES.map(status => [status, 0]));
  #usage = Object.fromEntries(TOKEN_FIELDS.map(field => [field,
    { tokens: null, reportedResponses: 0, missingResponses: 0, overflowed: false }]));

  constructor({ config = {}, now = Date.now, runId = randomUUID(), limit = 100 } = {}) {
    if (typeof now !== 'function') throw new TypeError('Telemetry clock must be a function.');
    if (!namespace(runId)) throw new TypeError('Telemetry run ID is invalid.');
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new RangeError('Telemetry retention must be from 1 to 100.');
    this.#now = now; this.#runId = runId; this.#limit = limit;
    this.#startedAt = this.#time(); this.#config = configSummary(config);
  }

  #time() {
    try { return integer(this.#now()); } catch { return null; }
  }

  #increment(object, field) {
    if (object[field] < MAX) object[field]++;
    else this.#counterOverflow = true;
  }

  #attempt(id) {
    return Number.isSafeInteger(id) && id > 0 ? this.#attempts.get(id) : undefined;
  }

  beginAttempt() {
    if (!Number.isSafeInteger(this.#nextId)) throw new RangeError('Telemetry attempt IDs exhausted.');
    const id = this.#nextId++;
    this.#attempts.set(id, { id, startedAt: this.#time(), finishedAt: null, status: 'pending',
      metadata: null, errorCode: null, disposition: null, reason: null, command: null });
    if (this.#attempts.size > this.#limit) this.#attempts.delete(this.#attempts.keys().next().value);
    this.#increment(this.#counters, 'attempts');
    return id;
  }

  recordResponse(id, metadata) {
    const attempt = this.#attempt(id);
    if (!attempt || attempt.status !== 'pending') return false;
    attempt.status = 'response'; attempt.finishedAt = this.#time(); attempt.metadata = metadataSummary(metadata);
    this.#increment(this.#counters, 'responses');
    for (const field of TOKEN_FIELDS) {
      const aggregate = this.#usage[field];
      const value = attempt.metadata.usage[field];
      if (value === null) { this.#increment(aggregate, 'missingResponses'); continue; }
      this.#increment(aggregate, 'reportedResponses');
      if (aggregate.overflowed) continue;
      const total = (aggregate.tokens ?? 0) + value;
      if (!Number.isSafeInteger(total)) { aggregate.tokens = null; aggregate.overflowed = true; }
      else aggregate.tokens = total;
    }
    return true;
  }

  recordFailure(id, metadata, code) {
    const attempt = this.#attempt(id);
    if (!attempt || attempt.status !== 'pending') return false;
    attempt.status = 'failure'; attempt.finishedAt = this.#time(); attempt.metadata = metadataSummary(metadata);
    attempt.errorCode = FAILURE_CODES.has(code) ? code : 'provider_error';
    this.#increment(this.#counters, 'providerFailures');
    // Failure metadata never contributes to response-token subtotals. Failure
    // count is exposed separately; missing failure usage is not fabricated zero.
    return true;
  }

  rejectDecision(id, reason, disposition = 'invalid') {
    const attempt = this.#attempt(id);
    const counters = { invalid: 'invalidDecisions', discarded: 'discardedDecisions', publication_failed: 'publicationFailures' };
    if (!attempt || attempt.status !== 'response' || attempt.disposition !== null
        || !Object.hasOwn(counters, disposition)) return false;
    attempt.disposition = disposition;
    attempt.reason = DECISION_REASONS.has(reason) ? reason : 'decision_rejected';
    this.#increment(this.#counters, counters[disposition]);
    return true;
  }

  publishIntent(id, value) {
    const attempt = this.#attempt(id);
    const identity = commandIdentity(value);
    if (!attempt || attempt.status !== 'response' || attempt.disposition !== null || !identity) return false;
    if (!this.#publish(identity, 'model', id, null)) return false;
    attempt.disposition = 'published'; attempt.command = identity;
    return true;
  }

  // Deterministic self-care is a real command publication, not a model call.
  // It shares the same identity/sequence fence and receipt ledger without
  // inventing an attempt, provider response, or token-usage coverage.
  publishLocalIntent(value, reason = 'supported_bleeding_wound') {
    const identity = commandIdentity(value);
    if (!identity || identity.action !== 'BANDAGE' || !LOCAL_REASONS.has(reason)) return false;
    return this.#publish(identity, 'self_care', null, reason);
  }

  #publish(identity, origin, attemptId, reason) {
    if (identity.seq <= this.#highestPublishedSequence
        || (this.#publishedNamespace && !sameNamespace(this.#publishedNamespace, identity))) return false;
    this.#publishedNamespace ??= Object.fromEntries(['world', 'actor', 'session'].map(key => [key, identity[key]]));
    this.#highestPublishedSequence = identity.seq;
    this.#commands.set(commandKey(identity), { ...identity, origin, attemptId, reason, publishedAt: this.#time(), outcome: null });
    this.#increment(this.#counters, 'intentsPublished');
    this.#increment(this.#counters, origin === 'model' ? 'modelIntentsPublished' : 'localIntentsPublished');
    if (this.#commands.size > this.#limit) {
      const oldest = this.#commands.keys().next().value;
      if (this.#commands.get(oldest).outcome === null) {
        if (this.#unresolvedEvicted < MAX) this.#unresolvedEvicted++;
        else this.#counterOverflow = true;
      }
      this.#commands.delete(oldest);
      if (this.#correlationsEvicted < MAX) this.#correlationsEvicted++;
      else this.#counterOverflow = true;
    }
    return true;
  }

  observeOutcome(value) {
    const identity = commandIdentity(value);
    if (!identity || !TERMINAL_STATUSES.includes(value.status)) return false;
    const command = this.#commands.get(commandKey(identity));
    if (!command || command.outcome !== null) return false;
    command.outcome = outcomeSummary(value, this.#time());
    this.#increment(this.#counters, 'matchedReceipts');
    this.#increment(this.#receiptStatuses, value.status);
    if (value.status === 'observed_effect') this.#increment(this.#counters, 'observedEffects');
    if (value.status === 'arrived') this.#increment(this.#counters, 'arrivals');
    return true;
  }

  snapshot() {
    return copy({ schemaVersion: 1, scope: 'bridge_process', runId: this.#runId, startedAt: this.#startedAt,
      config: this.#config, counters: this.#counters, receiptStatuses: this.#receiptStatuses,
      usage: { responses: this.#counters.responses, providerFailures: this.#counters.providerFailures, ...this.#usage },
      recentAttempts: [...this.#attempts.values()], recentCommands: [...this.#commands.values()],
      publishedNamespace: this.#publishedNamespace, highestPublishedSequence: this.#highestPublishedSequence,
      correlationsEvicted: this.#correlationsEvicted, unresolvedEvicted: this.#unresolvedEvicted,
      unresolvedTracked: [...this.#commands.values()].filter(command => command.outcome === null).length,
      counterOverflow: this.#counterOverflow });
  }
}
