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

function createLink(t, action) {
  try {
    action();
    return true;
  } catch (error) {
    if (['EPERM', 'EACCES', 'ENOTSUP', 'ENOSYS'].includes(error.code)) {
      t.skip(`Filesystem links are unavailable: ${error.code}`);
      return false;
    }
    throw error;
  }
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
    controlFile: path.join(options.homeDir, 'Zomboid', 'Lua', 'claude_control.txt'),
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
  for (const name of ['claude_percept.json', 'claude_intent.txt', 'claude_intent.txt.tmp', 'claude_control.txt', 'claude_control.txt.tmp']) {
    assert.throws(() => loadBridgeConfig({
      PZ_LUA_DIR: options.cwd,
      PZ_STATE_FILE: path.join(options.cwd, name),
    }, options), /PZ_STATE_FILE must be separate/);
  }
});

test('state cannot share an IPC path through an aliased directory before the file exists', t => {
  const { root, options } = fixture(t);
  const alias = path.join(root, 'linked-lua');
  if (!createLink(t, () => fs.symlinkSync(options.cwd, alias, 'dir'))) return;
  for (const name of ['claude_percept.json', 'claude_intent.txt', 'claude_intent.txt.tmp', 'claude_control.txt', 'claude_control.txt.tmp']) {
    const target = path.join(options.cwd, name);
    assert.throws(() => loadBridgeConfig({ PZ_LUA_DIR: alias, PZ_STATE_FILE: target }, options),
      /PZ_STATE_FILE must be separate/);
    assert.equal(fs.existsSync(target), false);
  }
});

test('state cannot alias an existing IPC file through a file symlink', t => {
  const { root, options } = fixture(t);
  for (const name of ['claude_percept.json', 'claude_intent.txt', 'claude_intent.txt.tmp', 'claude_control.txt', 'claude_control.txt.tmp']) {
    const target = path.join(options.cwd, name);
    const alias = path.join(root, `${name}.memory-link`);
    fs.writeFileSync(target, 'synthetic IPC data');
    if (!createLink(t, () => fs.symlinkSync(target, alias, 'file'))) return;
    assert.throws(() => loadBridgeConfig({ PZ_LUA_DIR: options.cwd, PZ_STATE_FILE: alias }, options),
      /PZ_STATE_FILE must be separate/);
    assert.equal(fs.readFileSync(target, 'utf8'), 'synthetic IPC data');
  }
});

test('state cannot alias an existing IPC file through a hardlink', t => {
  const { root, options } = fixture(t);
  for (const name of ['claude_percept.json', 'claude_intent.txt', 'claude_intent.txt.tmp', 'claude_control.txt', 'claude_control.txt.tmp']) {
    const target = path.join(options.cwd, name);
    const alias = path.join(root, `${name}.memory-link`);
    fs.writeFileSync(target, 'synthetic IPC data');
    if (!createLink(t, () => fs.linkSync(target, alias))) return;
    assert.throws(() => loadBridgeConfig({ PZ_LUA_DIR: options.cwd, PZ_STATE_FILE: alias }, options),
      /PZ_STATE_FILE must be separate/);
    assert.equal(fs.readFileSync(target, 'utf8'), 'synthetic IPC data');
  }
});

test('dangling state symlinks are rejected without creating their targets', t => {
  const { root, options } = fixture(t);
  const target = path.join(options.cwd, 'claude_percept.json');
  const alias = path.join(root, 'dangling-memory');
  if (!createLink(t, () => fs.symlinkSync(target, alias, 'file'))) return;
  assert.throws(() => loadBridgeConfig({ PZ_LUA_DIR: options.cwd, PZ_STATE_FILE: alias }, options),
    /dangling symlink/);
  assert.equal(fs.existsSync(target), false);
});

test('IPC names are reserved without regard to case within the same resolved directory', t => {
  const { options } = fixture(t);
  for (const name of ['CLAUDE_PERCEPT.JSON', 'CLAUDE_INTENT.TXT', 'CLAUDE_INTENT.TXT.TMP', 'CLAUDE_CONTROL.TXT', 'CLAUDE_CONTROL.TXT.TMP']) {
    assert.throws(() => loadBridgeConfig({
      PZ_LUA_DIR: options.cwd, PZ_STATE_FILE: path.join(options.cwd, name),
    }, options), /PZ_STATE_FILE must be separate/);
  }
});

test('a directory symlink is valid when state is separate from all IPC files', t => {
  const { root, options } = fixture(t);
  const alias = path.join(root, 'linked-lua');
  if (!createLink(t, () => fs.symlinkSync(options.cwd, alias, 'dir'))) return;
  const stateFile = path.join(root, 'separate-memory.json');
  const config = loadBridgeConfig({ PZ_LUA_DIR: alias, PZ_STATE_FILE: stateFile }, options);
  assert.equal(config.luaDir, alias);
  assert.equal(config.stateFile, stateFile);
  assert.equal(fs.existsSync(stateFile), false);
});
