// llm.mjs — pluggable LLM backend for the Claude Survives bridge.
//
// Works with anything. Pick a backend explicitly with PZ_BACKEND, or let it auto-detect from
// whichever key/config you've set. Model is PZ_MODEL (sensible per-backend default otherwise).
//
//   Ollama (local by default)   PZ_BACKEND=ollama   PZ_MODEL=llama3.1        [OLLAMA_URL=http://localhost:11434]
//   Anthropic (Claude)     ANTHROPIC_API_KEY=… PZ_MODEL=claude-haiku-4-5
//   OpenAI (GPT)           OPENAI_API_KEY=…     PZ_MODEL=gpt-4o-mini
//   OpenAI-compatible      OPENAI_API_KEY=…     OPENAI_BASE_URL=https://openrouter.ai/api/v1   (OpenRouter, Groq, Together, LM Studio…)
//   Google Gemini          GEMINI_API_KEY=…     PZ_MODEL=gemini-1.5-flash
//   Claude CLI (default)   CLAUDE_BIN=…         PZ_MODEL=haiku          (uses your Claude subscription)
//
// callLLM returns raw reply text for compatibility. callLLMResult also returns
// allowlisted provider metadata; it never attests billing or the upstream model.

import { spawn } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const env = process.env;
const TIMEOUT = Number(env.PZ_TIMEOUT || 45000);

function pickBackend() {
  if (env.PZ_BACKEND) return env.PZ_BACKEND.toLowerCase();
  if (env.OLLAMA_URL || env.OLLAMA_MODEL) return 'ollama';
  if (env.ANTHROPIC_API_KEY) return 'anthropic';
  if (env.OPENAI_API_KEY) return 'openai';
  if (env.GEMINI_API_KEY || env.GOOGLE_API_KEY) return 'gemini';
  return 'claude-cli';
}

const DEFAULT_MODEL = {
  ollama: 'llama3.1',
  anthropic: 'claude-haiku-4-5',
  openai: 'gpt-4o-mini',
  'openai-compat': 'gpt-4o-mini',
  gemini: 'gemini-1.5-flash',
  'claude-cli': 'haiku',
};

// Unknown backend names historically dispatch through the CLI. Report that actual
// dispatch rather than making a configured typo look like an HTTP provider.
const selectedBackend = pickBackend();
export const BACKEND = Object.hasOwn(DEFAULT_MODEL, selectedBackend) ? selectedBackend : 'claude-cli';
const requestedModel = env.PZ_MODEL || env.OLLAMA_MODEL || DEFAULT_MODEL[BACKEND];

function containsCredential(value, foldCase = false) {
  const known = [env.OPENAI_API_KEY, env.ANTHROPIC_API_KEY, env.GEMINI_API_KEY, env.GOOGLE_API_KEY]
    .filter(secret => typeof secret === 'string' && secret.length > 0);
  const comparable = foldCase ? value.toLowerCase() : value;
  return known.some(secret => [secret, encodeURIComponent(secret)].some(candidate =>
    comparable.includes(foldCase ? candidate.toLowerCase() : candidate)))
    || /(?:^|[/:._-])(?:sk-|gh[pousr]_|github_pat_|AIza)[A-Za-z0-9_-]*/i.test(value)
    || /^(?:Bearer|Basic)[.:_-]/i.test(value);
}

function publicIdentifier(value) {
  return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,179}$/.test(value)
    && !value.includes('://') && !containsCredential(value) ? value : null;
}

// These exports are safe display values. Requests use the original model setting.
export const MODEL = publicIdentifier(requestedModel);

function endpointBase() {
  switch (BACKEND) {
    case 'openai':
    case 'openai-compat': return env.OPENAI_BASE_URL || 'https://api.openai.com/v1';
    case 'anthropic': return env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com';
    case 'ollama': return env.OLLAMA_URL || 'http://localhost:11434';
    case 'gemini': return 'https://generativelanguage.googleapis.com';
    default: return null;
  }
}

export function publicModelConfig() {
  let endpointOrigin = null;
  try {
    const url = new URL(endpointBase());
    if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password
        && !containsCredential(url.origin, true)) endpointOrigin = url.origin;
  } catch { /* Invalid, CLI and credential-bearing origins remain unavailable. */ }
  const authMode = BACKEND === 'claude-cli' ? 'cli_subscription_or_login'
    : BACKEND === 'ollama' ? 'none'
      : ['openai', 'openai-compat'].includes(BACKEND) && env.PZ_API_KEYLESS === '1'
        ? 'keyless_loopback' : 'api_key';
  return { backend: BACKEND, requestedModel: MODEL, endpointOrigin, authMode };
}

