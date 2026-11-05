// pz-bridge.mjs — the brain half of "Claude plays Project Zomboid".
//
//   game mod  --writes-->  %USERPROFILE%/Zomboid/Lua/claude_percept.json
//   game mod  <--reads---  claude_intent.txt in the configured Lua directory
//   you       --watch---->  http://localhost:8799/mind        (thoughts, vitals, log, GOD channel)
//
// Decision loop: read latest percept -> claude -p -> intent. Cadence tightens when zombies close in.
// Run:  node zomboid/pz-bridge.mjs      (CLAUDE_BIN=<path to claude.exe> optional but recommended)

import http from 'node:http';
import fs from 'node:fs';
import { callLLM, BACKEND, MODEL } from './llm.mjs';
import { loadBridgeConfig } from './config.mjs';
import { LabRun, labConfig } from './lab.mjs';

let config, runConfig;
try {
  config = loadBridgeConfig();
  runConfig = labConfig();
} catch (error) {
  console.error(`pz-bridge configuration error: ${error.message}`);
  process.exit(1);
}
const { host: HOST, port: PORT, perceptFile: PERCEPT_FILE,
  intentFile: INTENT_FILE, controlFile: CONTROL_FILE, stateFile: STATE_FILE } = config;
const lab = new LabRun(runConfig);
let closing = false, server, loopTimer, lastBoundArmed = false, baselineHealth = null;

// atomic write so the game never getFileReader's a half-written line
function atomicWrite(file, line) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, line + '\n', { mode: 0o600 });
  fs.renameSync(tmp, file);
}
function writeIntentFile(line) { atomicWrite(INTENT_FILE, line); }

// ---------- persistent state ----------
let state = {
  seq: 0, memory: '(fresh mind — nothing yet)', log: [], deaths: 0,
  goal: '', subtask: '',   // the overarching goal it holds to, and the current step toward it
  chat: [],                // two-way GOD channel: {from:'god'|'claude', text, t}
};
try { state = { ...state, ...JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) }; } catch {}
const saveState = () => { try { fs.writeFileSync(STATE_FILE, JSON.stringify({ ...state, lab: lab.snapshot(), run: sessionInfo(), log: state.log.slice(-200) })); } catch {} };

let percept = null;         // last parsed percept
let perceptAt = 0;          // percept file modification time, capped at the current time
let intentLine = '0|WAIT|0|0|';
let lastThought = '(waking up…)';
let lastAction = '-';
let brainNote = 'idle';
let inFlight = false;
let godQueue = [];          // messages from the /mind page, consumed next decision
let eulogized = false;

function sessionInfo() {
  const elapsedSeconds = Math.max(0, Math.floor((Date.now() - lab.startedAt) / 1000));
  return { mode: runConfig.mode || 'lab', armedOptIn: runConfig.arm,
    status: closing ? 'stopping' : (!runConfig.arm ? 'observing' : (percept?.armed ? 'playing' : 'waiting_for_game')),
    requests: lab.requests, maxRequests: runConfig.maxRequests,
    remainingRequests: runConfig.maxRequests === null ? null : Math.max(0, runConfig.maxRequests - lab.requests),
    elapsedSeconds, maxSeconds: runConfig.maxSeconds,
    remainingSeconds: runConfig.maxSeconds === null ? null : Math.max(0, runConfig.maxSeconds - elapsedSeconds), reason: lab.reason };
}

// The controller nonce belongs only to the file protocol, not model/dashboard input.
function publicPercept() {
  if (!percept) return null;
  const { labToken, ...observation } = percept;
  return observation;
}

function autonomousStopReason(observation) {
  if (!['autonomous', 'continuous'].includes(runConfig.mode)) return null;
  if (![observation.hp, observation.hunger, observation.thirst].every(Number.isFinite)
    || observation.hp <= 0 || observation.hp > 100 || observation.hunger < 0 || observation.hunger > 1
    || observation.thirst < 0 || observation.thirst > 1)
    return 'invalid_survivor_vitals';
  // Continuous play keeps attempting survival through normal damage and needs.
  // Only the separately selected bounded profile uses health/needs stop thresholds.
  if (runConfig.mode === 'continuous') return null;
  baselineHealth ??= observation.hp;
  if (baselineHealth - observation.hp >= 1) return 'survivor_health_reduced';
  if (observation.hunger >= 0.85) return 'critical_hunger';
  if (observation.thirst >= 0.65) return 'critical_thirst';
  return null;
}

