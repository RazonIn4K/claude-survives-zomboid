import assert from 'node:assert/strict';
import test from 'node:test';
import { RunTelemetry } from '../telemetry.mjs';

const identity = (seq = 1, action = 'LOOT', changes = {}) => ({ world: 'fixture-world', actor: '0',
  session: 'fixture-session', seq, action, ...changes });
const receipt = (seq = 1, status = 'observed_effect', changes = {}) => ({ ...identity(seq), status, ...changes });
const metadata = changes => ({ backend: 'openai', requestedModel: 'fixture-model', returnedModel: 'reported-model',
  requestId: 'request-1', responseId: 'response-1', latencyMs: 20, httpStatus: 200,
  usage: { inputTokens: 12, outputTokens: 3, totalTokens: 15 }, ...changes });
const ledger = options => new RunTelemetry({ runId: 'fixture-run', now: () => 1000, ...options });
function published(run, seq = 1, action = 'LOOT', changes = {}) {
  const id = run.beginAttempt();
  assert.equal(run.recordResponse(id, metadata()), true);
  assert.equal(run.publishIntent(id, identity(seq, action, changes)), true);
  return id;
}

test('attempts, responses, publications and observed outcomes are separate evidence', () => {
  const run = ledger();
  const id = run.beginAttempt();
  assert.equal(run.snapshot().counters.attempts, 1);
  assert.equal(run.snapshot().counters.responses, 0);
  assert.equal(run.recordResponse(id, metadata()), true);
  assert.equal(run.snapshot().counters.intentsPublished, 0);
  assert.equal(run.publishIntent(id, identity()), true);
  assert.equal(run.snapshot().unresolvedTracked, 1);
  assert.equal(run.observeOutcome(receipt(1, 'pending')), false);
  assert.equal(run.observeOutcome(receipt(1, 'observed_effect', { added: 2 })), true);
  const snapshot = run.snapshot();
  assert.deepEqual(snapshot.counters, { attempts: 1, responses: 1, providerFailures: 0, invalidDecisions: 0,
    discardedDecisions: 0, publicationFailures: 0, intentsPublished: 1, matchedReceipts: 1, observedEffects: 1, arrivals: 0 });
  assert.equal(snapshot.unresolvedTracked, 0);
  assert.equal(snapshot.recentCommands[0].outcome.added, 2);
  assert.equal(snapshot.recentAttempts[0].disposition, 'published');
});

test('provider success counts usage even when decision is invalid, stale or cannot publish', () => {
  const run = ledger();
  for (const [disposition, reason] of [['invalid', 'invalid_json'], ['discarded', 'stale_percept'],
    ['publication_failed', 'intent_write_failed']]) {
    const id = run.beginAttempt();
    run.recordResponse(id, metadata());
    assert.equal(run.rejectDecision(id, reason, disposition), true);
    assert.equal(run.rejectDecision(id, reason, disposition), false);
    assert.equal(run.publishIntent(id, identity(id)), false);
  }
  const snapshot = run.snapshot();
  assert.equal(snapshot.counters.responses, 3);
  assert.equal(snapshot.counters.invalidDecisions, 1);
  assert.equal(snapshot.counters.discardedDecisions, 1);
  assert.equal(snapshot.counters.publicationFailures, 1);
  assert.equal(snapshot.counters.intentsPublished, 0);
  assert.deepEqual(snapshot.usage.inputTokens, { tokens: 36, reportedResponses: 3, missingResponses: 0, overflowed: false });
});

test('repeated response, failure and publication callbacks cannot inflate counters', () => {
  const run = ledger();
  const id = published(run);
  assert.equal(run.recordResponse(id, metadata()), false);
  assert.equal(run.recordFailure(id, metadata(), 'http_error'), false);
  assert.equal(run.publishIntent(id, identity()), false);
  assert.equal(run.publishIntent(id, identity(2)), false);
  const other = run.beginAttempt(); run.recordResponse(other, metadata());
  assert.equal(run.publishIntent(other, identity()), false);
  assert.equal(run.publishIntent(other, identity(1, 'EAT')), false);
  const failed = run.beginAttempt();
  assert.equal(run.recordFailure(failed, { httpStatus: 401 }, 'http_error'), true);
  assert.equal(run.recordFailure(failed, {}, 'http_error'), false);
  assert.equal(run.recordResponse(failed, metadata()), false);
  assert.equal(run.rejectDecision(failed, 'invalid_json'), false);
  assert.equal(run.publishIntent(failed, identity(3)), false);
  assert.equal(run.snapshot().counters.intentsPublished, 1);
  assert.equal(run.snapshot().counters.responses, 2);
  assert.equal(run.snapshot().counters.providerFailures, 1);
});

