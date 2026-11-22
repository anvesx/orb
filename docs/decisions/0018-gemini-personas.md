# 0018 · Gemini Live gets orb's personas through one tool

Date: 2026-11-17 · Status: accepted · Design: docs/design/gemini-personas.md

## Decision
- In a Gemini Live call with the "orb personas" switch, Gemini calls one tool, `get_persona_note`, before each reply.
  The tool asks the agent service: Jev reads the person's words, the debt rules choose the persona, and the persona
  note is the tool's result. Gemini writes and speaks the reply. No Gemma, no Ollama.
- The tool is BLOCKING: Gemini waits for the note. So the personas need `gemini-3.8-live`; the extended-thinking model
  refuses a blocking tool.
- Gemini's spoken reply goes back to the session, and Jev checks it, so the ledger, the chat and the debt board are the
  same as in the orb pipeline.
- The "Google Search" switch adds Gemini's own Google Search tool. orb runs no search code.

## Why
- The note goes back as the tool's result, not as a new system prompt: Gemini 3.x Live ignores a system prompt that
  changes inside a tool call (livekit/agents #7917), and refuses a system-role update (1007).
- A tool keeps Gemini's own turn detection and speed. The other way, the worker detects each turn and makes Gemini
  reply with the note, is the fallback if Gemini skips the tool too often (measured per turn: `called`).

## Rejected
- Gemma writes and Gemini only speaks: two models in one turn, and Gemini's voice loses its own words.
- A note one turn late, with no tool: no wait, but each persona answers the turn before.
