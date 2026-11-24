# The screen canvas: how orb finds things on your screen and draws on it

Status: built · Branch: `feat/mac-rough-marks` · Date: 2026-11-24 · Decision: 0022 · Replaces sections 5 and 14 of
[mac-screen.md](mac-screen.md)

## 1. Why a new core
The first version pointed and highlighted through tools that mixed three jobs: deciding *what* to show (Gemini),
finding *where* it is (OCR, Gemini's own coordinates, guesses), and *drawing* it (one amber box). Live tests showed the
cost: Gemini Live's coordinates were 120 to 500 px off, a caption heuristic circled the wrong robot, and every new kind
of mark meant a new special case. orb will draw much more on the screen later (diagrams, arrows, step-by-step guides,
3D models next to what you look at), so this design separates the three jobs and gives each a seam:

```
 Gemini Live (talks)          app: Grounding (finds)                     app: Canvas (keeps)       app: Renderer (draws)
 ───────────────────          ──────────────────────                     ───────────────────       ─────────────────────
 mark("the blue robot",  ──▶  Target.describe  ──▶ text? element? sight? ──▶ Annotation(id, kind,   ──▶ per-screen layers:
      style: circle)          on one Frame          → Region (rects,        anchor: Region,           RoughMarkLayer,
                                                     by, confidence)         note, lifetime)          (later) DiagramLayer,
 answer {"found", "by"}  ◀──────────────────────────────────────────────── Canvas.apply(op)          SceneLayer (3D)
```

Gemini never gives coordinates. It names the target in words; the app finds it with the right tool for the target,
on the exact frame the person sees, and the canvas draws it.

## 2. Perception: one stream, immutable frames
- `ScreenStream` (built): one ScreenCaptureKit stream of the display under the pointer for the whole call, two frames a
  second at most, orb's windows excluded, the latest complete frame kept. A stream keeps macOS's capture indicator
  steady; a screenshot per second made it blink.
- `Frame` (OrbKit): an immutable value with an id, the display's frame in global points, the pixel size and the time.
  The pixels stay in the app (`ScreenFrame`). Every grounding works on one frame and every region says which frame it
  came from, so a mark never mixes two moments.
- The 1 fps video for Gemini Live and the OCR read the same latest frame. No screenshot is taken during a call
  (only once before the stream's first frame).

## 3. Grounding: from words to a region
`Target` (OrbKit) is what the tool asked for: `{ what, kind }`, where `kind` is `text` (words on the screen), `ui` (a
button, menu, field, tab) or `visual` (a picture, an icon, a part of a figure). The kind routes the target to one
grounder, so a picture never waits for OCR and a quote never goes to the vision model first:

| Kind | Grounder | How | Time | Then |
|---|---|---|---|---|
| `text` | `TextGrounder` | Vision OCR of the frame (cached by frame id) + `TextMatch` + `ScreenMap.passage` | 0 ms cached, 0.5–1.5 s fresh | `visual` |
| `ui` | `ElementGrounder` | the front window's Accessibility tree, at most 50 ms and 12 levels deep: visible elements whose title, description or value matches, scored exact > prefix > contains | < 50 ms | `text`, then `visual` |
| `visual` | `SightGrounder` | the agent service's `POST /v1/ground`: the frame as JPEG (1280 px, quality 70) and the description; a Gemini vision model answers `{found, box_2d, confidence}`; an answer under 0.9 confidence, or any answer for a `ui` target, is checked on its crop ("is this …? yes or no") | 2–3 s, 4 s checked | — |

- **One answer or none, never a guess:** each grounder returns all candidates. Several with no clear best (text that
  is on the screen twice, two "Save" buttons) are ranked by distance to the pointer and the front window; when the
  top two are still close, the answer says `matches: n` and marks the first, so Gemini can say "the first of three".
- **Checks on a sight answer:** `found` must be true, the box inside the frame, under 60 % of it, and not over orb's
  own windows (they are excluded from the frame, so a box there is invented). The live test showed why a crop check
  is needed too: asked for a zoom button that full-screen Preview does not show, the model boxed the page handle at
  0.88 confidence. A control that Accessibility could not find is suspect, so `ui` answers are always checked. The answer carries the model's
  `confidence`; Gemini hears it and can hedge.
- **Timing:** Gemini Live's tool calls block (it waits for the answer, which keeps it from describing a mark that is
  not there). Each grounder has a budget (text 2 s, ui 0.2 s, sight 6 s; a first sight run of 3.5 s ran out); past it the answer is "not found in time".
- **Keys and privacy:** the app never holds a Google key; `/v1/ground` is the one place that calls the vision model
  (`ORB_GROUND_MODEL`, default `gemini-3.5-flash-lite`, temperature 0). A frame leaves the Mac only for a `visual`
  target, as the 1 fps video already does during a call. A remote request needs the share key (`access.py`).
- **Who grounds:** the app. It alone has Accessibility, the exact frame and the display geometry; the worker has only
  the compressed 1 fps video on another clock.

## 4. The canvas: anchors and annotations
- `Anchor` (OrbKit) says where an annotation is attached. A sum type from the start, so later kinds don't change
  the annotation: `.screen(displayID, rects, frameID)` now; `.window(windowID, rects)` and `.element(ref)` later, with
  an anchor tracker that moves marks when a window moves or a page scrolls.
- `Annotation`: an id, a kind (`mark(style)` now), an anchor, a note, and its lifetime as data.
- `Canvas` (OrbKit, pure, tested like `CallMachine`): `reduce(state, event)` over `add`, `remove(id)`, `clear`,
  `youSpoke`, `orbStopped(at)`, `tick(now)`. A mark lasts until you next talk, or 6 s after orb stops speaking; a new
  call clears the canvas. Several marks can be on screen at once. `focus` is the newest one: the companion goes there.
- Every op carries an `opId`: a retried RPC never draws twice.

## 5. Rendering
`CanvasRenderer` (OrbApp), one per screen overlay window, shows the annotations anchored on its display and diffs
them by id: a new id gets a layer that animates in, a removed id animates out.
- `RoughMarkLayer`: the hand-drawn strokes of `Rough` (built, tested: seeded, double-stroked lines, a loose loop for a
  circle), one `CAShapeLayer` per stroke, `strokeEnd` 0 → 1 one stroke after another, on the GPU.
- Diagrams (SwiftUI) and 3D (SceneKit or RealityKit) will be further layers in the same overlay with the same anchors,
  lifetimes and focus. The layer protocol is extracted when the second layer exists, not before.

## 6. Tools (what Gemini Live sees)
| Tool | Arguments | Answer |
|---|---|---|
| `read_screen()` | — | as today (the front app, window, selection, document, the screen's text) |
| `mark(target, kind, style, note)` | `target`: for `text`, the words copied from `read_screen`; else a short description ("the blue robot", "the Export button"). `kind`: text, ui, visual. `style`: underline, box, marker, circle | `{"found": true, "by": "sight", "id": "m3", "matches": 1, "confidence": 0.8}` or `{"found": false, "why": …}` |
| `clear_marks()` | — | `{"cleared": n}` |

`highlight_text` and `point_at` go: one tool, one idea. Gemini decides what and how; the app decides where.

**Wire format:** one RPC method `orb.canvas` with versioned JSON, `{"v": 1, "op": "mark", "opId": …, "target": …,
"kind": …, "style": …, "note": …}`. The schema lives once in each language (`CanvasOp` in OrbKit, `canvas_op()` in
Python), and a contract test on each side decodes the same fixture file (`fixtures/canvas-ops.json`). RPC answers
are small; a later op with a large body (a diagram, a 3D scene) goes on a LiveKit byte stream (topic `orb.canvas`)
with the same envelope, because an RPC is limited to 15 KB.

## 7. What is removed
`point_at`, `highlight_text`, Gemini's x/y, `near_text`, `ScreenMap.object`, Vision saliency, the ink scan and the
colour names (written during the live tests, never shipped), `PointTarget`.

## 8. Code
| Where | What |
|---|---|
| `orb_agent/ground.py` (new), `server.py` | `POST /v1/ground`: validate (JPEG ≤ 2 MB, query ≤ 200 chars), call the model, parse and check `box_2d` |
| `orb_voice/screen_tools.py` | `read_screen`, `mark`, `clear_marks`; one RPC method `orb.canvas` |
| `orb_core/gemini.py` | `SCREEN_RULES` for `mark` |
| `OrbKit/Screen/` | `Frame`, `Target`, `Region`, `Grounder`, `Grounding`, `TextGrounder` (logic), `CanvasOp` |
| `OrbKit/Canvas/` (new) | `Annotation`, `Canvas` (reducer), `Rough` (moved), `Flight` (moved) |
| `OrbKit/Agent/` | `AgentAPI.ground(image:query:)` |
| `OrbApp/` | `ScreenStream`, `ScreenVision` (OCR), `ElementGrounder`, `SightGrounder` (JPEG of a frame + API), `CanvasRenderer`, `RoughMarkLayer` |

## 9. Tests
- **Contract:** `fixtures/canvas-ops.json` decodes the same in Swift and Python (ops and answers).
- **Grounding (Swift, fakes):** routing by kind and the fall-through order; ambiguity (two matches → `matches: 2`,
  the one nearer the pointer first); a sight answer that is not found, outside the frame, too big, or over orb's
  island is refused; a budget overrun is "not found in time".
- **Element matching (Swift, pure):** exact > prefix > contains ("Save" is not "Save As…"), hidden elements skipped.
- **Canvas (Swift):** add, remove, clear, the same `opId` twice draws once, `youSpoke` clears, `orbStopped` + 6 s
  expires, focus is the newest, a new call clears.
- **Geometry (Swift):** points and pixels at scale 1 and 2, a display left of the main one.
- **Rough (Swift, built):** bounds, seeds, loops.
- **`/v1/ground` (Python, fake model, built):** answer shapes, impossible boxes, empty answers, bad input, model failure.
- **Tools (Python):** each tool's payload and its failure sentences.
- **Live (test voice):** box a heading, underline a phrase, circle "the blue robot" (by sight), mark a Preview toolbar
  button (by ui), ask for a zoom button that is not there (found: false), clear; the time of each.

## 10. Tickets
| # | Ticket | Done when |
|---|---|---|
| CV-0 | This doc, decision 0022, the review folded in | committed |
| CV-1 | `/v1/ground` in the agent service | tests green (built) |
| CV-2 | Wire format + contract fixtures; tools `mark`, `clear_marks`; `SCREEN_RULES` | Python tests green |
| CV-3 | OrbKit: `Target`, `Anchor`, `Region`, `Grounding` (routing, ambiguity, budgets), `Canvas`, `CanvasOp`; remove `PointTarget` and the heuristics | Swift tests green |
| CV-4 | OrbApp grounders: text (OCR cache by frame), element (AX), sight (JPEG + API) | Swift tests green, app builds |
| CV-5 | OrbApp: `CanvasRenderer` with `RoughMarkLayer`, companion focus, AppModel wiring | app builds |
| CV-6 | Live test, docs, PR, merge into staging | PR merged |

## 11. Live results (2026-11-24, the test voice on a two-column paper in Preview)
| Asked | Grounded by | Time | Result |
|---|---|---|---|
| box "2 Related Work" | text | 1.4 s | right |
| underline "fast and intuitive Talker agent" | text | 1.6 s | right |
| marker on a sentence over two lines | text | 1.4 s | both lines, left column only (after `ReadingOrder`; before it, the columns interleaved and the text match failed) |
| circle "the blue robot" | sight | 2.6 s | a loop around the blue robot, confidence 0.98 |
| circle "the zoom-in button" (not shown) | sight, crop check | — | not found, and Gemini said so once (before the no-retry rule, it tried four wordings) |