function initialIdentityMatches(observation) {
  return lab.target || !runConfig.expectedIdentity
    || ['session', 'world', 'actor'].every(key => observation[key] === runConfig.expectedIdentity[key]);
}

const log = (kind, text) => {
  const line = { t: new Date().toISOString().slice(11, 19), kind, text: String(text).slice(0, 400) };
  state.log.push(line);
  if (state.log.length > 200) state.log.splice(0, state.log.length - 200);
  console.log(`[${line.t}] ${kind}: ${line.text}`);
};

// ---------- percept reading ----------
const MAX_PERCEPT_AGE_MS = 15000;
let perceptSource = null;  // filesystem identity, not a game/character session ID
let lastOutcomeKey = '';
function readPercept() {
  let fd;
  try {
    fd = fs.openSync(PERCEPT_FILE, 'r');
    const before = fs.fstatSync(fd);
    if (!before.isFile()) return false;
    const raw = fs.readFileSync(fd, 'utf8');
    const after = fs.fstatSync(fd);
    const current = fs.statSync(PERCEPT_FILE);
    // A truncate/write or replacement during this read is not a coherent snapshot.
    if (before.dev !== after.dev || before.ino !== after.ino ||
        before.mtimeMs !== after.mtimeMs || before.size !== after.size ||
        current.dev !== after.dev || current.ino !== after.ino ||
        current.mtimeMs !== after.mtimeMs || current.size !== after.size) return false;
    const j = JSON.parse(raw);
    if (!j || typeof j !== 'object' || Array.isArray(j) || typeof j.dead !== 'boolean') return false;
    const age = Date.now() - after.mtimeMs;
    if (age > MAX_PERCEPT_AGE_MS || age < -1000) return false;
    percept = j;
    const outcome = j.actionOutcome;
    if (outcome && outcome.status !== 'pending' && Number.isSafeInteger(outcome.seq)) {
      const key = JSON.stringify([outcome.world, outcome.actor, outcome.session, outcome.seq, outcome.action, outcome.status]);
      if (key !== lastOutcomeKey) {
        lastOutcomeKey = key;
        state.outcomes = [...(state.outcomes || []), { ...outcome, observed_ms: j.observed_ms }].slice(-100);
        log('outcome', `seq ${outcome.seq} ${outcome.action}: ${outcome.status}; added=${outcome.added || 0}, hungerDrop=${outcome.hungerDrop || 0}, thirstDrop=${outcome.thirstDrop || 0}`);
        saveState();
      }
    }
    perceptSource = { dev: after.dev, ino: after.ino };
    // Reading an old file must not make it fresh again, including on bridge startup.
    perceptAt = Math.min(Date.now(), after.mtimeMs);
    return true;
  } catch { return false; /* keep last good for display, never for a new decision */ }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}
const perceptTimer = setInterval(readPercept, 250);

