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

function startBridge(run, overrides) {
  // Deliberately do not inherit the developer's credentials, provider configuration,
  // HOME, or CLI setup. Every file path and the only model endpoint are test-owned.
  const child = spawn(process.execPath, [bridgeFile], {
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
  const fakeOllama = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    requests.push({ url: req.url, method: req.method, body: JSON.parse(Buffer.concat(chunks).toString()) });
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

  const percept = { fixture: 'isolated-runtime', dead: false, day: 1, hour: 9, hp: 100, zClose: 0, zNear: 0, qlen: 0 };
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
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(run.luaDir, 'claude_percept.json'), 'utf8')), percept);
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
