# The bridge (the brain)

## Safe-default laboratory fork

This fork starts **monitor-only**. It makes no model requests and does not arm
Lua unless `PZ_LAB_ARM=1` is explicitly set. The matching Lua starts disarmed;
legacy intent lines and unmodified upstream percepts cannot control it.

An explicitly armed run selects one of three profiles with `PZ_RUN_MODE`:

| Mode | Provider attempts | Duration |
| --- | --- | --- |
| `lab` (default) | Default 10, maximum 10 | Default 120 seconds, maximum 300 |
| `autonomous` | Default 120, maximum 300 | Default 1800 seconds, maximum 3600 |
| `continuous` | No cap | No cap |

The bounded modes accept `PZ_MAX_REQUESTS` and `PZ_MAX_SECONDS`, counted from
bridge startup. Continuous mode rejects those variables; omit them completely.
Failed HTTP calls, invalid JSON and discarded replies count as attempts. Each
loop iteration makes at most one provider call; a later iteration can try again
after an error. Continuous mode keeps running independently of a chat session
until stopped, revoked, disconnected or dead. It does not guarantee survival.

Use `PZ_RUN_MODE=continuous PZ_LAB_ARM=1` with the same backend/path settings
below for indefinite operation. Selecting a mode alone never arms the client.
An independent process needs the game, server, model gateway and awake computer
to remain available. No automatic login, respawn or restart is implemented.

Example using an already running loopback OpenAI-compatible model gateway:

```sh
PZ_LAB_ARM=1 PZ_MAX_REQUESTS=5 PZ_MAX_SECONDS=120 \
PZ_BACKEND=openai PZ_API_KEYLESS=1 PZ_MODEL=gpt-6.1-sol PZ_REASONING_EFFORT=none \
OPENAI_BASE_URL=http://127.0.0.1:4141/v1 \
PZ_LUA_DIR=/absolute/path/to/task-client/Lua \
PZ_STATE_FILE=/absolute/path/to/existing/run-directory/memory.json \
node pz-bridge.mjs
```

Keyless mode is accepted only for an explicit HTTP loopback endpoint and sends
no Authorization header. Cloud providers use their separately configured key.
The bridge reads environment variables; it does not load `.env` files itself.

The bridge binds one world, actor and session, then renews a two-second lease in
`claude_control.txt`. Every intent carries that identity, a controller token and
an expiry. Lua checks them before executing any action. MOVE offsets have a
four-tile radius, loot searches are restricted to four tiles, travel momentum
is disabled, and this fork never changes game speed or automatic sneak/light
settings. Initial ARM refuses a pre-existing timed-action queue; lease renewal
can continue while the controller's own actions are queued. Existing local reflex,
loot, eating, drinking, equipment and concealment functions run only while the
lease is armed. The earlier bounded multiplayer run observed actual looting and
screwdriver equip. A subsequent scripted check collected three food items and
consumed one with an observed hunger reduction. Positive drinking and combat
remain untested. See [the bounded lab results](../docs/LAB-PLAYTEST.md).

`bodyRevision="survival-1"` identifies the current body update. Renewed short
leases can continue without an absolute body cutoff. LOOT ranks nearby
safe edible food and pure clean water ahead of a single useful weapon fallback;
it does not fill inventory with household clutter. Food checks match the official
B42 inventory pane, including known poison and unsafe raw food checks. Unknown
or hidden hazards can still exist. Nearby contents are proximity observations,
not proof of visibility or an accessible route. In multiplayer, unrequested
container lists can be empty while their actual contents remain unknown; a zero
count does not establish an empty container or house. The current body does not
request all container contents itself. `nearbyLoot` exposes these client counts;
`inventoryCount` covers all items while the legacy names list remains capped at12.

`health` reports read-only body-part facts, bandage/bleeding/glass counts and
urgency. Complete observations require every expected unique body-part ID;
missing APIs, unreadable parts or a truncated enumeration remain unknown or
partial. It does not diagnose the cause of every health decrease, reveal hidden
infection state or add treatment actions. The HUD and dashboard show whether
the body check is complete.

`qlen=-1` means the Lua queue could not be read. `nativeBusy` independently
reports the game's action/traversal state and is `null` when unreadable.
Unknown state and native activity block new model work. Disarm confirmation
requires both an empty Lua queue and observed native inactivity; a queue clear
alone cannot claim that an already-started Java traversal ended.

The legacy `BREAKIN` intent now only tries an already-adjacent, same-floor,
open or fully glass-cleared window with a supported landing and no observed
floor glass or barricade. It never smashes, removes glass, walks or clears the
queue. The guarded vanilla action rechecks controller identity/lease and live
hazards before execution. Queue acceptance must be confirmed. Unsafe or unknown
conditions return explicit blockers. These policies are source-reviewed and
fixture-tested; actual multiplayer window execution remains unverified.