test('A-B-A receipt replay and terminal-status changes count each published command once', () => {
  const run = ledger();
  published(run, 1); published(run, 2);
  assert.equal(run.observeOutcome(receipt(1)), true);
  assert.equal(run.observeOutcome(receipt(2, 'no_effect')), true);
  assert.equal(run.observeOutcome(receipt(1)), false);
  assert.equal(run.observeOutcome(receipt(2, 'observed_effect')), false);
  assert.equal(run.snapshot().counters.matchedReceipts, 2);
  assert.equal(run.snapshot().counters.observedEffects, 1);
  assert.equal(run.snapshot().receiptStatuses.no_effect, 1);
});

test('foreign identity, action and sequence receipts cannot claim progress', () => {
  const run = ledger(); published(run);
  for (const changes of [{ world: 'other' }, { actor: 'other' }, { session: 'other' }, { seq: 2 }, { action: 'EAT' }]) {
    assert.equal(run.observeOutcome(receipt(1, 'observed_effect', changes)), false);
  }
  assert.equal(run.snapshot().counters.matchedReceipts, 0);
  assert.equal(run.snapshot().unresolvedTracked, 1);
  // There is intentionally no current-percept session check: after takeover a
  // cancellation receipt still belongs to the original published identity.
  assert.equal(run.observeOutcome(receipt(1, 'interrupted')), true);
  assert.equal(run.snapshot().receiptStatuses.interrupted, 1);
});

test('startup and prepublication receipts are not queued to become accomplishments', () => {
  const run = ledger();
  assert.equal(run.observeOutcome(receipt()), false);
  const id = run.beginAttempt();
  assert.equal(run.observeOutcome(receipt()), false);
  run.recordResponse(id, metadata());
  assert.equal(run.observeOutcome(receipt()), false);
  run.publishIntent(id, identity());
  assert.equal(run.snapshot().counters.matchedReceipts, 0);
  assert.equal(run.snapshot().unresolvedTracked, 1);
});

test('arrival is separate from observed effects and all terminal categories are preserved', () => {
  const run = ledger();
  for (const [index, status] of ['observed_effect', 'arrived', 'no_effect', 'unverified', 'interrupted', 'native_failed'].entries()) {
    const action = status === 'arrived' ? 'NAVIGATE' : 'LOOT';
    published(run, index + 1, action);
    assert.equal(run.observeOutcome(receipt(index + 1, status, { action })), true);
  }
  const snapshot = run.snapshot();
  assert.equal(snapshot.counters.matchedReceipts, 6);
  assert.equal(snapshot.counters.observedEffects, 1);
  assert.equal(snapshot.counters.arrivals, 1);
  assert.deepEqual(snapshot.receiptStatuses, { observed_effect: 1, arrived: 1, no_effect: 1,
    unverified: 1, interrupted: 1, native_failed: 1 });
});

test('eviction bounds records and late callbacks never recreate a correlation', () => {
  const run = ledger({ limit: 2 });
  const first = published(run, 1); published(run, 2); published(run, 3);
  assert.equal(run.observeOutcome(receipt(1)), false);
  assert.equal(run.recordResponse(first, metadata()), false);
  assert.equal(run.publishIntent(first, identity(1)), false);
  assert.equal(run.recordFailure(first, {}, 'timeout'), false);
  assert.equal(run.rejectDecision(first, 'stale_percept', 'discarded'), false);
  assert.equal(run.observeOutcome(receipt(2)), true);
  assert.equal(run.observeOutcome(receipt(3)), true);
  const snapshot = run.snapshot();
  assert.equal(snapshot.recentAttempts.length, 2); assert.equal(snapshot.recentCommands.length, 2);
  assert.equal(snapshot.correlationsEvicted, 1); assert.equal(snapshot.unresolvedEvicted, 1);
  assert.equal(snapshot.counters.attempts, 3); assert.equal(snapshot.counters.intentsPublished, 3);
  assert.equal(snapshot.counters.matchedReceipts, 2); assert.equal(snapshot.unresolvedTracked, 0);
});

