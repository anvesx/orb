# 0016 · The brain packages import no voice code

Date: 2026-11-16 · Status: accepted · Design: docs/design/layer-separation.md

## Decision
- orb-discussion and the brain modules of orb-core import no LiveKit, Gemini or speech code.
- The agent service's brain routes (`apps/agent/src/orb_agent/server.py`: sessions, turns, models, the page) have no
  voice code of their own: the voice routes and checks live in `voice.py` (`VoiceChannel`), in the same process and at
  the same URLs. `server.py` still imports `voice.py`, so the service needs `livekit` installed, as before.
- The room-to-session rule (`orb-<session id>`) lives once, in `orb_core.rooms`, for both apps.
- `tests/test_boundaries.py` enforces it: the brain never imports voice, packages never import an app, the two apps
  never import each other. `apps/agent/tests/test_contract.py` records every route and answer field.

## Why
Anyone can run only the brain (text, Slack, another voice stack) through the HTTP API, and a voice change cannot
break the brain. It was a refactor: no route, answer, log line or call changed.

## Rejected
- A separate voice-gateway process: the page and the voice signal share one address through a tunnel (decision 0009),
  and one more process costs memory on a 16 GB Mac.
- An OpenAI-compatible endpoint and an LLM provider registry: new features, for a later PR.
- Splitting `plugins.py` or `main.py`: no separation gain.
