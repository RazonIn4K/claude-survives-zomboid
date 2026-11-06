import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import test from 'node:test';

const execute = promisify(execFile);
const moduleURL = new URL('../llm.mjs', import.meta.url).href;
const unknownUsage = { inputTokens: null, outputTokens: null, totalTokens: null };
const envBase = { PATH: process.env.PATH, PZ_BACKEND: 'openai', PZ_MODEL: 'fixture-requested',
  PZ_API_KEYLESS: '1', OPENAI_BASE_URL: 'http://127.0.0.1:1/v1', PZ_TIMEOUT: '1000' };

async function child(env = {}, before = '', mode = 'call') {
  const program = `${before}\nconst m = await import(${JSON.stringify(moduleURL)});
    const config = m.publicModelConfig();
    ${mode === 'config' ? 'console.log(JSON.stringify(config));' : `
    try { console.log(JSON.stringify({config, ...(await m.callLLMResult('synthetic prompt'))})); }
    catch (e) { console.log(JSON.stringify({config, error:{code:e.code,message:e.message,metadata:e.metadata}})); }`}`;
  const { stdout } = await execute(process.execPath, ['--input-type=module', '-e', program], {
    env: { ...envBase, ...env }, timeout: 5000,
  });
  return JSON.parse(stdout);
}

function stub(body, headers = {}, additional = '') {
  return `globalThis.fetch = async () => { ${additional} return new Response(${JSON.stringify(JSON.stringify(body))},
    {status:200,headers:${JSON.stringify(headers)}}); };`;
}

async function endpoint(t, handler) {
  const server = http.createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  return `http://127.0.0.1:${server.address().port}/v1`;
}

const reply = content => ({ choices: [{ message: { content } }] });

test('HTTP adapter retains allowlisted metadata before any decision parsing', async t => {
  let count = 0;
  const url = await endpoint(t, (req, res) => {
    count++;
    assert.equal(req.headers.authorization, undefined);
    req.resume();
    res.writeHead(200, { 'content-type': 'application/json', 'x-request-id': 'req-fixture-1',
      'set-cookie': 'private-cookie-fixture' });
    res.end(JSON.stringify({ ...reply('not a JSON decision'), model: 'fixture-returned', id: 'chatcmpl-fixture-1',
      usage: { prompt_tokens: 14, completion_tokens: 8, total_tokens: 22, private: 'private-usage-fixture' },
      privateAccount: 'private-account-fixture' }));
  });
  const result = await child({ OPENAI_BASE_URL: url });
  assert.equal(count, 1);
  assert.equal(result.text, 'not a JSON decision');
  assert.deepEqual(result.config, { backend: 'openai', requestedModel: 'fixture-requested',
    endpointOrigin: new URL(url).origin, authMode: 'keyless_loopback' });
  const m = result.metadata;
  assert.equal(m.backend, 'openai'); assert.equal(m.requestedModel, 'fixture-requested');
  assert.equal(m.returnedModel, 'fixture-returned'); assert.equal(m.requestId, 'req-fixture-1');
  assert.equal(m.responseId, 'chatcmpl-fixture-1'); assert.equal(m.httpStatus, 200);
  assert.ok(Number.isInteger(m.latencyMs) && m.latencyMs >= 0);
  assert.deepEqual(m.usage, { inputTokens: 14, outputTokens: 8, totalTokens: 22 });
  assert.deepEqual(Object.keys(m).sort(), ['backend', 'requestedModel', 'returnedModel', 'requestId', 'responseId', 'latencyMs', 'httpStatus', 'usage'].sort());
  assert.doesNotMatch(JSON.stringify(result), /private-(?:cookie|usage|account)-fixture/);
});

test('missing usage is unknown while explicit zero is retained', async () => {
  const missing = await child({}, stub(reply('fixture')));
  assert.deepEqual(missing.metadata.usage, unknownUsage);
  assert.equal(missing.metadata.returnedModel, null); assert.equal(missing.metadata.requestId, null);
  assert.equal(missing.metadata.responseId, null);
  const zero = await child({}, stub({ ...reply('fixture'), usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 } }));
  assert.deepEqual(zero.metadata.usage, { inputTokens: 0, outputTokens: 0, totalTokens: 0 });
});

test('partial and malformed token fields do not become valid numbers or an inferred total', async () => {
  const partial = await child({}, stub({ ...reply('fixture'), usage: { prompt_tokens: 15, completion_tokens: 3 } }));
  assert.deepEqual(partial.metadata.usage, { inputTokens: 15, outputTokens: 3, totalTokens: null });
  for (const value of ['12', -1, 2.5, true, Number.MAX_SAFE_INTEGER + 1]) {
    const result = await child({}, stub({ ...reply('fixture'), usage: { prompt_tokens: value, completion_tokens: 4, total_tokens: value } }));
    assert.deepEqual(result.metadata.usage, { inputTokens: null, outputTokens: 4, totalTokens: null });
  }
});