test('resolved-command eviction does not increase unresolved loss or permit recounting', () => {
  const run = ledger({ limit: 1 });
  published(run, 1); run.observeOutcome(receipt(1)); published(run, 2);
  assert.equal(run.observeOutcome(receipt(1)), false);
  assert.equal(run.snapshot().correlationsEvicted, 1);
  assert.equal(run.snapshot().unresolvedEvicted, 0);
  assert.equal(run.snapshot().counters.observedEffects, 1);
});

test('published namespace and sequence high-water mark survive eviction without an unbounded ID set', () => {
  const run = ledger({ limit: 1 });
  published(run, 1); run.observeOutcome(receipt(1)); published(run, 2);
  const id = run.beginAttempt(); run.recordResponse(id, metadata());
  assert.equal(run.publishIntent(id, identity(1)), false, 'new attempt cannot republish an evicted sequence');
  assert.equal(run.publishIntent(id, identity(1, 'EAT')), false, 'changing action cannot reuse an evicted sequence');
  assert.equal(run.publishIntent(id, identity(3, 'LOOT', { session: 'replacement' })), false);
  assert.equal(run.publishIntent(id, identity(3, 'LOOT', { actor: 'replacement' })), false);
  assert.equal(run.publishIntent(id, identity(3, 'LOOT', { world: 'replacement' })), false);
  assert.equal(run.observeOutcome(receipt(1)), false);
  assert.equal(run.snapshot().counters.intentsPublished, 2);
  assert.equal(run.snapshot().counters.matchedReceipts, 1);
  assert.equal(run.publishIntent(id, identity(3)), true);
  assert.equal(run.snapshot().highestPublishedSequence, 3);
  assert.deepEqual(run.snapshot().publishedNamespace, { world: 'fixture-world', actor: '0', session: 'fixture-session' });
});

test('missing and partial token usage remain unknown while explicit zero is preserved', () => {
  const run = ledger();
  let id = run.beginAttempt(); run.recordResponse(id, {});
  assert.deepEqual(run.snapshot().usage.totalTokens, { tokens: null, reportedResponses: 0, missingResponses: 1, overflowed: false });
  id = run.beginAttempt(); run.recordResponse(id, metadata({ usage: { inputTokens: 0, outputTokens: 5 } }));
  const snapshot = run.snapshot();
  assert.deepEqual(snapshot.usage.inputTokens, { tokens: 0, reportedResponses: 1, missingResponses: 1, overflowed: false });
  assert.deepEqual(snapshot.usage.outputTokens, { tokens: 5, reportedResponses: 1, missingResponses: 1, overflowed: false });
  assert.equal(snapshot.usage.totalTokens.tokens, null, 'never infer provider total from partial fields');
  assert.equal(snapshot.usage.totalTokens.missingResponses, 2);
});

test('invalid token values do not count toward coverage and overflow stays explicit', () => {
  const run = ledger();
  for (const value of [-1, 1.5, '4', NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, null, true]) {
    const id = run.beginAttempt();
    run.recordResponse(id, metadata({ usage: { inputTokens: value, outputTokens: value, totalTokens: value } }));
  }
  assert.equal(run.snapshot().usage.inputTokens.reportedResponses, 0);
  assert.equal(run.snapshot().usage.inputTokens.missingResponses, 8);
  for (const value of [Number.MAX_SAFE_INTEGER, 1, 0]) {
    const id = run.beginAttempt(); run.recordResponse(id, metadata({ usage: { inputTokens: value } }));
  }
  assert.deepEqual(run.snapshot().usage.inputTokens, { tokens: null, reportedResponses: 3, missingResponses: 8, overflowed: true });
  assert.equal(run.snapshot().usage.responses, 11);
});

