# 0022 · The screen canvas: finding is separate from talking and drawing

Date: 2026-11-24 · Status: proposed

## Decision
- Gemini Live names what to show in words (`mark(target, kind, style, note)`); it never gives coordinates.
- The app grounds the target on one frame with the grounder for its kind: OCR for text, Accessibility for UI
  elements, a Gemini vision model (through the agent service's `POST /v1/ground`) for pictures and things.
- A pure `Canvas` keeps the annotations, each attached to an `Anchor`; per-screen renderers draw them. Marks are
  hand-drawn (`Rough`). Diagrams and 3D later are more annotation kinds and layers on the same canvas.
- The screen is captured by one ScreenCaptureKit stream for the whole call, never by a screenshot per frame.
The design is `docs/design/screen-canvas.md`.

## Why
- Live tests: Gemini Live's coordinates were 120 to 500 px off; `gemini-3.5-flash-lite` boxed "the blue robot" within
  2 px of 1000 in 1.8 s; OCR and Accessibility are exact for text and controls.
- One kind of seam per job keeps later kinds (arrows, guides, diagrams, 3D) from touching grounding or tools.
- A screenshot per second made macOS's capture indicator blink.

## Rejected
- **Gemini Live's own coordinates:** too far off to circle anything small.
- **Heuristics for pictures** (saliency next to a caption, an ink scan above it, colour names): they guessed, and
  circled the wrong robot.
- **Grounding in the voice worker:** it has only the compressed 1 fps video, on another clock, and no Accessibility.