test('backend-specific usage retains reported categories without adding a derived total', async () => {
  const cases = [
    ['anthropic', { content: [{ type: 'text', text: 'fixture' }], model: 'claude-fixture', id: 'msg-fixture',
      usage: { input_tokens: 12, output_tokens: 6, cache_read_input_tokens: 20, total_tokens: 38 } },
    { inputTokens: 12, outputTokens: 6, totalTokens: null }, 'claude-fixture', 'msg-fixture', 'api_key'],
    ['ollama', { message: { content: 'fixture' }, model: 'ollama-fixture:latest', prompt_eval_count: 11, eval_count: 18, total_tokens: 29 },
    { inputTokens: 11, outputTokens: 18, totalTokens: null }, 'ollama-fixture:latest', null, 'none'],
    ['gemini', { candidates: [{ content: { parts: [{ text: 'fixture' }] } }], modelVersion: 'gemini-fixture', responseId: 'response-fixture',
      usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, thoughtsTokenCount: 7, totalTokenCount: 22 } },
    { inputTokens: 10, outputTokens: 5, totalTokens: 22 }, 'gemini-fixture', 'response-fixture', 'api_key'],
  ];
  for (const [backend, body, usage, model, id, authMode] of cases) {
    const result = await child({ PZ_BACKEND: backend }, stub(body, { 'request-id': 'req-header-fixture' }));
    assert.equal(result.text, 'fixture'); assert.deepEqual(result.metadata.usage, usage);
    assert.equal(result.metadata.backend, backend); assert.equal(result.metadata.returnedModel, model);
    assert.equal(result.metadata.responseId, id); assert.equal(result.metadata.requestId, 'req-header-fixture');
    assert.equal(result.config.authMode, authMode);
  }
});

test('latency uses a monotonic clock rather than wall time', async () => {
  const result = await child({}, `Date.now = () => -987654321;\n${stub(reply('fixture'), {}, 'await new Promise(resolve => setTimeout(resolve, 25));')}`);
  assert.ok(result.metadata.latencyMs >= 20 && result.metadata.latencyMs < 2000);
});

test('identifier fields reject known credentials, credential-like strings, markup and oversized values', async () => {
  const secret = 'synthetic-private-credential-value';
  const cases = [secret, 'prefix-' + secret, 'sk-private-fixture', 'github_pat_private_fixture', 'ghp_private_fixture',
    'AIzaFixtureCredential', '<script>fixture</script>', 'https://example.invalid/private', 'x'.repeat(181), ['fixture']];
  for (const value of cases) {
    const result = await child({ OPENAI_API_KEY: secret }, stub({ ...reply('fixture'), model: value, id: value },
      { 'x-request-id': typeof value === 'string' ? value : 'sk-private-fixture' }));
    assert.equal(result.metadata.returnedModel, null); assert.equal(result.metadata.responseId, null);
    assert.equal(result.metadata.requestId, null);
    assert.doesNotMatch(JSON.stringify(result.metadata), /private|<script>/);
  }
});

test('public configuration omits URL paths, query secrets, credentials and unsafe model values', async () => {
  const secret = 'synthetic-private-credential-value';
  const originOnly = await child({ OPENAI_BASE_URL: `https://example.invalid/private/path?key=${secret}#private`,
    OPENAI_API_KEY: secret, PZ_API_KEYLESS: '0' }, '', 'config');
  assert.equal(originOnly.endpointOrigin, 'https://example.invalid'); assert.equal(originOnly.authMode, 'api_key');
  assert.doesNotMatch(JSON.stringify(originOnly), /private|path|key=/);
  for (const url of ['https://user:password@example.invalid/v1', 'not a valid private url', `https://${secret}.invalid/v1`]) {
    const config = await child({ OPENAI_BASE_URL: url, OPENAI_API_KEY: secret, PZ_MODEL: secret }, '', 'config');
    assert.equal(config.endpointOrigin, null); assert.equal(config.requestedModel, null);
    assert.doesNotMatch(JSON.stringify(config), /private|password|user/);
  }
  const alias = await child({ PZ_BACKEND: 'openai-compat' }, '', 'config'); assert.equal(alias.backend, 'openai-compat');
  const caseFolded = await child({ OPENAI_API_KEY: 'MixedCasePrivateCredential',
    OPENAI_BASE_URL: 'https://MixedCasePrivateCredential.example.invalid/v1' }, '', 'config');
  assert.equal(caseFolded.endpointOrigin, null);
  assert.doesNotMatch(JSON.stringify(caseFolded), /mixedcaseprivatecredential/i);
  const fallback = await child({ PZ_BACKEND: 'misspelled-provider' }, '', 'config');
  assert.equal(fallback.backend, 'claude-cli'); assert.equal(fallback.endpointOrigin, null);
  assert.equal(fallback.authMode, 'cli_subscription_or_login');
});