LOOT/EAT/DRINK publish `actionOutcome` with their original world/actor/session.
`observed_effect` requires a new full-inventory item ID or the matching raw
hunger/thirst reduction after the queue settles. `no_effect` follows an empty
queue without an observed delta after a one-second synchronization grace;
`interrupted` records takeover/reflex replacement; `unverified` records missing
evidence or a30-second timeout. These receipts report observed changes, not proof
of causation or that every requested transfer completed. The bridge waits for
pending evidence before another decision and stores terminal receipts in
`state.outcomes`. At a request cap, a final command gets at most ten seconds
within the selected duration budget. Continuous mode has neither overall cap.

**Any key or mouse input permanently disarms and rotates the session.** Idle
input never automatically resumes the AI. Exit the stopped bridge and explicitly
start another opted-in run to arm the new session. A missing heartbeat, pause/tick
gap, player change, world change, death or a selected duration cap also revokes
control. Use Ctrl-C or the dashboard's **Stop AI** button to request shutdown.
The Stop endpoint requires POST with the exact loopback dashboard origin and
host; the other legacy dashboard endpoints still assume trusted local inputs.
Optional `PZ_EXPECTED_SESSION`, `PZ_EXPECTED_WORLD` and `PZ_EXPECTED_ACTOR` must
all be supplied together and prevent acquiring a replacement player at startup.
On finish, it stops heartbeat publication,
writes DISARM, and waits up to 3.5 seconds for a fresh unarmed percept from the
same world and actor, an empty queue, and no reported queue-clear failure. The final
state includes `lab.requests`, `lab.reason`, `finalObservation` and
`disarmObserved`; a written stop command alone is not proof of disarming. An
unobserved cleanup exits with status 2. The lease limits game-control duration;
shutdown may use the extra observation window to record that control ended.

`/api/state.run` reports mode, requests and remaining budgets; unlimited values
are JSON `null`. Normal damage and critical needs do not stop continuous play.
The separate bounded `autonomous` profile stops on a health drop of at least one
point, hunger at 0.85 or thirst at 0.65. Both extended profiles reject invalid
vitals. State history is kept as bounded rolling windows.

The final intent gets at most ten seconds, within the overall lifetime, to be
consumed and finish its timed-action queue. A consumed sequence and empty queue
are **not success receipts**. Compare actual position, inventory/vitals and
object state to establish an effect. This remains a player-client prototype,
not a server-owned NPC system or proven multiplayer survival bot. Do not enable
a second controller for the same player simultaneously.

## Backend and dashboard

`pz-bridge.mjs` reads the game's perception, asks an LLM what to do, writes the decision back, and serves the live mind dashboard at `http://127.0.0.1:8799/mind`. The HTTP listener binds explicitly to IPv4 loopback (`127.0.0.1`). `llm.mjs` is the pluggable backend.

```bash
node pz-bridge.mjs
# → pz-bridge up on http://127.0.0.1:8799/mind — brain: <backend> (<model>) …
```

## Choose your AI

It works with **any** of these — free/local or hosted. Set a key (or `PZ_BACKEND`) and it auto-detects. Override the model with `PZ_MODEL`.

| Backend | How to enable | Default model | Notes |
|---------|---------------|---------------|-------|
| **Ollama** (free, local) | `PZ_BACKEND=ollama` | `llama3.1` | 100% free & offline. `OLLAMA_URL` default `http://localhost:11434`. Set `PZ_MODEL` to any pulled model (e.g. `mistral`, `qwen2.5`). |
| **Anthropic** (Claude) | `ANTHROPIC_API_KEY=…` | `claude-haiku-4-5` | Fast + cheap on Haiku. |
| **OpenAI** (GPT) | `OPENAI_API_KEY=…` | `gpt-4o-mini` | |
| **OpenAI-compatible** | `OPENAI_API_KEY=…` + `OPENAI_BASE_URL=…` | — | OpenRouter, Groq, Together, LM Studio, etc. Point `OPENAI_BASE_URL` at the endpoint. |
| **Google Gemini** | `GEMINI_API_KEY=…` | `gemini-1.5-flash` | |
| **Claude CLI** (default) | `claude` on PATH (or `CLAUDE_BIN`) | `haiku` | Uses your Claude Code subscription; no API key needed. |

### Examples

