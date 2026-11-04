import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const bridgeFile = fileURLToPath(new URL('../pz-bridge.mjs', import.meta.url));
const clockFixture = fileURLToPath(new URL('../test-support/clock.cjs', import.meta.url));

function temporaryRun(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pz-runtime-'));
  const luaDir = path.join(root, 'Lua');
  fs.mkdirSync(luaDir);
  const run = { root, luaDir, stateFile: path.join(root, 'memory.json') };
  t.after(async () => {
    // Stop the writer before removing its files or closing its fake model endpoint.
    if (run.child) {
      if (run.child.exitCode === null && run.child.signalCode === null) run.child.kill();
      await run.exited;
    }
    if (run.modelServer?.listening) {
      await new Promise((resolve, reject) => run.modelServer.close(error => error ? reject(error) : resolve()));
    }
    fs.rmSync(root, { recursive: true, force: true });
  });
  return run;
}

function startBridge(run, overrides, nodeOptions = []) {
  // Deliberately do not inherit the developer's credentials, provider configuration,
  // HOME, or CLI setup. Every file path and the only model endpoint are test-owned.
  const child = spawn(process.execPath, [...nodeOptions, bridgeFile], {
    cwd: run.root,
    env: {
      PZ_BACKEND: 'ollama',
      PZ_MODEL: 'synthetic-fixture',
      PZ_TIMEOUT: '2000',
      PZ_PORT: '0',
      PZ_LUA_DIR: run.luaDir,
      PZ_STATE_FILE: run.stateFile,
      ...overrides,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  const exited = once(child, 'exit');
  run.child = child;
  run.exited = exited;
  return { child, exited, output: () => output };
}

async function waitFor(predicate, failureMessage, timeout = 13000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const result = predicate();
    if (result) return result;
    await delay(25);
  }
  throw new Error(failureMessage());
}

test('bridge binds loopback and completes an isolated perception → fake model → intent cycle', { timeout: 20000 }, async t => {
  const run = temporaryRun(t);
  const requests = [];
  const percept = { fixture: 'isolated-runtime', dead: false, day: 1, hour: 9, hp: 100, zClose: 0, zNear: 0, qlen: 0 };
  const updatedPercept = { ...percept, x: 42 };
  const fakeOllama = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    requests.push({ url: req.url, method: req.method, body: JSON.parse(Buffer.concat(chunks).toString()) });
    // Ordinary in-place game updates during inference must remain supported.
    fs.writeFileSync(path.join(run.luaDir, 'claude_percept.json'), JSON.stringify(updatedPercept));
    res.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
    res.end(JSON.stringify({ message: { content: JSON.stringify({
      action: { type: 'MOVE', dx: 5, dy: -3 },
      say: 'synthetic smoke', thought: 'fixture only',
      goal: 'temporary test run', subtask: 'stay isolated', memory: 'synthetic-state',
    }) } }));
  });
  run.modelServer = fakeOllama;
  fakeOllama.listen(0, '127.0.0.1');
  await once(fakeOllama, 'listening');

  fs.writeFileSync(path.join(run.luaDir, 'claude_percept.json'), JSON.stringify(percept));
  const processRun = startBridge(run, { OLLAMA_URL: `http://127.0.0.1:${fakeOllama.address().port}` });
  const boot = await waitFor(() => processRun.output().match(/pz-bridge up on http:\/\/([^\s/]+)\/mind/),
    () => `Bridge did not start: ${processRun.output()}`, 5000);
  // Startup uses the actual server.address(), rather than merely printing config.
  assert.match(boot[1], /^127\.0\.0\.1:\d+$/);
  const base = `http://${boot[1]}`;
  const initial = await (await fetch(`${base}/api/state`)).json();
  assert.deepEqual(initial.percept, percept);
  assert.equal(initial.seq, 0);

  await waitFor(() => fs.existsSync(run.stateFile), () => `No isolated decision saved: ${processRun.output()}`);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/api/chat');
  assert.equal(requests[0].method, 'POST');
  assert.equal(requests[0].body.model, 'synthetic-fixture');
  assert.match(requests[0].body.messages[0].content, /isolated-runtime/);
  const intent = fs.readFileSync(path.join(run.luaDir, 'claude_intent.txt'), 'utf8');
  assert.equal(intent, '1|MOVE|5|-3|synthetic smoke|fixture only|stay isolated\n');
  assert.equal(await (await fetch(`${base}/pz/intent`)).text(), intent);
  const state = JSON.parse(fs.readFileSync(run.stateFile, 'utf8'));
  assert.equal(state.seq, 1);
  assert.equal(state.memory, 'synthetic-state');
  assert.equal(fs.existsSync(path.join(run.luaDir, 'claude_intent.txt.tmp')), false);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(run.luaDir, 'claude_percept.json'), 'utf8')), updatedPercept);
});