const unknownUsage = () => ({ inputTokens: null, outputTokens: null, totalTokens: null });
const tokenCount = value => Number.isSafeInteger(value) && value >= 0 ? value : null;
const safeText = value => {
  if (value === undefined || value === null) return '';
  if (typeof value !== 'string') throw failure('invalid_response', 'Model provider returned an unsupported response');
  return value;
};
function failure(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function responseMetadata(j, metadata) {
  metadata.returnedModel = publicIdentifier(BACKEND === 'gemini' ? j.modelVersion : j.model);
  metadata.responseId = publicIdentifier(BACKEND === 'gemini' ? j.responseId : j.id);
  let input, output, total;
  // Keep provider-reported categories, not derived totals. Cache and reasoning
  // accounting differ across providers; these fields do not establish a charge.
  switch (BACKEND) {
    case 'openai':
    case 'openai-compat':
      input = j.usage?.prompt_tokens; output = j.usage?.completion_tokens; total = j.usage?.total_tokens; break;
    case 'anthropic': input = j.usage?.input_tokens; output = j.usage?.output_tokens; break;
    case 'ollama': input = j.prompt_eval_count; output = j.eval_count; break;
    case 'gemini':
      input = j.usageMetadata?.promptTokenCount; output = j.usageMetadata?.candidatesTokenCount;
      total = j.usageMetadata?.totalTokenCount; break;
  }
  metadata.usage = { inputTokens: tokenCount(input), outputTokens: tokenCount(output), totalTokens: tokenCount(total) };
}

async function fetchJSON(url, opts, label, metadata) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), TIMEOUT);
  try {
    let r;
    try { r = await fetch(url, { ...opts, signal: ctl.signal, redirect: 'error' }); }
    catch { throw failure(ctl.signal.aborted ? 'timeout' : 'network_error',
      ctl.signal.aborted ? 'Model provider timed out' : 'Model provider request failed'); }
    metadata.httpStatus = Number.isInteger(r.status) && r.status >= 100 && r.status <= 599 ? r.status : null;
    metadata.requestId = publicIdentifier(r.headers.get('x-request-id')) || publicIdentifier(r.headers.get('request-id'));
    // Never read/echo an error body. It may contain account data or prompt text.
    if (!r.ok) {
      try { await r.body?.cancel(); } catch {}
      throw failure('http_error', `${label} HTTP ${r.status}`);
    }
    let j;
    try { j = await r.json(); }
    catch { throw failure(ctl.signal.aborted ? 'timeout' : 'invalid_response',
      ctl.signal.aborted ? 'Model provider timed out' : 'Model provider returned invalid JSON'); }
    if (!j || typeof j !== 'object' || Array.isArray(j)) {
      throw failure('invalid_response', 'Model provider returned an unsupported response');
    }
    responseMetadata(j, metadata);
    return j;
  } finally { clearTimeout(t); }
}

async function callAnthropic(prompt, metadata) {
  const j = await fetchJSON(endpointBase() + '/v1/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': env.ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: requestedModel, max_tokens: 500, messages: [{ role: 'user', content: prompt }] }),
  }, 'anthropic', metadata);
  if (j.content !== undefined && !Array.isArray(j.content)) throw failure('invalid_response', 'Model provider returned an unsupported response');
  return (j.content || []).map(c => safeText(c?.text)).join('');
}

async function callOpenAI(prompt, metadata) {
  const base = endpointBase();
  let url;
  try { url = new URL(base); }
  catch { throw failure('configuration_error', 'OpenAI-compatible base URL is invalid'); }
  const keyless = env.PZ_API_KEYLESS === '1';
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw failure('configuration_error', 'OpenAI-compatible base URL must not contain credentials, query, or fragment');
  }
  if (keyless && !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) {
    throw failure('configuration_error', 'Keyless model access is restricted to loopback');
  }
  if (url.protocol === 'http:' && !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) {
    throw failure('configuration_error', 'Remote model endpoints require HTTPS');
  }
  if (!keyless && !env.OPENAI_API_KEY?.trim()) throw failure('configuration_error', 'OPENAI_API_KEY is not configured');
  const body = { model: requestedModel, max_completion_tokens: 500, messages: [{ role: 'user', content: prompt }] };
  if (env.PZ_REASONING_EFFORT) {
    if (!['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].includes(env.PZ_REASONING_EFFORT)) {
      throw failure('configuration_error', 'Invalid PZ_REASONING_EFFORT');
    }
    body.reasoning_effort = env.PZ_REASONING_EFFORT;
  }
  const j = await fetchJSON(base.replace(/\/$/, '') + '/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(keyless ? {} : { authorization: 'Bearer ' + env.OPENAI_API_KEY }) },
    body: JSON.stringify(body),
  }, 'openai', metadata);
  return safeText(j.choices?.[0]?.message?.content);
}