```bash
# Free & local with Ollama (pull a model first: `ollama pull llama3.1`)
PZ_BACKEND=ollama PZ_MODEL=llama3.1 node pz-bridge.mjs

# Anthropic API
ANTHROPIC_API_KEY=sk-ant-… PZ_MODEL=claude-haiku-4-5 node pz-bridge.mjs

# OpenAI
OPENAI_API_KEY=sk-… PZ_MODEL=gpt-4o-mini node pz-bridge.mjs

# OpenRouter (OpenAI-compatible) — try any model on one key
OPENAI_API_KEY=sk-or-… OPENAI_BASE_URL=https://openrouter.ai/api/v1 PZ_MODEL=meta-llama/llama-3.1-70b-instruct node pz-bridge.mjs

# Google Gemini
GEMINI_API_KEY=… PZ_MODEL=gemini-1.5-flash node pz-bridge.mjs
```

On Windows PowerShell, set vars with `$env:NAME="value"` before `node pz-bridge.mjs`. See [`.env.example`](.env.example). The bridge reads the process environment; it does not automatically load `.env` files. Local `.env` files are ignored by Git.

## Tuning

| Var | Default | What |
|-----|---------|------|
| `PZ_MODEL` | per-backend | The model to use. |
| `PZ_API_KEYLESS` | unset | Only `1` enables explicit loopback access without sending an Authorization header. |
| `PZ_REASONING_EFFORT` | unset | Optional setting for a model that supports it; the lab example uses `none`. |
| `PZ_TIMEOUT` | `45000` | Per-decision timeout (ms). Bump it for slow local models. |
| `PZ_PORT` | `8799` | Dashboard + intent port on `127.0.0.1`. Integer `0`–`65535`; `0` asks the OS for an available port, printed on startup. |
| `PZ_LUA_DIR` | `~/Zomboid/Lua` | Directory containing `claude_percept.json` and `claude_intent.txt`. Explicit overrides must already exist. |
| `PZ_STATE_FILE` | `pz-state.json` next to the script | Persistent memory and log file. Its parent directory must already exist; the file is created when state is saved. |

**Speed matters.** The whole loop is more fun when decisions land in a few seconds. Small/fast models (Haiku, GPT-4o-mini, Gemini Flash, an 8B Ollama model) feel great. Big models are smarter but slower — the local reflex keeps the survivor alive either way, so favor speed.

## What it writes

- Reads `claude_percept.json` in `PZ_LUA_DIR` (the game's senses).
- Writes `claude_intent.txt` in that same directory (the decision the mod executes).
- Writes `PZ_STATE_FILE` — the AI's persistent memory + decision log across restarts. Safe to delete for a clean slate.

Relative override paths resolve from the directory where you launch Node. Use absolute paths for launchers, and use `$HOME` in your shell rather than a literal `~` inside a quoted path. Blank paths, invalid ports, and a state file that overlaps the percept/intent files are rejected before the bridge starts. The default Lua directory may be absent until Project Zomboid's first launch; the bridge does not create it.

Separation checks resolve directory/file symlinks and detect existing hardlinks. IPC filenames are reserved without regard to case inside the same resolved directory, even before those files exist. Dangling symlinks are rejected. These startup checks prevent accidental aliases; they do not protect against another process changing filesystem links after validation.

## Delayed decisions

The bridge uses the percept file's modification time, not the time Node reads
it, for its 15-second freshness limit. It checks current readable JSON before
starting a decision and again immediately after the model returns, with no automatic
retry. A reply is discarded before changing the intent, sequence, goals, reply,
or memory if its original senses have expired, the current percept is unreadable
or stale, the survivor is dead, the body became busy, or the percept file was replaced. Unanswered
dashboard guidance is retained for the next accepted decision. Raising
`PZ_TIMEOUT` does not extend this freshness limit; a model that regularly takes
longer than 15 seconds will have its decisions discarded.

The lab protocol additionally binds world, actor and session and revokes control
on takeover. This does not add multiplayer NPC ownership or action-success
receipts; those remain separate integration and playtest requirements.

## Isolated development runs

Give each bridge its own Lua directory, state file, and port. For example, from `bridge/` on macOS/Linux:

```bash
mkdir -p "$PWD/scratch/run-a/Lua"
PZ_BACKEND=ollama \
  PZ_LUA_DIR="$PWD/scratch/run-a/Lua" \
  PZ_STATE_FILE="$PWD/scratch/run-a/pz-state.json" \
  PZ_PORT=8800 \
  node pz-bridge.mjs
```

This only changes the bridge's paths. To connect a real game instance, its mod must write and read the same directory. These options do not add multiplayer, dedicated-server authority, or coordination between survivors. Without a percept file, this isolated bridge waits and makes no model requests.

## Local tests

Run `npm test` from `bridge/`. No package installation is needed. Tests use Node's built-in runner, temporary directories, synthetic game data, and a fake Ollama endpoint on an OS-assigned loopback port. If `lua` is installed, they also run deterministic gate and whole-body engine-stub checks; otherwise that entry is explicitly skipped. They do not launch the game or a provider CLI, inherit API keys, or contact a real model service. The runtime smoke test takes about ten seconds because it preserves the bridge's normal decision cadence.
