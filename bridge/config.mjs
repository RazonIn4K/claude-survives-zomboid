import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function configuredPath(env, name, fallback, cwd) {
  if (env[name] === undefined) return fallback;
  const value = env[name];
  if (typeof value !== 'string' || !value.trim() || value.includes('\0')) {
    throw new Error(`${name} must be a non-empty filesystem path without NUL characters.`);
  }
  return path.resolve(cwd, value);
}

function checkPath(name, value, kind, allowMissing = false) {
  let stat;
  try {
    stat = fs.statSync(value);
  } catch (error) {
    if (allowMissing && error.code === 'ENOENT') return;
    throw new Error(`${name} cannot be accessed at ${value}: ${error.code}.`);
  }
  if (!(kind === 'directory' ? stat.isDirectory() : stat.isFile())) {
    throw new Error(`${name} must be a ${kind}: ${value}.`);
  }
}

/** Resolve and validate configuration without creating any game or state directories. */
export function loadBridgeConfig(env = process.env, {
  homeDir = os.homedir(),
  bridgeDir = fileURLToPath(new URL('.', import.meta.url)),
  cwd = process.cwd(),
} = {}) {
  const rawPort = env.PZ_PORT ?? '8799';
  if (typeof rawPort !== 'string' || rawPort.trim() !== rawPort
    || !/^\d+$/.test(rawPort) || Number(rawPort) > 65535) {
    throw new Error('PZ_PORT must be an integer from 0 to 65535 (0 selects an available port).');
  }
  const luaDir = configuredPath(env, 'PZ_LUA_DIR', path.join(homeDir, 'Zomboid', 'Lua'), cwd);
  const perceptFile = path.join(luaDir, 'claude_percept.json');
  const intentFile = path.join(luaDir, 'claude_intent.txt');
  const stateFile = configuredPath(env, 'PZ_STATE_FILE', path.join(bridgeDir, 'pz-state.json'), cwd);

  // The default Lua directory may be absent before the game's first launch. An explicit
  // override must already exist so a typo cannot silently redirect the game connection.
  checkPath('PZ_LUA_DIR', luaDir, 'directory', env.PZ_LUA_DIR === undefined);
  checkPath('PZ_STATE_FILE parent directory', path.dirname(stateFile), 'directory');
  checkPath('PZ_STATE_FILE', stateFile, 'file', true);
  if ([perceptFile, intentFile, `${intentFile}.tmp`].includes(stateFile)) {
    throw new Error('PZ_STATE_FILE must be separate from the percept and intent files.');
  }

  return Object.freeze({
    host: '127.0.0.1',
    port: Number(rawPort),
    luaDir,
    perceptFile,
    intentFile,
    stateFile,
  });
}