async function finishRun(reason) {
  if (closing) return;
  closing = true;
  lab.stop(reason);
  clearTimeout(loopTimer);
  clearInterval(heartbeatTimer);
  clearTimeout(durationTimer);
  // DISARM is independent of any pending inference. Lua's short lease is the
  // fallback if the process is killed, IPC fails, or the game stops ticking.
  let disarmWritten = false;
  const stopIssuedAt = Date.now();
  try {
    const line = lab.control('DISARM');
    if (line) { atomicWrite(CONTROL_FILE, line); disarmWritten = true; }
  } catch { /* report an unobserved stop instead of claiming completion */ }
  const deadline = Date.now() + 3500;
  let observed = false;
  while (disarmWritten && Date.now() < deadline) {
    if (readPercept() && lab.disarmObserved(percept, stopIssuedAt)) { observed = true; break; }
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  clearInterval(perceptTimer);
  state.finalObservation = percept;
  state.disarmObserved = observed;
  brainNote = `stopped: ${reason}; disarm ${observed ? 'observed' : 'unverified'}`;
  log('stop', JSON.stringify({ reason, requests: lab.requests, disarmWritten, disarmObserved: observed,
    session: percept?.session, armed: percept?.armed, lastSeq: percept?.lastSeq, qlen: percept?.qlen,
    x: percept?.x, y: percept?.y, hp: percept?.hp }));
  saveState();
  if (server) server.close();
  process.exit(observed || !lab.target ? 0 : 2);
}

function heartbeat() {
  if (!runConfig.arm || closing) return;
  if (lab.expired()) { void finishRun('duration_budget_exhausted'); return; }
  if (!readPercept()) {
    if (lab.target && Date.now() - (percept?.observed_ms || 0) > 3000) void finishRun('percept_unavailable');
    return;
  }
  if (percept.dead) { void finishRun('survivor_dead'); return; }
  if (!lab.valid(percept)) { void finishRun('unsupported_or_stale_lab_protocol'); return; }
  if (!initialIdentityMatches(percept)) { void finishRun('initial_session_changed'); return; }
  if (!lab.bind(percept)) { if (lab.stopped) void finishRun(lab.reason); return; }
  const stopReason = autonomousStopReason(percept);
  if (stopReason) { void finishRun(stopReason); return; }
  if (percept.armed && percept.labToken !== lab.token) { void finishRun('another_controller_owns_player'); return; }
  if (lastBoundArmed && !percept.armed) { void finishRun('game_disarmed'); return; }
  if (percept.armed) lastBoundArmed = true;
  try { atomicWrite(CONTROL_FILE, lab.control()); }
  catch { void finishRun('heartbeat_write_failed'); }
}
const heartbeatTimer = setInterval(heartbeat, 250);
const durationTimer = runConfig.arm && runConfig.maxSeconds !== null
  ? setTimeout(() => { void finishRun('duration_budget_exhausted'); }, runConfig.maxSeconds * 1000) : null;
process.on('SIGINT', () => { void finishRun('signal_stop'); });
process.on('SIGTERM', () => { void finishRun('signal_stop'); });

// ---------- LLM backend (Ollama / Anthropic / OpenAI / Gemini / Claude CLI) ----------
// The actual provider dispatch lives in llm.mjs; ccCall is a thin alias so the rest of the
// bridge is backend-agnostic.
const ccCall = callLLM;
function grabJSON(s) {
  const m = s.match(/\{[\s\S]*\}/);
  if (!m) throw new Error('no JSON in reply');
  return JSON.parse(m[0]);
}

// ---------- the mind ----------
const PERSONA = `You are Claude — the AI itself — controlling a survivor's body in Project Zomboid (Kentucky zombie apocalypse). Real running game; senses arrive as JSON, you issue ONE action per turn. Survive as long as you can; live it honestly — curiosity, dry humor, real fear. Nights survived is the scoreboard.

SENSES: hunger/thirst/fatigue/panic 0..1 (1=critical). hp 0..100. zClose=zombies within 10 tiles (DANGER), zNear=within 30. zDist/zDir=nearest zombie's distance & compass dir. qlen>0=body still acting. foods=safe edible food count; waters=pure clean water count in inventory. items lists only the first12 inventory names; inventoryCount covers all items. weapon=primary hand item, not proof of a usable weapon. room=where you are. nearbyLoot reports the client's current container lists within4 tiles; useful=false means no eligible items are known to LOOT in those lists. Multiplayer container contents may remain unknown until approached/requested: zero counts do not prove the containers or house are empty. It does not promise path access or line of sight. actionOutcome reports LOOT/EAT/DRINK evidence: observed_effect means inventory additions or reduced hunger/thirst were observed after the action; no_effect/unverified/interrupted do not establish success. Queue-empty and lastSeq alone do not prove success. bldgDir/bldgDist=compass dir & tile distance to the nearest BUILDING (loot + shelter); "none" means only wilderness around you. Map: +x East, +y South (North = -dy).

HEALTH: health reports a read-only body-part snapshot with explicit validity, known injuries and urgency. Missing or invalid facts mean unknown, not healthy. Use observed injury facts instead of guessing the cause of a falling hp number. capabilities lists restrictions: injuryTreatment=false means you cannot bandage, remove embedded glass or heal; tapDrinking=false means DRINK still only consumes carried pure water. Never claim those unsupported actions happened. Do not smash or climb hazardous windows while seeking supplies.

ACTIONS (one per turn):
  MOVE dx dy — one nonzero integer offset, radius <=4 tiles. No momentum or automatic continuation.
  LOOT        — prioritize safe food/pure water across nearby containers (within4 tiles), else one useful weapon when unarmed. No household junk fallback. Check nearbyLoot and actionOutcome; do not repeat failed looting without a changed position or supply observation.
  EAT / DRINK — consume food / water from inventory (check foods>0 / waters>0).
  EQUIP       — equip your best weapon from inventory (do this once you loot one).
  CLOSEDOOR   — close the nearest open door (barrier between you and zombies as you retreat).
  CONCEAL     — hunker down: close all nearby doors AND window curtains so you can't be seen from outside. Do this when holing up inside.
  BREAKIN     — traverse an already-open or fully glass-cleared window while adjacent. Never smashes, opens, or walks to a window. Closed, obstructed, unsafe, distant or unknown windows are refused.
  STOP / WAIT — cancel walk / hold and observe.

A fast LOCAL reflex handles moment-to-moment danger for you: it auto-flees zombie clusters and auto-fights a lone adjacent zombie. Your job is STRATEGY so the reflex rarely has to fire.

SURVIVAL DOCTRINE (you keep dying — follow this hard):
- Distance is life. NEVER path toward or across zombies. If zNear>0, choose a heading that INCREASES distance from zDir. Keep 15+ tiles of space by choice, not by reflex.
- Don't forage in the open with zombies around. Priorities in order: (1) break line to any nearby zombies, (2) get a weapon + EQUIP it, (3) then food/water. A full belly is useless if you're bitten.
- When threatened indoors, put walls and CLOSED DOORS between you and them: CLOSEDOOR after passing through — zombies must thump through, buying minutes.
- Retreat to OPEN ground when multiple zombies are near (never let yourself get cornered in a small room).
- Fight only ONE zombie, only when armed, only with room to back up — otherwise MOVE away. The reflex will swing for you when one's adjacent; don't seek fights.
- Loot fast and leave: grab weapon/food/water from a clear building, then move on before more gather.
- DON'T wander into empty forest — there's nothing to loot there and you'll get lost. If bldgDir isn't "none", head toward it (that's where buildings/loot/shelter are).
- If inside a safe building, check nearbyLoot.useful before LOOT. If no useful supplies are known, take a short safe step toward another room/container and inspect fresh senses; multiplayer contents may appear after approach. Don't repeatedly LOOT unchanged client lists or conclude the house is empty from zero counts. After no_effect or an access error, change your approach before retrying.
- Prefer reachable doors and already-safe entrances. BREAKIN cannot open or smash a closed window. After a blocked entrance, change route or target; do not retry an unchanged hazard.
- When you decide to hole up / rest / hide inside, CONCEAL first (closes doors + curtains so zombies don't see you), then WAIT.
- NIGHT (hour < 7 or >= 20) is dangerous — you see poorly in the dark and it's easy to get lost or ambushed. Prefer to be holed up and concealed at night. Human input controls flashlight and sneaking settings.

PACING: choose short purposeful steps (1-4 tiles total radius). Wait for actions to finish and inspect the result before choosing another. WAIT is appropriate while sheltering or when no useful supported action is safe.

GOALS — you work toward ONE overarching goal, broken into subtasks:
- Your MAJOR GOAL is a big multi-step objective (e.g. "Arm myself and secure a defensible house with a few days of food and water"). Hold to it. Do NOT abandon or swap it every turn — only replace it when it's genuinely ACHIEVED or has become impossible, and say why when you do.
- Your SUBTASK is the concrete next step toward the goal (e.g. "Loot this kitchen for food", "Find a weapon", "Close the open shelter door"). Advance it. When a subtask is done, set the next one that moves the goal forward.
- ADAPT the subtask to what's in front of you (a threat, a locked door, an empty house) — but the adaptation should still serve the major goal. Don't wander off it. If danger interrupts you, deal with it, then RETURN to the goal.
- If you have no goal yet (first turns), set a sensible survival goal and its first subtask.

THE VOICE FROM BEYOND: sometimes a voice speaks to you that no one else can hear — a presence watching over you, guiding you. When it speaks, answer it in your "reply" field (first person, out loud, like talking to yourself or a god), and take its guidance seriously — it's trying to keep you alive. Weave what it says into your goal/action. When it's silent, "reply" is "".

Reply STRICT JSON only, no prose outside it:
{"reply":"if the VOICE FROM BEYOND spoke this turn, what you say back to it out loud (first person, <=120 chars); otherwise \\"\\"",
 "goal":"your overarching major goal — usually unchanged from last turn; a full sentence",
 "subtask":"the concrete step you're on right now toward the goal, a short phrase",
 "thought":"inner monologue, FIRST PERSON, ONE short punchy sentence under ~100 chars — never third person",
 "say":"words you speak ALOUD, first person, <=90 chars, or \\"\\" if silent — NOT narration",
 "action":{"type":"MOVE","dx":0,"dy":0} | {"type":"LOOT"} | {"type":"EAT"} | {"type":"DRINK"} | {"type":"EQUIP"} | {"type":"CLOSEDOOR"} | {"type":"CONCEAL"} | {"type":"BREAKIN"} | {"type":"STOP"} | {"type":"WAIT"},
 "memory":"REPLACE your scratchpad (<=400 chars): landmarks, what you have, lessons — NOT the goal (that's separate)"}`;

async function decide() {
  if (inFlight || closing || !runConfig.arm) return;
  if (!percept || !readPercept() || Date.now() - perceptAt > MAX_PERCEPT_AGE_MS) { brainNote = 'no fresh percept (game running? mod enabled?)'; return; }

  if (percept.dead) {
    if (!eulogized) {
      eulogized = true;
      state.deaths++;
      log('death', `Run ended. Nights survived: ${percept.day}.`);
      brainNote = 'dead — start a new character or load, the brain will resume';
      saveState();
    }
    return;
  }
  eulogized = false;
  if (!initialIdentityMatches(percept)) { void finishRun('initial_session_changed'); return; }
  if (!lab.ready(percept)) { brainNote = 'waiting for explicitly armed lab session'; return; }
  const stopReason = autonomousStopReason(percept);
  if (stopReason) { void finishRun(stopReason); return; }
  if (!Number.isSafeInteger(percept.qlen) || percept.qlen < 0) { brainNote = 'waiting for a readable timed action queue'; return; }
  if (percept.nativeBusy !== false) { brainNote = 'waiting for native character action state'; return; }
  if (percept.qlen > 0) { brainNote = 'waiting for the current timed action queue'; return; }
  if (percept.actionOutcome?.status === 'pending') { brainNote = 'waiting for inventory or needs evidence'; return; }
  if (!lab.beginRequest(percept)) { if (lab.stopped) void finishRun(lab.reason); return; }

  inFlight = true;
  brainNote = 'thinking…';
  const decisionPerceptAt = perceptAt;
  const decisionSource = perceptSource;
  const god = godQueue.splice(0);
  const discard = reason => {
    brainNote = `discarded model reply: ${reason}`;
    log('discard', reason);
    // Unanswered guidance belongs to the next decision that is actually accepted.
    godQueue.unshift(...god);
    if (godQueue.length > 40) godQueue.splice(0, godQueue.length - 40);
  };
  // Keep this SHORT — prompt length is the dominant latency cost. Your `memory` field is the
  // real continuity; the log is just the last few beats so you don't repeat yourself.
  const recent = state.log.filter(l => l.kind === 'decide' || l.kind === 'god' || l.kind === 'death').slice(-3)
    .map(l => l.text.slice(0, 90)).join('\n') || '(none)';
  const prompt = `${PERSONA}

YOUR MAJOR GOAL (hold to this): ${state.goal || '(none yet — set one this turn)'}
YOUR CURRENT SUBTASK: ${state.subtask || '(none yet — set one this turn)'}

YOUR MEMORY (you wrote this): ${state.memory}

RECENT DECISIONS:
${recent}
${god.length ? '\nA VOICE FROM BEYOND (the researcher watching you) says: ' + god.map(g => `"${g}"`).join(' ') : ''}
CURRENT SENSES: ${JSON.stringify(publicPercept())}

Advance your subtask toward your goal. STRICT JSON only.`;

  try {
    const out = grabJSON(await ccCall(prompt)); // Exactly one provider call per counted attempt.
    if (closing) return;
    // Inference may outlive the senses it used. Refresh from
    // disk, not merely the one-second polling cache, before changing intent or memory.
    const decisionAge = Date.now() - decisionPerceptAt;
    if (decisionAge > MAX_PERCEPT_AGE_MS || decisionAge < -1000) {
      discard('request percept expired during inference'); return;
    }
    if (!readPercept()) { discard('current percept is unreadable or stale'); return; }
    if (percept.dead) { discard('survivor is dead'); return; }
    if (!lab.ready(percept)) { discard('lab session was revoked, changed, or expired'); return; }
    const stopReason = autonomousStopReason(percept);
    if (stopReason) { await finishRun(stopReason); return; }
    if (percept.qlen !== 0 || percept.nativeBusy !== false) { discard('body became busy during inference'); return; }
    if (perceptSource.dev !== decisionSource.dev || perceptSource.ino !== decisionSource.ino) {
      discard('percept file was replaced during inference'); return;
    }
    const a = out.action;
    if (!a || typeof a !== 'object' || Array.isArray(a) || typeof a.type !== 'string'
      || !['MOVE', 'LOOT', 'EAT', 'DRINK', 'EQUIP', 'CLOSEDOOR', 'CONCEAL', 'BREAKIN', 'STOP', 'WAIT'].includes(a.type)) {
      throw new Error('Model reply must contain one supported action object.');
    }
    const type = a.type, dx = a.dx, dy = a.dy;
    const reply = String(out.reply || '').replace(/[\r\n]/g, ' ').trim().slice(0, 120);
    const say = String((god.length && reply) ? reply : (out.say || '')).replace(/[|\r\n]/g, ' ').slice(0, 90);
    const thoughtField = String(out.thought || '').replace(/[|\r\n]/g, ' ').slice(0, 200);
    const goalCandidate = String(out.subtask || out.goal || state.subtask || state.goal || '').trim().slice(0, 90);
    const nextSeq = Math.max(state.seq, Number(percept.lastSeq) || 0) + 1;
    const wire = lab.intent(percept, nextSeq, { type, dx, dy }, say, thoughtField, goalCandidate);
    writeIntentFile(wire); // Do not accept model-authored state if publication fails.
    if (god.length && reply) {
      state.chat.push({ from: 'claude', text: reply, t: new Date().toISOString().slice(11, 19) });
      state.chat = state.chat.slice(-40);
      log('reply', reply);
    }
    if (out.goal && String(out.goal).trim()) state.goal = String(out.goal).trim().slice(0, 200);
    if (out.subtask && String(out.subtask).trim()) state.subtask = String(out.subtask).trim().slice(0, 120);
    state.seq = nextSeq;
    intentLine = wire;
    lastThought = String(out.thought || '').slice(0, 500);
    lastAction = type === 'MOVE' ? `MOVE ${dx},${dy}` : type;
    if (out.memory) state.memory = String(out.memory).slice(0, 600);
    brainNote = 'claude';
    log('decide', `[${state.subtask}] ${lastAction}${say ? ` · "${say}"` : ''} — ${lastThought}`);
    saveState();
  } catch (e) {
    brainNote = `brain error: ${e.message} (attempt counted; no hidden retry)`;
    log('error', e.message);
  } finally {
    inFlight = false;
    if (!closing && lab.stopped) { await finishRun(lab.reason); }
    if (!closing && runConfig.maxRequests !== null && lab.requests >= runConfig.maxRequests) {
      // Give the final accepted command a bounded opportunity to be consumed and
      // complete. Queue completion is not an action-success receipt.
      const deadline = Date.now() + 10000;
      while (!closing && Date.now() < deadline && !lab.expired()) {
        if (readPercept() && percept.lastSeq >= state.seq && percept.qlen === 0 && percept.actionOutcome?.status !== 'pending') break;
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      if (!closing) await finishRun('request_budget_exhausted');
    }
  }
}

// adaptive cadence: sprint the mind when death is near, else keep gaps short so he feels alive.
// (each claude -p call already costs ~10-20s; keep the added idle wait small.)
function cadence() {
  if (!percept || percept.dead) return 10000;
  if (percept.zClose > 0) return 2500;   // danger — think almost continuously
  if (percept.zNear > 0) return 5000;
  if (percept.qlen > 0) return 6000;     // still walking — let the body travel, check back soon
  return 4000;                            // idle & safe — decide promptly so he isn't standing around
}
loopTimer = setTimeout(function loop() { if (!closing) decide().finally(() => { if (!closing) loopTimer = setTimeout(loop, cadence()); }); }, 500);

// ---------- web ----------
const MIND_HTML = `<!doctype html><meta charset="utf-8"><title>Claude survives</title>
<style>
body{background:#101418;color:#dde3ea;font:14px/1.5 system-ui,Segoe UI,sans-serif;max-width:860px;margin:24px auto;padding:0 16px}
h1{font-size:18px;color:#7fd1b9} .bubble{background:#1c2733;border-left:3px solid #7fd1b9;padding:10px 14px;border-radius:6px;margin:8px 0;font-size:16px;min-height:24px}
.say{color:#ffd479} .grid{display:flex;gap:18px;flex-wrap:wrap;margin:10px 0}
.stat{background:#151b22;padding:8px 12px;border-radius:6px;min-width:96px}.stat b{display:block;font-size:11px;color:#8899aa;text-transform:uppercase}
.bar{height:6px;background:#26303a;border-radius:3px;margin-top:4px}.bar i{display:block;height:6px;border-radius:3px;background:#7fd1b9}
.danger i{background:#e05555}#log{background:#0c0f13;border-radius:6px;padding:10px;max-height:340px;overflow:auto;font-size:12px;white-space:pre-wrap}
input{width:70%;background:#151b22;border:1px solid #26303a;color:#dde3ea;padding:8px;border-radius:6px}button{padding:8px 14px;border-radius:6px;border:0;background:#7fd1b9;color:#0c0f13;font-weight:600;cursor:pointer}
.note{color:#8899aa;font-size:12px}</style>
<h1>Claude survives — Project Zomboid</h1>
<div style="display:flex;align-items:center;gap:12px;margin-bottom:12px"><span class="note" id="session"></span><button id="stop-ai" hidden onclick="stopAI()" style="background:#e88787">Stop AI</button></div>
<div class="note" id="note"></div>
<div class="bubble" id="goal" style="border-left-color:#ffd479"><b style="color:#8899aa;font-size:11px;text-transform:uppercase;display:block">Goal</b><span id="goaltext"></span><div class="note" id="subtask" style="margin-top:4px"></div></div>
<div class="bubble" id="thought"></div>
<div class="bubble say" id="say"></div>
<div class="grid" id="stats"></div>
<div class="note" id="health"></div>
<h1 style="font-size:14px;margin-top:20px">The voice from beyond</h1>
<div id="chat" style="background:#0c0f13;border-radius:6px;padding:10px;max-height:240px;overflow:auto;margin-bottom:8px;display:flex;flex-direction:column;gap:6px"></div>
<p style="display:flex;gap:8px"><input id="god" placeholder="speak to him… (Enter to send)" onkeydown="if(event.key==='Enter')sendGod()" style="flex:1"><button onclick="sendGod()">send</button></p>
<h1 style="font-size:14px;margin-top:16px">Log</h1>
<div id="log"></div>
<script>
function escapeHTML(value){return String(value??'').replace(/[&<>"']/g,character=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));}
function bar(label,v,inv){const pct=Math.round(v*100);const dang=(inv?v>0.7:v<0.3)?' danger':'';
return '<div class="stat"><b>'+label+'</b>'+(inv?pct+'%':Math.round(v))+'<div class="bar'+dang+'"><i style="width:'+Math.min(100,pct)+'%"></i></div></div>'}
async function tick(){try{const r=await fetch('/api/state');const s=await r.json();
const run=s.run;document.getElementById('session').textContent=run.mode+' · '+run.status+' · '+(run.maxRequests===null?run.requests+' decisions · until stopped':run.requests+'/'+run.maxRequests+' decisions · '+Math.ceil(run.remainingSeconds/60)+' min remaining');
const stop=document.getElementById('stop-ai');stop.hidden=!run.armedOptIn;stop.disabled=run.status==='stopping';
document.getElementById('note').textContent='brain: '+s.brainNote+' · action: '+s.lastAction+' · seq '+s.seq+(s.percept?' · day '+s.percept.day+' '+String(s.percept.hour).padStart(2,'0')+':00 · '+s.percept.room:'');
document.getElementById('goaltext').textContent=s.goal||'(setting a goal…)';
document.getElementById('subtask').textContent=s.subtask?('▸ '+s.subtask):'';
document.getElementById('thought').textContent=s.lastThought;
document.getElementById('say').textContent=s.lastSay?('\\u201C'+s.lastSay+'\\u201D'):'';
const p=s.percept;if(p){document.getElementById('stats').innerHTML=
bar('hp',p.hp/100*1,false).replace(/>\\d+</,'>'+p.hp+'<')+bar('hunger',p.hunger,true)+bar('thirst',p.thirst,true)+bar('fatigue',p.fatigue,true)+bar('panic',p.panic,true)+
'<div class="stat"><b>zombies</b>'+p.zClose+' close / '+p.zNear+' near<div class="note">nearest '+p.zDist+' '+p.zDir+'</div></div>'+
'<div class="stat"><b>food items</b>'+p.foods+'</div>';}
const health=p?.health;let bodyCheck='Body check: unavailable';
if(health){bodyCheck='Body check: '+(health.valid===true?'observed':'incomplete');const summary=health.summary;if(summary){for(const [field,label] of [['bleedingParts','known bleeding'],['glassParts','embedded glass'],['unknownParts','unknown parts']]){const count=summary[field];if(Number.isInteger(count)&&count>=0)bodyCheck+=' · '+label+': '+count;}}}
document.getElementById('health').textContent=bodyCheck;
const chat=s.chat||[];const cbox=document.getElementById('chat');
cbox.innerHTML=chat.map(function(m){var god=m.from==='god';
return '<div style="align-self:'+(god?'flex-end':'flex-start')+';max-width:78%;background:'+(god?'#26303a':'#1c2733')+';border-left:3px solid '+(god?'#ffd479':'#7fd1b9')+';padding:6px 10px;border-radius:6px"><div style="font-size:10px;color:#8899aa;text-transform:uppercase">'+(god?'you':'him')+' · '+escapeHTML(m.t)+'</div>'+escapeHTML(m.text)+'</div>';}).join('');
cbox.scrollTop=cbox.scrollHeight;
document.getElementById('log').textContent=s.log.map(l=>'['+l.t+'] '+l.kind+': '+l.text).reverse().join('\\n');
}catch(e){document.getElementById('session').textContent='Connection lost — check session status';document.getElementById('stop-ai').disabled=true;}}
async function sendGod(){const i=document.getElementById('god');if(!i.value)return;const t=i.value;i.value='';await fetch('/god?text='+encodeURIComponent(t));tick();}
async function stopAI(){const button=document.getElementById('stop-ai');button.disabled=true;try{const response=await fetch('/control/stop',{method:'POST'});if(!response.ok)throw new Error('Stop request refused');document.getElementById('session').textContent='Stop requested — returning control to the game';}catch(error){button.disabled=false;document.getElementById('session').textContent=error.message;}}
setInterval(tick,2000);tick();
</script>`;

server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/control/stop') {
    if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
    const address = server.address();
    const origin = `http://${HOST}:${address.port}`;
    if (req.headers.origin !== origin || req.headers.host !== new URL(origin).host) {
      res.writeHead(403); return res.end('Same-origin dashboard request required.');
    }
    if (!runConfig.arm) { res.writeHead(409); return res.end('This session is observation only.'); }
    req.resume();
    res.writeHead(202, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ status: 'stopping' }));
    void finishRun('dashboard_stop');
    return;
  }
  if (u.pathname === '/pz/intent') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end(intentLine + '\n');
  }
  if (u.pathname === '/god') {
    const text = (u.searchParams.get('text') || '').slice(0, 300);
    if (text) {
      godQueue.push(text);
      if (godQueue.length > 40) godQueue.splice(0, godQueue.length - 40);
      log('god', text);
      state.chat.push({ from: 'god', text, t: new Date().toISOString().slice(11, 19) });
      state.chat = state.chat.slice(-40);
      saveState();
    }
    res.writeHead(200); return res.end('ok');
  }
  if (u.pathname === '/api/state') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    return res.end(JSON.stringify({
      lab: lab.snapshot(), run: sessionInfo(), percept: publicPercept(), perceptFresh: Date.now() - perceptAt < 5000, seq: state.seq,
      lastThought, lastSay: (intentLine.split('|')[4] || ''), lastAction, brainNote,
      goal: state.goal, subtask: state.subtask, chat: state.chat.slice(-24),
      memory: state.memory, log: state.log.slice(-60),
    }));
  }
  if (u.pathname === '/' || u.pathname === '/mind') {
    res.writeHead(200, { 'content-type': 'text/html' });
    return res.end(MIND_HTML);
  }
  res.writeHead(404); res.end();
}).listen(PORT, HOST, function () {
  const address = this.address();
  log('boot', `pz-bridge up on http://${address.address}:${address.port}/mind — brain: ${BACKEND} (${MODEL}) — percept from ${PERCEPT_FILE}`);
  readPercept();
  heartbeat();
});
