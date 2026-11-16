# Layer separation: the brain does not know about voice

Status: planned · Branch: `refactor/layer-separation` · Date: 2026-11-16

## 1. Goal and the one rule
**The brain (sessions, turns, the discussion agent) must work and be testable with no voice code present. Voice
is a channel that uses the brain through its HTTP API.** Anyone can then run only the brain (text chat, Slack, someone
else's voice stack), or only the speech service, or our voice worker in front of another brain that speaks the same
API.

This is a refactor: **no behavior changes.** Every URL, request, response, log line, page and voice call stays the
same. Only where code lives changes.

## 2. What is already right (no change)
| Part | Why it is already separate |
|---|---|
| The brain contract | `orb_core/agent.py`: `Session.turn(text) -> events`. Channels never read agent state directly. |
| The discussion agent | `orb-discussion` imports no LiveKit, no Gemini, no speech code. |
| The speech service | its own process and API (`/v1/stt`, `/v1/tts`, `/v1/polish`); usable alone. |
| Voice worker → brain | only over HTTP at `ORB_AGENT_URL` (`/v1/sessions/{id}`, `/turns`, `/instructions`). Any brain that serves those three routes can sit behind our voice worker. That is the seam already; no new module needed. |

## 3. What is mixed today (the problems this PR fixes)
```
apps/agent/src/orb_agent/server.py  (one create_app)
 ├─ brain:  sessions · turns · models.llm · page
 └─ voice:  Gemini checks (orb_core.gemini) · "warm the LLM unless gemini-live" · /v1/voice/token
            /v1/voice/status · /instructions (+ VOICE_RULES) · models.gemini       ← voice inside the brain service

"orb-" + session id   written in apps/agent/voice.py AND apps/voice-agent/config.py  ← one contract, two copies
```
1. **P1 · The brain service code knows voice.** `server.py` imports `orb_core.gemini`, checks voice modes, decides
   whether to warm the LLM by voice mode, signs LiveKit tokens and builds the Gemini prompt. Without voice, all of
   that still sits in the brain's request path.
2. **P2 · The room name is a hidden contract with two copies.** The agent service names a room `orb-<id>`, and the
   voice worker strips `orb-` to find the session. A change in one breaks voice with no test failing.
3. **P3 · Nothing guards the boundary.** A future import of LiveKit into `orb-discussion` would pass every test.

## 4. Target
```
                 ┌────────────── channels ──────────────┐
  browser text ─▶│ server.py: brain routes + page        │
                 │ voice.py:  voice routes (VoiceChannel)│◀─ same routes as before, voice on or off
                 └──────────────────┬───────────────────┘
                                    ▼
                 brain: orb_core.agent · orb_discussion   (no voice import, enforced by a test)
```
- `server.py` keeps the brain routes, the page, `build()` and `main()`. It no longer imports `orb_core.gemini`.
- `voice.py` (exists: LiveKit config, tokens, probes) gets a `VoiceChannel` whose `.router(session_or_404)` is
  included like `bench.make_router` and `livekit_proxy.make_router`. It owns: `/v1/voice/token`, `/v1/voice/status`,
  `/v1/sessions/{id}/instructions`, the voice fields of a session config (Gemini checks, `--gemini` rules), the warm
  decision, and the `gemini` part of `/v1/models`. `server.py` asks it `.check(config)`, `.warms(config)`, `.status()`
  and `.models()`.
- The room contract (`room_for`, `session_for`, the prefix) lives once in `orb_core`, used by both apps.

**Not in this PR (each would be a behavior change, or a split for its own sake):**
- a separate voice-gateway process;
- an OpenAI-compatible brain endpoint;
- an LLM provider registry;
- splitting `plugins.py` or `main.py` into smaller files. They stay as they are: the user ruled out cutting a file
  into chunks with no separation gain.

## 5. Tickets
One commit per ticket. After each ticket: `make test` all green with the expected count, then **one** poteto agent
reviews the blast radius (callers, imports, tests, docs, scripts) before the next ticket starts. Never more than
one agent at a time. No orb voice pipeline run (it hangs the Mac); Gemini-only runs are fine.

| # | Ticket | Done when |
|---|---|---|
| LS-0 | **Safety net first.** (a) A route snapshot test: every method+path of `create_app` with voice on and with voice off, and the keys of `/v1/models`, `/health`, a session state. (b) A boundary test over the source tree (ast imports): `orb_core.agent`, `orb_core.jev`, `orb_core.ollama`, `orb_core.web`, `orb_discussion` never import `livekit`, `orb_voice`, `orb_agent`, `orb_core.gemini`; `apps/agent` never imports `orb_voice`; `apps/voice-agent` never imports `orb_agent` or `orb_discussion`; `orb_agent.server` never imports `orb_core.gemini` or `livekit` (marked xfail until LS-1). | both green on main's code (the server rule xfail); baseline count recorded below |
| LS-1 | **Voice routes out of `server.py` into `voice.VoiceChannel`** (P1). Moved code keeps its body. `create_app` signature unchanged; the router is always included, as the routes were before (proven by LS-0a). | snapshot unchanged; server rule passes (xfail removed); poteto blast-radius review |
| LS-2 | **One room contract** (P2): `orb_core/rooms.py` with `ROOM_PREFIX`, `room_for`, `session_for`; both apps import it; the two copies go. | `test_session_for_*` passes unchanged; poteto review |
| LS-3 | **Comments.** In the files this PR touches only: drop comments that repeat the code or tell history ("the first test…"); keep the ones that say why. | diff is comments only (an ast compare of each file shows no code change) |
| LS-4 | **Docs.** README: a high-level diagram (channels → brain: Jev reads → debt rules → one of six personas → LLM → check; voice modes; speech service). `docs/architecture.md` layers, the two LLDs, decision 0016. | links work; numbers unchanged |
| LS-5 | **Final check.** `make test` same count + new tests; `scripts/dev.sh --gemini` starts; curl `/health`, `/v1/models`, a session, `/instructions` give the same JSON as on main; the owner makes one Gemini call. A last poteto review of the whole diff. | PR opened |

### How "no behavior change" is proven
1. **Routes:** LS-0's snapshot is written on main's code and must not change.
2. **Moved code:** an ast comparison of each moved function before and after (bodies equal, only the module differs).
3. **Tests:** every existing test passes; a test only changes its import line when its subject moved.
4. **Live:** the agent service's JSON answers on main and on the branch are compared with curl (LS-5).
The orb voice pipeline (`entry` in `main.py`) is not changed by this PR, so it is not run.

## 6. Baseline (main, a21535f)
`make test` on 2026-11-16, all green: orb-core 22, orb-discussion 39, orb-speech 2,445 (3 skipped), orb-bench 24,
agent service 60, voice worker 45. (orb-core's count includes the local, untracked `test_scaledown.py`.)

## 7. Question: can the discussion agent's personas drive Gemini Live?
**Partly, and not in this PR.** What Gemini Live already gets from us: orb's system prompt for the topic and its
source (`/instructions`). What it does not get: orb's per-turn steps (Jev reads the message, the debt rules pick a
persona, the persona note goes to the LLM, the reply is checked). In Gemini Live the model hears the audio and starts
speaking by itself; there is no text step between "the person stopped" and "the reply starts" where our note can go.

Ways to bring the personas in, each with a cost (to measure in the next architecture PR, not assumed here):
| Way | How | Cost |
|---|---|---|
| A tool | Gemini calls `ask_orb(text)` each turn and speaks the answer orb's brain wrote | adds the brain's time (Jev about 0.5 s + LLM) to every turn; Gemini may reword the answer |
| A note one turn late | after each turn our brain reads the transcript and sends the next persona note as context | the persona fits the previous message, not the current one |
| A cascade with cloud STT/TTS | our brain writes every reply, as in the orb pipeline | not speech-to-speech any more |

This PR makes none of these harder; it changes no Gemini behavior.