async function callOllama(prompt, metadata) {
  const j = await fetchJSON(endpointBase() + '/api/chat', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model: requestedModel, stream: false, messages: [{ role: 'user', content: prompt }] }),
  }, 'ollama', metadata);
  return safeText(j.message?.content);
}

async function callGemini(prompt, metadata) {
  const key = env.GEMINI_API_KEY || env.GOOGLE_API_KEY;
  const j = await fetchJSON(`https://generativelanguage.googleapis.com/v1beta/models/${requestedModel}:generateContent?key=${key}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }] }),
  }, 'gemini', metadata);
  const parts = j.candidates?.[0]?.content?.parts;
  if (parts !== undefined && !Array.isArray(parts)) throw failure('invalid_response', 'Model provider returned an unsupported response');
  return (parts || []).map(p => safeText(p?.text)).join('');
}

function callClaudeCLI(prompt) {
  return new Promise((resolve, reject) => {
    const bin = env.CLAUDE_BIN || 'claude';
    const hasPath = !!env.CLAUDE_BIN;
    let ps, timer;
    let settled = false;
    function done(error, text) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error); else resolve(text);
    }
    try {
      if (hasPath) {
        // Keep the existing no-shell path form for Windows-compatible invocation.
        ps = spawn(bin, ['-p', prompt, '--model', requestedModel], { stdio: ['ignore', 'pipe', 'pipe'], shell: false, windowsHide: true });
      } else {
        ps = spawn(bin, ['-p', '--model', requestedModel], { stdio: ['pipe', 'pipe', 'pipe'], shell: true, windowsHide: true });
      }
    } catch { done(failure('cli_error', 'claude-cli failed to start')); return; }
    let out = '';
    ps.stdout.on('data', d => out += d);
    ps.stderr.resume(); // Drain without collecting or surfacing credentials/prompt text.
    timer = setTimeout(() => { try { ps.kill(); } catch {} done(failure('timeout', 'claude-cli timed out')); }, TIMEOUT);
    ps.on('error', () => done(failure('cli_error', 'claude-cli failed to start')));
    ps.on('close', c => c === 0 && out.trim() ? done(null, out.trim()) : done(failure('cli_error', 'claude-cli failed')));
    if (!hasPath) {
      ps.stdin.on('error', () => done(failure('cli_error', 'claude-cli input failed')));
      ps.stdin.write(prompt); ps.stdin.end();
    }
  });
}

/** Response metadata is provider-reported, optional, bounded and not billing evidence. */
export async function callLLMResult(prompt) {
  const started = performance.now();
  const metadata = { backend: BACKEND, requestedModel: MODEL, returnedModel: null,
    requestId: null, responseId: null, latencyMs: null, httpStatus: null, usage: unknownUsage() };
  try {
    let text;
    switch (BACKEND) {
      case 'anthropic': text = await callAnthropic(prompt, metadata); break;
      case 'openai':
      case 'openai-compat': text = await callOpenAI(prompt, metadata); break;
      case 'ollama': text = await callOllama(prompt, metadata); break;
      case 'gemini': text = await callGemini(prompt, metadata); break;
      default: text = await callClaudeCLI(prompt);
    }
    metadata.latencyMs = Math.max(0, Math.round(performance.now() - started));
    return { text, metadata };
  } catch (cause) {
    // Only failures created here carry stable messages. Arbitrary library errors
    // can include endpoint URLs, provider bodies or command arguments.
    const codes = ['http_error', 'timeout', 'network_error', 'invalid_response', 'configuration_error', 'cli_error'];
    const error = codes.includes(cause?.code) ? cause : failure('invalid_response', 'Model provider returned an unsupported response');
    metadata.latencyMs = Math.max(0, Math.round(performance.now() - started));
    // Valid provider usage may precede unsupported text extraction. Preserve it
    // on the attempt even though no usable adapter response can be returned.
    error.metadata = metadata;
    throw error;
  }
}

export async function callLLM(prompt) {
  return (await callLLMResult(prompt)).text;
}
