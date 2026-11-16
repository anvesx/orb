# Observability: traces, metrics and logs in New Relic

Status: building · Branch: `feat/new-relic-observability` · Date: 2026-11-16

## 1. Goal
One dashboard that shows what happened in a call or a chat: what the person said, the persona that answered, the reply,
how long each step took, and the errors. Today this is only in `data/logs/*.log`.

orb sends OpenTelemetry (OTel) traces, metrics and logs over OTLP/HTTP. New Relic (free tier, US region) receives them.
Another OTel backend needs only another endpoint and key, not code.

## 2. Rules
- **Off by default.** With no `NEW_RELIC_LICENSE_KEY`, nothing is set up and nothing is sent. Every route and answer
  stays the same (the contract tests of decision 0016).
- **Words follow `ORB_LOG_TEXT`.** With 1, the person's text and the reply are sent. With 0, only timings, personas,
  tokens and errors: the same rule as the log files.
- **No brain change.** The turn trace is built from the events the discussion agent already yields (`read`, `decision`,
  `reply` with `timing`, `check`, `error`). `orb-discussion` is not edited.
- **No local model in the live check.** It uses Gemini Live only.

## 3. Design
| Part | Change |
|---|---|
| `orb_core/telemetry.py` (new) | `start(service)`: tracer, meter and logger providers with OTLP/HTTP exporters to `https://otlp.nr-data.net` (`OTEL_EXPORTER_OTLP_ENDPOINT` overrides), header `api-key`; the `orb` logger's lines go too. `text_allowed()`. `traced(events, sid, channel)`: passes each event on unchanged and records an `orb.turn` span with `jev.read` and `llm` child spans placed by the turn's timing. |
| agent service | `main()` calls `start("orb-agent")`; `turn()` streams `traced(...)`. |
| voice worker | `NEW_RELIC_LICENSE_KEY` and `OTEL_EXPORTER_OTLP_ENDPOINT` load from `.env`; each worker process calls `start("orb-voice")` and hands the tracer to LiveKit Agents (`set_tracer_provider`), which traces every call: VAD, STT, LLM, TTS, Gemini realtime, tokens. A call's spans are flushed when it ends. |

## 4. Tickets
| # | Ticket |
|---|---|
| OB-0 | This document |
| OB-1 | `orb_core/telemetry.py` and its tests (in-memory exporter, no network) |
| OB-2 | Agent service: `start`, `traced` |
| OB-3 | Voice worker: env names, the tracer hook, flush on shutdown |
| OB-4 | Docs: README, `.env.example`, LLDs, decision 0017 |
| OB-5 | Live Gemini call, data seen in New Relic, last review, PR |

## 5. Baseline (main, 38822eb)
`make test` on 2026-11-16, all green: orb-core 24, orb-discussion 39, orb-speech 2,445 (3 skipped), orb-bench 24,
agent service 63, voice worker 44, boundaries 4.
