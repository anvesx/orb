# 0021 · The screen is the context: orb sees, reads and points at it

Date: 2026-11-24 · Status: proposed

## Decision
- In a Mac call, what the person is looking at is the context. The app publishes the display under the pointer as a
  video track (1 frame/s), and Gemini Live gets it as video input. The design is `docs/design/mac-screen.md`.
- Gemini gets three function tools that the voice worker forwards to the app by LiveKit RPC: `read_screen` (exact text
  by Accessibility and OCR, plus the open document), `highlight_text` and `point_at` (the companion moves there).
- The app does every read, on the Mac, only during a call; the worker gets text and video, never files.
- The panel loses files and folders as context (Add, chips), the service dot, the Inspector button and New session.
  The service keeps `sources` (decision 0020) for later contexts.
- Google Search is on by default.

## Why
- The owner wants to talk about whatever is on the screen with no setup: "can you read this, explain this".
- Video gives Gemini the layout; OCR and Accessibility give it exact words; RPC tools let it show what it means.
- Tools in the worker plug into the next brain (Claude) unchanged.

## Rejected
- **LiveKit's built-in screen share:** main display only, no switch without a new track, and no frames while the
  screen is still.
- **A screenshot per turn sent as text input:** Gemini Live takes images as realtime input, the video path already
  exists in LiveKit Agents, and per-turn images need the turn boundary that Gemini's server owns.
- **Pointing from Gemini's coordinates only:** a 1024 px frame is too coarse to hit a line of text; OCR boxes are exact.
