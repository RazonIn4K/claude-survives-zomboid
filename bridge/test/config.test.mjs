import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { loadBridgeConfig } from '../config.mjs';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pz-config-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const options = {
    homeDir: path.join(root, 'home'),
    bridgeDir: path.join(root, 'bridge'),
    cwd: path.join(root, 'launch'),
  };
  for (const dir of Object.values(options)) fs.mkdirSync(dir);
  return { root, options };
}

test('defaults preserve the original paths without creating a game directory', t => {
  const { options } = fixture(t);
  const config = loadBridgeConfig({}, options);
  assert.deepEqual(config, {
    host: '127.0.0.1',
    port: 8799,
    luaDir: path.join(options.homeDir, 'Zomboid', 'Lua'),
    perceptFile: path.join(options.homeDir, 'Zomboid', 'Lua', 'claude_percept.json'),
    intentFile: path.join(options.homeDir, 'Zomboid', 'Lua', 'claude_intent.txt'),
    stateFile: path.join(options.bridgeDir, 'pz-state.json'),
  });
  assert.equal(fs.existsSync(config.luaDir), false);
  assert.equal(fs.existsSync(config.stateFile), false);
});

test('overrides isolate both IPC files and resolve relative paths from the launch directory', t => {
  const { options } = fixture(t);
  const luaDir = path.join(options.cwd, 'custom Lua');
  fs.mkdirSync(luaDir);
  const config = loadBridgeConfig({
    PZ_LUA_DIR: 'custom Lua',
    PZ_STATE_FILE: 'custom-state.json',
    PZ_PORT: '8801',
  }, options);
  assert.equal(config.luaDir, luaDir);
  assert.equal(config.perceptFile, path.join(luaDir, 'claude_percept.json'));
  assert.equal(config.intentFile, path.join(luaDir, 'claude_intent.txt'));
  assert.equal(config.stateFile, path.join(options.cwd, 'custom-state.json'));
  assert.equal(config.port, 8801);
  assert.equal(config.host, '127.0.0.1');
});

test('ports accept the ephemeral value and upper boundary', t => {
  const { options } = fixture(t);
  assert.equal(loadBridgeConfig({ PZ_PORT: '0' }, options).port, 0);
  assert.equal(loadBridgeConfig({ PZ_PORT: '65535' }, options).port, 65535);
});

test('ports reject blank, fractional, signed, nondecimal and out-of-range values', t => {
  const { options } = fixture(t);
  for (const value of ['', ' ', '-1', '+1', '1.5', '1e3', '0x10', '65536', 'Infinity', 'NaN', '8799\n', 8799]) {
    assert.throws(() => loadBridgeConfig({ PZ_PORT: value }, options), /PZ_PORT must be an integer/, String(value));
  }
});

test('explicit path overrides reject blanks and NUL characters', t => {
  const { options } = fixture(t);
  for (const name of ['PZ_LUA_DIR', 'PZ_STATE_FILE']) {
    for (const value of ['', '   ', 'bad\0path']) {
      assert.throws(() => loadBridgeConfig({ [name]: value }, options), new RegExp(`${name} must be a non-empty`));
    }
  }
});

test('an explicit Lua directory must exist and be a directory', t => {
  const { root, options } = fixture(t);
  assert.throws(() => loadBridgeConfig({ PZ_LUA_DIR: path.join(root, 'missing') }, options), /PZ_LUA_DIR.*ENOENT/);
  const file = path.join(root, 'not-a-directory');
  fs.writeFileSync(file, 'fixture');
  assert.throws(() => loadBridgeConfig({ PZ_LUA_DIR: file }, options), /PZ_LUA_DIR must be a directory/);
});

test('state requires an existing parent directory and cannot itself be a directory', t => {
  const { root, options } = fixture(t);
  assert.throws(() => loadBridgeConfig({ PZ_STATE_FILE: path.join(root, 'missing', 'state.json') }, options), /PZ_STATE_FILE parent directory.*ENOENT/);
  assert.throws(() => loadBridgeConfig({ PZ_STATE_FILE: options.cwd }, options), /PZ_STATE_FILE must be a file/);
});

test('state cannot overwrite percept, intent or the atomic intent temporary file', t => {
  const { options } = fixture(t);
  for (const name of ['claude_percept.json', 'claude_intent.txt', 'claude_intent.txt.tmp']) {
    assert.throws(() => loadBridgeConfig({
      PZ_LUA_DIR: options.cwd,
      PZ_STATE_FILE: path.join(options.cwd, name),
    }, options), /PZ_STATE_FILE must be separate/);
  }
});