test('HTTP failure metadata preserves status and request id but excludes the body and unknown usage', async t => {
  const url = await endpoint(t, (req, res) => {
    req.resume(); res.writeHead(429, { 'x-request-id': 'req-error-fixture' });
    res.end('private-account-and-prompt-fixture');
  });
  const result = await child({ OPENAI_BASE_URL: url });
  assert.equal(result.error.code, 'http_error'); assert.equal(result.error.message, 'openai HTTP 429');
  assert.equal(result.error.metadata.httpStatus, 429); assert.equal(result.error.metadata.requestId, 'req-error-fixture');
  assert.deepEqual(result.error.metadata.usage, unknownUsage);
  assert.doesNotMatch(JSON.stringify(result), /private-account-and-prompt-fixture/);
});

test('malformed provider JSON and non-object envelopes expose stable errors without body snippets', async t => {
  const url = await endpoint(t, (req, res) => { req.resume(); res.end('{private-fixture-json'); });
  const result = await child({ OPENAI_BASE_URL: url });
  assert.equal(result.error.code, 'invalid_response'); assert.equal(result.error.metadata.httpStatus, 200);
  assert.equal(result.error.message, 'Model provider returned invalid JSON');
  assert.doesNotMatch(JSON.stringify(result), /private-fixture-json/);
  for (const body of [null, [], 4]) {
    const invalid = await child({}, stub(body));
    assert.equal(invalid.error.code, 'invalid_response'); assert.deepEqual(invalid.error.metadata.usage, unknownUsage);
  }
});

test('valid reported usage survives unsupported response text without leaking its content', async () => {
  const result = await child({}, stub({ ...reply([{ private: 'private-content-fixture' }]),
    usage: { prompt_tokens: 9, completion_tokens: 5, total_tokens: 14 } }));
  assert.equal(result.error.code, 'invalid_response');
  assert.deepEqual(result.error.metadata.usage, { inputTokens: 9, outputTokens: 5, totalTokens: 14 });
  assert.doesNotMatch(JSON.stringify(result), /private-content-fixture/);
});

test('timeout and transport failures contain metadata without raw request or network diagnostics', async t => {
  const url = await endpoint(t, req => req.resume());
  const timedOut = await child({ OPENAI_BASE_URL: url, PZ_TIMEOUT: '80' });
  assert.equal(timedOut.error.code, 'timeout'); assert.equal(timedOut.error.metadata.httpStatus, null);
  assert.ok(timedOut.error.metadata.latencyMs >= 70); assert.deepEqual(timedOut.error.metadata.usage, unknownUsage);
  const network = await child({}, "globalThis.fetch = async () => { throw new Error('private-fixture-URL-and-key'); };");
  assert.equal(network.error.code, 'network_error'); assert.equal(network.error.metadata.httpStatus, null);
  assert.doesNotMatch(JSON.stringify(network), /private-fixture-URL-and-key/);
});

test('configuration failures retain their category without attempting a network request', async () => {
  const result = await child({ OPENAI_BASE_URL: 'https://private-fixture.invalid/v1' },
    "globalThis.fetch = async () => { throw new Error('network must not run'); };");
  assert.equal(result.error.code, 'configuration_error'); assert.equal(result.error.metadata.httpStatus, null);
  assert.deepEqual(result.error.metadata.usage, unknownUsage);
  assert.equal(result.error.message, 'Keyless model access is restricted to loopback');
});

test('timeout during response body consumption retains headers without body disclosure', async t => {
  const url = await endpoint(t, (req, res) => {
    req.resume();
    res.writeHead(200, { 'content-type': 'application/json', 'x-request-id': 'req-body-timeout-fixture' });
    res.write('{"private":"unfinished-private-fixture');
  });
  const result = await child({ OPENAI_BASE_URL: url, PZ_TIMEOUT: '250' });
  assert.equal(result.error.code, 'timeout');assert.equal(result.error.metadata.httpStatus, 200);
  assert.equal(result.error.metadata.requestId, 'req-body-timeout-fixture');
  assert.deepEqual(result.error.metadata.usage, unknownUsage);
  assert.doesNotMatch(JSON.stringify(result), /unfinished-private-fixture/);
});

test('CLI text works with unavailable provider usage and CLI failures do not reveal local paths', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pz-llm-cli-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'synthetic-cli');
  fs.writeFileSync(bin, '#!/bin/sh\nprintf "fixture CLI reply\\n"\n', { mode: 0o700 });
  const result = await child({ PZ_BACKEND: 'claude-cli', CLAUDE_BIN: bin });
  assert.equal(result.text, 'fixture CLI reply'); assert.deepEqual(result.metadata.usage, unknownUsage);
  assert.equal(result.metadata.httpStatus, null); assert.equal(result.metadata.returnedModel, null);
  const missing = await child({ PZ_BACKEND: 'unknown-falls-back-to-cli', CLAUDE_BIN: path.join(root, 'private-missing-file') });
  assert.equal(missing.error.code, 'cli_error'); assert.equal(missing.error.metadata.backend, 'claude-cli');
  assert.doesNotMatch(JSON.stringify(missing), /private-missing-file|pz-llm-cli-/);
});
