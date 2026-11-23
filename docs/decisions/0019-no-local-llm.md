# 0019 · No local LLM for replies

Date: 2026-11-23 · Status: accepted

## Decision
- orb no longer writes replies with a local LLM: the Ollama client (`orb_core/ollama.py`), the default model
  `gemma4:e2b`, the session field `llm_model`, the LLM picker of the page, the `llm` part of `/v1/models`, the bench's
  LLM tab and `llm` suite are gone.
- `DiscussionAgent` takes an optional `llm` (`stream`, `warm`, `health`; failures raise `orb_core.agent.LLMError`).
  Without one, `turn` yields one `error` event and changes nothing, `/health` shows `llm: null`, and a session never
  warms. The turn path stays, so another LLM is one object passed in `build()`.
- Gemini Live writes the replies (`note` and `add_reply`, decision 0018). The local speech-to-text and text-to-speech
  engines, the guarded polish of transcripts (decision 0013, a small model through Ollama) and the bench's STT, TTS and
  format suites stay.
- `scripts/check_stack.sh` checks a persona note instead of a text turn, and runs the voice end-to-end test only with
  `--e2e`: the orb voice mode and the `turn` suite answer nothing until an LLM is added.

## Why
- The owner does not want a local open model as the brain; the next brain is Claude, through the user's own Claude
  login. Its design is a separate decision.
- The local model held 7.9 GB of memory on a 16 GB Mac and had to be warmed per session.

## Rejected
- Removing the turn path, the orb voice mode and the speech engines too: they are the shape that a Claude brain plugs
  into (speech-to-text → Claude → text-to-speech).