test('invalid configuration exits before creating intent or state files', { timeout: 5000 }, async t => {
  const run = temporaryRun(t);
  const processRun = startBridge(run, { PZ_PORT: '65536', OLLAMA_URL: 'http://127.0.0.1:1' });
  const [code] = await processRun.exited;
  assert.equal(code, 1);
  assert.match(processRun.output(), /pz-bridge configuration error: PZ_PORT/);
  assert.equal(fs.existsSync(run.stateFile), false);
  assert.deepEqual(fs.readdirSync(run.luaDir), []);
});

test('reading an old percept at startup does not make it fresh', { timeout: 5000 }, async t => {
  const run = temporaryRun(t);
  const file = path.join(run.luaDir, 'claude_percept.json');
  fs.writeFileSync(file, JSON.stringify({ dead: false, hp: 100 }));
  const old = new Date(Date.now() - 16000);
  fs.utimesSync(file, old, old);
  const processRun = startBridge(run, { OLLAMA_URL: 'http://127.0.0.1:1' });
  const boot = await waitFor(() => processRun.output().match(/pz-bridge up on http:\/\/([^\s/]+)\/mind/),
    () => `Bridge did not start: ${processRun.output()}`, 3000);
  const state = await (await fetch(`http://${boot[1]}/api/state`)).json();
  assert.equal(state.percept, null);
  assert.equal(state.perceptFresh, false);
  assert.equal(fs.existsSync(path.join(run.luaDir, 'claude_intent.txt')), false);
  assert.equal(fs.existsSync(run.stateFile), false);
});

test('a model reply cannot write an intent after its percept context becomes unsafe',
  { timeout: 20000, concurrency: true }, async t => {
    const cases = [
      ['slow inference despite fresh current data', (run, file, percept) => {
        fs.writeFileSync(run.clockFile, '16000');
        fs.writeFileSync(file, JSON.stringify(percept));
        const fresh = new Date(Date.now() + 16000);
        fs.utimesSync(file, fresh, fresh);
      }],
      ['retry expires the original percept', (run, file, percept) => {
        fs.writeFileSync(run.clockFile, '16000');
        fs.writeFileSync(file, JSON.stringify(percept));
        const fresh = new Date(Date.now() + 16000);
        fs.utimesSync(file, fresh, fresh);
      }, true],
      ['dead survivor', (_run, file, percept) => {
        fs.writeFileSync(file, JSON.stringify({ ...percept, dead: true }));
      }],
      ['replaced percept file', (_run, file, percept) => {
        fs.writeFileSync(file + '.replacement', JSON.stringify(percept));
        fs.renameSync(file + '.replacement', file);
      }],
      ['unreadable current percept', (_run, file) => fs.writeFileSync(file, '{')],
      ['stale current percept', (_run, file) => {
        const stale = new Date(Date.now() - 16000);
        fs.utimesSync(file, stale, stale);
      }],
    ];
    await Promise.all(cases.map(([name, invalidate, retry]) => t.test(name, async t => {
      const run = temporaryRun(t);
      run.clockFile = path.join(run.root, 'clock-offset-ms');
      fs.writeFileSync(run.clockFile, '0');
      let heldResponse;
      let modelCalls = 0;
      const server = http.createServer(async (req, res) => {
        for await (const _chunk of req) { /* consume the synthetic request */ }
        modelCalls++;
        if (retry && modelCalls === 1) {
          res.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
          res.end(JSON.stringify({ message: { content: 'invalid model JSON fixture' } }));
          return;
        }
        heldResponse = res;
      });
      run.modelServer = server;
      server.listen(0, '127.0.0.1');
      await once(server, 'listening');
      const percept = { dead: false, day: 1, hp: 100, zClose: 0, zNear: 0, qlen: 0 };
      const file = path.join(run.luaDir, 'claude_percept.json');
      const intentFile = path.join(run.luaDir, 'claude_intent.txt');
      fs.writeFileSync(file, JSON.stringify(percept));
      fs.writeFileSync(intentFile, 'previous-intent\n');
      const processRun = startBridge(run, {
        OLLAMA_URL: `http://127.0.0.1:${server.address().port}`,
        PZ_TEST_CLOCK_FILE: run.clockFile,
      }, ['--require', clockFixture]);
      const boot = await waitFor(() => processRun.output().match(/pz-bridge up on http:\/\/([^\s/]+)\/mind/),
        () => `Bridge did not start: ${processRun.output()}`, 5000);
      const response = await waitFor(() => heldResponse,
        () => `No synthetic model request: ${processRun.output()}`);
      invalidate(run, file, percept);
      response.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
      response.end(JSON.stringify({ message: { content: JSON.stringify({
        action: { type: 'MOVE', dx: 25, dy: 10 },
        goal: 'must not be saved', memory: 'must not be saved', thought: 'unsafe reply',
      }) } }));
      await waitFor(() => /discard:/.test(processRun.output()) || fs.existsSync(run.stateFile),
        () => `No reply outcome: ${processRun.output()}`, 3000);
      assert.equal(fs.readFileSync(intentFile, 'utf8'), 'previous-intent\n');
      assert.equal(fs.existsSync(run.stateFile), false);
      const state = await (await fetch(`http://${boot[1]}/api/state`)).json();
      assert.equal(state.seq, 0);
      assert.equal(state.goal, '');
      assert.equal(state.memory, '(fresh mind — nothing yet)');
      assert.match(state.brainNote, /^discarded model reply:/);
      assert.equal(modelCalls, retry ? 2 : 1);
    })));
  });

