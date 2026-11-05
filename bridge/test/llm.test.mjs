import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import http from 'node:http';
import { promisify } from 'node:util';
import test from 'node:test';

const execute = promisify(execFile);
const moduleURL = new URL('../llm.mjs', import.meta.url).href;

async function call(env) {
  const program = `import { callLLM } from ${JSON.stringify(moduleURL)};\ntry { console.log(await callLLM('synthetic prompt')); } catch (e) { console.error(e.message); process.exitCode=1; }`;
  return execute(process.execPath, ['--input-type=module', '-e', program], {
    env: { PATH: process.env.PATH, PZ_BACKEND: 'openai', PZ_MODEL: 'synthetic-model', PZ_TIMEOUT: '2000', ...env },
    timeout: 5000,
  });
}

async function endpoint(t, respond) {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let raw = '';
    for await (const part of req) raw += part;
    requests.push({ headers: req.headers, body: JSON.parse(raw) });
    respond(res);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  return { url: `http://127.0.0.1:${server.address().port}/v1`, requests };
}

const success = res => {
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ choices: [{ message: { content: 'synthetic reply' } }] }));
};

test('explicit loopback keyless mode omits inherited credentials and bounds output', async t => {
  const api = await endpoint(t, success);
  const result = await call({ OPENAI_BASE_URL: api.url, OPENAI_API_KEY: 'synthetic-unused-key',
    PZ_API_KEYLESS: '1', PZ_REASONING_EFFORT: 'none' });
  assert.equal(result.stdout.trim(), 'synthetic reply');
  assert.equal(api.requests.length, 1);
  assert.equal(api.requests[0].headers.authorization, undefined);
  assert.equal(api.requests[0].body.max_completion_tokens, 500);
  assert.equal(api.requests[0].body.max_tokens, undefined);
  assert.equal(api.requests[0].body.reasoning_effort, 'none');
});

test('keyed backend still sends explicitly supplied synthetic fixture credential', async t => {
  const api = await endpoint(t, success);
  await call({ OPENAI_BASE_URL: api.url, OPENAI_API_KEY: 'synthetic-fixture-key' });
  assert.equal(api.requests.length, 1);
  assert.equal(api.requests[0].headers.authorization, 'Bearer synthetic-fixture-key');
});

test('keyless remote endpoints are rejected before any request', async () => {
  await assert.rejects(call({ OPENAI_BASE_URL: 'https://example.invalid/v1', PZ_API_KEYLESS: '1' }),
    error => /restricted to loopback/.test(error.stderr));
});

test('missing key and credential-bearing URL fail before network access', async t => {
  const api = await endpoint(t, success);
  await assert.rejects(call({ OPENAI_BASE_URL: api.url }), error => /not configured/.test(error.stderr));
  await assert.rejects(call({ OPENAI_BASE_URL: 'http://fixture:fixture@127.0.0.1:1/v1', PZ_API_KEYLESS: '1' }),
    error => /must not contain credentials/.test(error.stderr));
  assert.equal(api.requests.length, 0);
});

test('provider error bodies never appear in the surfaced error', async t => {
  const api = await endpoint(t, res => { res.statusCode = 401; res.end('private-fixture-provider-details'); });
  await assert.rejects(call({ OPENAI_BASE_URL: api.url, PZ_API_KEYLESS: '1' }), error => {
    assert.match(error.stderr, /openai HTTP 401/);
    assert.doesNotMatch(error.stderr, /private-fixture-provider-details/);
    return true;
  });
});

test('redirects are refused before reaching their destination', async t => {
  const destination = await endpoint(t, success);
  const api = await endpoint(t, res => {
    res.statusCode = 307;
    res.setHeader('Location', destination.url + '/chat/completions');
    res.end();
  });
  await assert.rejects(call({ OPENAI_BASE_URL: api.url, OPENAI_API_KEY: 'synthetic-fixture-key' }));
  assert.equal(destination.requests.length, 0);
});