test('provider failures have separate coverage and never pretend to consume zero tokens', () => {
  const run = ledger(); const id = run.beginAttempt();
  run.recordFailure(id, { httpStatus: 429, usage: { inputTokens: 99 } }, 'http_error');
  const snapshot = run.snapshot();
  assert.equal(snapshot.usage.providerFailures, 1); assert.equal(snapshot.usage.responses, 0);
  assert.equal(snapshot.usage.inputTokens.tokens, null); assert.equal(snapshot.usage.inputTokens.reportedResponses, 0);
  assert.equal(snapshot.recentAttempts[0].metadata.httpStatus, 429);
  assert.equal(snapshot.recentAttempts[0].errorCode, 'http_error');
});

test('configuration and response metadata keep only bounded nonsecret fields', () => {
  const run = ledger({ config: { backend: 'openai', requestedModel: 'fixture-model', authMode: 'keyless_loopback',
    endpointOrigin: 'http://127.0.0.1:4141/v1/private-fixture-path?key=private-query#private-fragment', apiKey: 'private-config-key' } });
  const id = run.beginAttempt();
  run.recordResponse(id, metadata({ requestId: 'sk-private-fixture', responseId: 'x'.repeat(181),
    returnedModel: '<img src=x>', headers: { authorization: 'private-header' }, body: 'private-body',
    prompt: 'private-prompt', labToken: 'private-controller-token', usage: { inputTokens: 1, secret: 'private-usage' } }));
  run.rejectDecision(id, 'private freeform reason');
  const snapshot = run.snapshot(); const serialized = JSON.stringify(snapshot);
  assert.equal(snapshot.config.endpointOrigin, 'http://127.0.0.1:4141');
  assert.equal(snapshot.recentAttempts[0].metadata.requestId, null);
  assert.equal(snapshot.recentAttempts[0].metadata.responseId, null);
  assert.equal(snapshot.recentAttempts[0].metadata.returnedModel, null);
  assert.equal(snapshot.recentAttempts[0].reason, 'decision_rejected');
  assert.doesNotMatch(serialized, /private-|private freeform|authorization|labToken|<img/);
  assert.equal(ledger({ config: { endpointOrigin: 'https://user:pass@example.invalid' } }).snapshot().config.endpointOrigin, null);
  assert.equal(ledger({ config: { endpointOrigin: 'file:///private' } }).snapshot().config.endpointOrigin, null);
  for (const value of ['https://example.invalid/model', 'copilot/sk-private-fixture', 'provider:github_pat_private']) {
    const other = ledger(); const attempt = other.beginAttempt();
    other.recordResponse(attempt, metadata({ returnedModel: value, requestId: value, responseId: value }));
    const result = other.snapshot().recentAttempts[0].metadata;
    assert.equal(result.returnedModel, null); assert.equal(result.requestId, null); assert.equal(result.responseId, null);
  }
});

test('outcome summaries exclude arbitrary text, tokens, identities and invalid metrics', () => {
  const run = ledger(); published(run, 1, 'BANDAGE');
  run.observeOutcome(receipt(1, 'observed_effect', { action: 'BANDAGE', detail: 'private-detail', labToken: 'private-token',
    added: Infinity, hungerDrop: -1, thirstDrop: '2', consumed: true, bandaged: true, finalX: 101.25, finalZ: 101,
    metadata: { body: 'private-body' } }));
  const outcome = run.snapshot().recentCommands[0].outcome;
  assert.deepEqual(outcome, { status: 'observed_effect', observedAt: 1000, finalX: 101.25, bandaged: true, consumed: true });
  assert.doesNotMatch(JSON.stringify(run.snapshot()), /private-/);
});

test('invalid IDs, command identities and statuses fail closed', () => {
  const run = ledger(); const id = run.beginAttempt(); run.recordResponse(id, metadata());
  for (const invalid of [0, -1, 1.5, '1', NaN, Number.MAX_SAFE_INTEGER + 1]) {
    assert.equal(run.recordResponse(invalid, metadata()), false);
    assert.equal(run.recordFailure(invalid, {}, 'timeout'), false);
    assert.equal(run.publishIntent(invalid, identity()), false);
  }
  for (const changes of [{ seq: 0 }, { seq: 2147483648 }, { seq: '1' }, { actor: '' }, { world: 'with spaces' },
    { session: undefined }, { action: 'EXEC' }]) {
    assert.equal(run.publishIntent(id, identity(1, 'LOOT', changes)), false);
    assert.equal(run.observeOutcome(receipt(1, 'observed_effect', changes)), false);
  }
  assert.equal(run.publishIntent(id, identity()), true);
  for (const status of ['pending', 'success', '', null, {}, ['observed_effect']]) {
    assert.equal(run.observeOutcome(receipt(1, status)), false);
  }
  assert.equal(run.observeOutcome(null), false);
  assert.equal(run.observeOutcome([]), false);
});