test('dashboard guidance survives a discarded reply and is answered once on the next accepted decision',
  { timeout: 22000 }, async t => {
    const run = temporaryRun(t);
    const requests = [];
    const responses = [];
    const modelServer = http.createServer(async (req, res) => {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      requests.push(JSON.parse(Buffer.concat(chunks).toString()));
      responses.push(res);
    });
    run.modelServer = modelServer;
    modelServer.listen(0, '127.0.0.1');
    await once(modelServer, 'listening');
    const file = path.join(run.luaDir, 'claude_percept.json');
    const percept = { dead: false, hp: 100, zClose: 0, zNear: 0, qlen: 0 };
    fs.writeFileSync(file, JSON.stringify(percept));
    const processRun = startBridge(run, { OLLAMA_URL: `http://127.0.0.1:${modelServer.address().port}` });
    const boot = await waitFor(() => processRun.output().match(/pz-bridge up on http:\/\/([^\s/]+)\/mind/),
      () => `Bridge did not start: ${processRun.output()}`, 3000);
    const url = `http://${boot[1]}`;
    const guidance = 'synthetic guidance: stay beside the kitchen door';
    await fetch(`${url}/god?text=${encodeURIComponent(guidance)}`);
    const first = await waitFor(() => responses[0], () => `No first decision: ${processRun.output()}`);
    assert.ok(JSON.stringify(requests[0]).includes(guidance));
    fs.writeFileSync(file, '{');
    const reply = res => {
      res.writeHead(200, { 'content-type': 'application/json', connection: 'close' });
      res.end(JSON.stringify({ message: { content: JSON.stringify({
        action: { type: 'WAIT' }, reply: 'synthetic acknowledgement', memory: 'accepted guidance',
      }) } }));
    };
    reply(first);
    await waitFor(() => /discard:/.test(processRun.output()), () => `Reply was not discarded: ${processRun.output()}`, 3000);
    fs.writeFileSync(file, JSON.stringify(percept));
    const next = await waitFor(() => responses[1], () => `No second decision: ${processRun.output()}`, 6000);
    assert.ok(JSON.stringify(requests[1]).includes(guidance));
    reply(next);
    await waitFor(() => fs.existsSync(path.join(run.luaDir, 'claude_intent.txt')),
      () => `No accepted intent: ${processRun.output()}`, 3000);
    const state = await (await fetch(`${url}/api/state`)).json();
    assert.equal(state.seq, 1);
    assert.equal(state.memory, 'accepted guidance');
    assert.equal(state.chat.filter(entry => entry.from === 'god' && entry.text === guidance).length, 1);
    assert.equal(state.chat.filter(entry => entry.from === 'claude' && entry.text === 'synthetic acknowledgement').length, 1);
  });