test('snapshots and supplied inputs cannot mutate ledger state; a new run starts fresh', () => {
  const config = { backend: 'openai', requestedModel: 'fixture-model' };
  const run = ledger({ config }); config.requestedModel = 'mutated';
  const supplied = metadata(); const id = run.beginAttempt(); run.recordResponse(id, supplied);
  supplied.usage.inputTokens = 999;
  const command = identity(); run.publishIntent(id, command); command.seq = 2;
  const suppliedReceipt = receipt(); run.observeOutcome(suppliedReceipt); suppliedReceipt.status = 'no_effect';
  const snapshot = run.snapshot(); snapshot.config.backend = 'mutated'; snapshot.counters.attempts = 999;
  snapshot.usage.inputTokens.tokens = 999; snapshot.recentAttempts[0].metadata.usage.inputTokens = 999;
  snapshot.recentCommands[0].outcome.status = 'mutated';
  const current = run.snapshot();
  assert.equal(current.config.requestedModel, 'fixture-model'); assert.equal(current.config.backend, 'openai');
  assert.equal(current.counters.attempts, 1); assert.equal(current.usage.inputTokens.tokens, 12);
  assert.equal(current.recentAttempts[0].metadata.usage.inputTokens, 12);
  assert.equal(current.recentCommands[0].seq, 1); assert.equal(current.recentCommands[0].outcome.status, 'observed_effect');
  const restarted = ledger({ runId: 'next-run', state: current }).snapshot();
  assert.equal(restarted.scope, 'bridge_process'); assert.equal(restarted.schemaVersion, 1);
  assert.equal(restarted.counters.attempts, 0); assert.equal(restarted.recentCommands.length, 0);
  assert.equal(restarted.usage.totalTokens.tokens, null);
});

test('retention remains bounded across a continuing sequence of decisions', () => {
  const run = ledger();
  for (let seq = 1; seq <= 250; seq++) { published(run, seq); run.observeOutcome(receipt(seq)); }
  const snapshot = run.snapshot();
  assert.equal(snapshot.recentAttempts.length, 100); assert.equal(snapshot.recentCommands.length, 100);
  assert.equal(snapshot.counters.attempts, 250); assert.equal(snapshot.counters.matchedReceipts, 250);
  assert.equal(snapshot.correlationsEvicted, 150); assert.equal(snapshot.unresolvedEvicted, 0);
  assert.equal(snapshot.recentAttempts[0].id, 151); assert.equal(snapshot.recentCommands[0].seq, 151);
  assert.equal(run.observeOutcome(receipt(1)), false);
});

test('invalid retention and clocks do not leak free-form errors into metadata', () => {
  for (const limit of [0, -1, 101, 1.2, '2']) assert.throws(() => ledger({ limit }), RangeError);
  assert.throws(() => ledger({ runId: 'bad run ID' }), TypeError);
  assert.throws(() => ledger({ now: null }), TypeError);
  const run = ledger({ now: () => { throw new Error('private-clock-error'); } });
  const id = run.beginAttempt(); run.recordFailure(id, { latencyMs: NaN, httpStatus: 999 }, 'private-error-code');
  const snapshot = run.snapshot();
  assert.equal(snapshot.startedAt, null); assert.equal(snapshot.recentAttempts[0].finishedAt, null);
  assert.equal(snapshot.recentAttempts[0].metadata.latencyMs, null); assert.equal(snapshot.recentAttempts[0].metadata.httpStatus, null);
  assert.equal(snapshot.recentAttempts[0].errorCode, 'provider_error');
  assert.doesNotMatch(JSON.stringify(snapshot), /private-/);
});
