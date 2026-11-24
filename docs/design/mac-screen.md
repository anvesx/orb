# orb sees your screen: talk about what you're looking at

Status: in progress · Branch: `feat/mac-screen` · Date: 2026-11-24 · Decision: 0021

## 1. Goal
You hold ⌥ Space (or double-tap ⌥) while looking at anything: a PDF, a web page, code, a settings window, a chart.
You say "what does this paragraph mean?" or "where do I change the export format?", and orb:
- **sees** the screen you are on, live, while you talk;
- **reads** its exact words when it needs them (the text on the screen, your selected text, and the whole document
  that is open in the front app);
- **shows** you as it talks: the companion flies to the words or the button it means, and highlights the words;
- **searches** Google for facts that change, then says where the fact comes from.

No files to add, no context to pick: what you look at is the context. The voice stays Gemini Live speech to speech
(decision 0019); the brain (Claude) comes later and plugs into the same tools (section 9).

The panel gets simpler at the same time: what is not needed to talk goes (section 6).

## 2. What changes, in one picture
```
 Mac app (orb)                                LiveKit room                 voice worker (Gemini Live)
 ─────────────                                ────────────                 ──────────────────────────
 mic track ─────────────────────────────────▶ audio ─────────────────────▶ Gemini hears
 screen track (the display under the pointer,  video ─────────────────────▶ Gemini sees (1 frame/s while you
   orb's own windows left out, 2 fps)                                        talk, 1 per 3 s otherwise)
                                                                            Gemini calls a tool:
 RPC "orb.screen.read"  ◀──────────────────── RPC ◀──────────────────────── read_screen()
   AX: app, window, selection, document                                     → exact text, back to Gemini
   OCR (Vision) of the display
 RPC "orb.screen.show"  ◀──────────────────── RPC ◀──────────────────────── highlight_text(text, note)
   finds the words by OCR, the companion                                    point_at(x, y, label)
   flies there, highlights them                                             → found / not found
                                                                            google_search (Gemini's own tool)
```
The worker never sees pixels it did not get as video, and never reads files: every read happens in the app, on the
Mac, and only during a call.

## 3. Seeing: the screen as a video track
- **How:** the app takes a ScreenCaptureKit screenshot (`SCScreenshotManager.captureSampleBuffer`, macOS 14) of one
  display every second and feeds it into its own video track (LiveKit `BufferCapturer`, source `screenShareVideo`,
  VP8, at most 2 fps and 2.5 Mbit/s, no simulcast). Not LiveKit's built-in screen share, for three reasons found in
  review: it shares only the main display, it can't switch display without a new track, and ScreenCaptureKit sends no
  frames while the screen does not change, so Gemini would get one old frame of a still PDF. A steady 1 frame/s fixes
  all three.
- **Which display:** the one under the pointer, checked before each screenshot (pure `ScreenChoice`, tested). Moving
  the pointer to another display moves the share within a second, on the same track.
- **What is left out:** orb's own windows (island, panel, companion), by an `SCContentFilter` that excludes this app,
  so Gemini never reads its own captions back. The pointer is drawn, so "this" can mean what you point at.
- **Size:** the longest side at most 1920 px. LiveKit's agent samples the track for Gemini at 1 frame/s while you speak
  and one per 3 s otherwise (`VoiceActivityVideoSampler`), as JPEG at 1024 px (the plugin's default).
- **Permission:** Screen Recording. The first call with the screen on asks (`CGRequestScreenCaptureAccess`). Without it
  the call still works (voice only), and the panel shows one row, "orb can't see your screen · Allow", which opens the
  Settings pane. Each call tries again, so a grant works without a relaunch where macOS allows it.
- **When:** only during a call. The track is published at the join and removed at hang-up. The setting "Let orb see
  my screen" (default on) turns it off.
- **Worker:** a session config with `gemini_screen: true` starts the agent with `RoomOptions(video_input=True)` (the
  first participant that is not an agent, the app, is linked), the screen tools, and Gemini tool calls that block
  (`tool_behavior=BLOCKING`): Gemini waits for `read_screen`'s text before it speaks, instead of guessing.

At 1024 px a frame is enough to see what is on the screen and read big text, not to quote small text exactly. The
tool `read_screen` closes that gap.

## 4. Reading: `read_screen`
A Gemini function tool in the worker; it calls the app by LiveKit RPC (`orb.screen.read`, 4 s timeout). The app answers
JSON, at most 12 000 UTF-8 bytes (a LiveKit RPC payload is limited to 15 KB on the v1 wire; error 1504 past it):
```json
{ "app": "Preview", "window": "pricing.pdf – page 3 of 12",
  "selection": "the words the person selected, if any",
  "document": { "name": "pricing.pdf", "kind": "pdf", "text": "…the open file's text, cut to fit…",
                "cut": true },
  "screen_text": "the display's text by OCR, in reading order, one line per line" }
```
- **app, window:** `NSWorkspace.frontmostApplication` and the focused window's `AXTitle` (Accessibility, which orb
  already has for the double tap).
- **selection:** the focused element's `AXSelectedText`, never from a secure (password) field.
- **document:** the focused window's `AXDocument` (a file URL that Preview, TextEdit, Xcode, Pages and most document
  apps set). The text comes from the existing `Extractor` (PDF, Markdown, text, code, Word, RTF). Missing for a browser
  page; the screen text covers that.
- **screen_text:** Vision `VNRecognizeTextRequest` (accurate, language correction on) on a fresh screenshot of the
  shared display (the same capture as section 3), orb's windows left out. About 0.3 to 0.6 s on Apple silicon. The
  display's frame and scale are kept with the result, so a later show maps to where the words were.
- `ScreenReading.budgeted()` cuts each part to its share of the 12 000 bytes (selection 1 500, screen text 5 000, the
  document the rest), so one huge document can't crowd out the screen text. `cut: true` tells Gemini there is more.
- With no Screen Recording permission: `screen_text` is missing and `"note"` says why. With no Accessibility: app only.

## 5. Showing: `highlight_text` and `point_at`
Two function tools; both call `orb.screen.show` (4 s timeout) and return `{"found": true}` or `{"found": false, "why": "…"}`, so
Gemini can say "I can't find that on your screen" instead of pointing at nothing.
- **`highlight_text(text, note)`:** `text` is a few words exactly as they appear on screen (one passage). The app OCRs
  the display, finds the passage (`TextMatch`: case, punctuation and spaces ignored; it may run over line breaks; the
  closest match wins when it is at least 0.8 similar), and gets each matched line's box from Vision
  (`VNRecognizedText.boundingBox(for:)`). Exact, unlike coordinates guessed from a 1024 px frame.
- **`point_at(x, y, label)`:** for what is not text (an icon, a slider, a part of a chart). `x` and `y` are 0 to 1000
  over the shared screen, left to right and top to bottom, the convention Gemini is trained on.
- **What you see:** the companion leaves the pointer, flies to the target along a curved path (0.5 s, ease in and out),
  and stays next to it with a bubble that holds `note` or `label`. A highlight sweeps over the matched words (rounded
  boxes in the state colour, soft glow, fill drawn left to right in 0.35 s). A new show replaces the old one. It lasts
  until you next talk, or 6 s after orb stops speaking; then the companion flies back to the pointer.
- **Coordinates:** pure `ScreenMap` (OrbKit) turns Vision boxes (normalized, origin bottom left) and Gemini points
  (0–1000, origin top left) into global AppKit points on the right display. Tested with two displays side by side.

## 6. The panel, simpler
Goes: the Context section and **Add** (files and folders), the service dot, the Inspector button (it stays in the
menu bar menu, ⌘I), New session. The FilesProvider, SourcePack and context chips go with them; the service API for
sources stays (decision 0020: a later context or the brain can use it).

```
 ╭──────────────────────────────────────────╮
 │ ●orb                                  ⚙ │   header: logo, settings
 │                                          │
 │                  ◉                       │   the orb, 120 pt, live colour
 │              Listening                   │   the state in words
 │                                          │
 │  YOU  what does this paragraph mean       │   captions
 │  ORB  It says the beta starts on…         │
 │                                          │
 │  ◎ Sees Preview · pricing.pdf   🔍 Search │   one quiet row: what orb can use now
 │                                          │
 │  [ Hold ⌥ Space to talk ]        Hang up │
 ╰──────────────────────────────────────────╯
```
- **The "can use" row:** `◎ Sees your screen` before a call (or `◎ Sees Preview · pricing.pdf` during one, from the
  last read), `Screen off` when the setting is off, `Allow screen access` (a button) without the permission, and
  `Search` when Google Search is on. Small, grey, one line.
- **Settings** gain "Let orb see my screen"; "Google Search" becomes on by default (a new key, so an old saved "off"
  does not hide it).
- Errors still come as a warning row when you call (the service, the worker, the key).

## 7. Gemini's instructions (added when screen is on)
```
You can see the person's screen: frames of it arrive while they talk. "This", "here" and "that" mean what is on their
screen, near their pointer. When you need exact words (a paragraph, a number, a line of code, a name), call read_screen
first and use its text; it also has the whole document open in the front app. To show something while you explain,
call highlight_text with a few words exactly as they appear on the screen, or point_at for something that is not
text. Show first, then talk about it. Never say coordinates out loud. When a tool says it found nothing, say so
briefly. When the screen is not shared, say that you can't see it and that they can allow it in orb.
```
`VOICE_RULES` drops its file sentence: there are no files in a call any more.

## 8. Code
| Where | What |
|---|---|
| `orb_agent/server.py` | `SessionConfig.gemini_screen` |
| `orb_core/gemini.py` | `SCREEN_RULES`, in `with_tool_rules`; `VOICE_RULES` without files |
| `orb_voice/screen_tools.py` (new) | `ScreenTools(room)`: `read_screen`, `highlight_text`, `point_at` as LiveKit function tools, RPC to the app, errors as tool results ("the app did not answer") |
| `orb_voice/main.py` | `gemini_call`: screen tools and `RoomOptions(video_input=True)` when `gemini_screen` |
| `OrbKit/Screen/` (new) | `ScreenReading` (+ `budgeted`), `ShowRequest`, `ScreenMap`, `TextMatch`, `ScreenChoice`, `ScreenRPC` (decode, call the `ScreenService`, encode), protocol `ScreenService` |
| `OrbKit/Model/AppModel.swift` | `screen: ScreenService?`, `pointer: PointTarget?`, `seeing: String?`; the share starts with the mic; files and context removed |
| `OrbKit/Voice/VoiceTransport.swift` | `shareScreen(display:)`, `serve(method:handler:)` |
| `OrbVoice/LiveKitTransport.swift` | screen track publish, unpublish, switch; RPC registration |
| `OrbApp/ScreenService.swift` (new) | ScreenCaptureKit screenshot, Vision OCR, AX reads, permission |
| `OrbUI/CompanionView`, `OrbApp/CompanionOverlay` | fly to a target, the highlight layer |
| `OrbUI/PanelView`, `SettingsView` | section 6 |

## 9. Later (not in this work)
- **The brain (Claude):** the same three tools become Claude tools; Gemini only speaks.
- **Acting:** click, type, scroll for you ("computer use"), with a confirm step.
- **More than one display at once**, and a window rather than a whole display.
- **MCP connections** (calendar, mail, files) as more tools in the same worker.

## 10. Risks
- **Gemini calls the tools too rarely or too often.** The rules say when; the live test counts calls on 10 questions.
- **OCR misses small or styled text.** `point_at` is the fallback; the result says "not found" rather than guess.
- **Privacy:** the screen goes to Google during a call, as the voice does. The share starts only in a call, the
  panel shows "Sees …" while it does, and one setting turns it off. Only the open document's text is read, only when
  Gemini asks, and only in a call.
- **Screen Recording permission resets** when the app's signature changes (ad hoc builds). The build keeps signing
  with a stable development identity when there is one.

## 11. Tests
**Unit (no network, no screen):**
- Swift `TextMatch`: exact, case and punctuation, across two lines, closest match at ≥ 0.8, nothing below it, a
  repeated phrase picks the first on screen.
- Swift `ScreenMap`: Vision box → global rect on the main display and on a display to the left; Gemini 0–1000 point;
  clamping.
- Swift `ScreenChoice`: the display under the pointer, a pointer between displays.
- Swift `ScreenReading.budgeted`: each limit in UTF-8 bytes (Hindi text is 3 bytes a letter), the total, `cut` set.
- Swift `ScreenRPC`: read → JSON under 12 000 bytes; show text found and not found; a bad payload is an error result,
  never a crash.
- Swift `ScreenMap`: a Retina display (scale 2) and a display above the main one.
- Swift `AppModel`: the share starts when the mic first opens with screen on, never with it off, stops at hang-up;
  the RPC handlers are served after the join; `pointer` is set by a show and cleared when you talk.
- Swift `Settings`: the new keys decode with their defaults from an old saved value.
- Python `screen_tools`: each tool sends the right RPC method and payload to the app's identity; a timeout, a too
  large answer (1504) or an app error becomes a short sentence for Gemini, not an exception; no app participant → "the
  screen is not shared"; screen on → tool calls block.
- Python `gemini`: `SCREEN_RULES` only with `gemini_screen`; the server accepts `gemini_screen`.
- Python `main.gemini_call`: screen on → video input on and the three tools; off → neither.

**Live (by me, then by you):** a still PDF (frames keep coming), the pointer moved to a second display, then open a PDF in Preview, call, ask "what's on my screen", "explain the second paragraph"
(expect `read_screen`, then `highlight_text` on it), "where is the zoom button" (`point_at`), "what's the latest
version of Swift" (search). Check the log for tool calls and their time, and watch the companion.

## 12. Tickets (one PR, `feat/mac-screen` → staging)
| # | Ticket | Done when |
|---|---|---|
| SC-0 | This doc, decision 0021 | committed |
| SC-1 | Service and worker: `gemini_screen`, `SCREEN_RULES`, `screen_tools.py`, video input in `gemini_call` | Python tests green |
| SC-2 | OrbKit: `Screen/` (reading, map, match, choice, RPC), transport protocol, AppModel share and pointer; files removed | Swift tests green |
| SC-3 | OrbVoice and OrbApp: screen track, RPC serve, ScreenService (ScreenCaptureKit, Vision, AX), permission | app builds and runs |
| SC-4 | Companion: fly to a target, highlight layer, bubble | seen live |
| SC-5 | Panel and Settings (section 6); Accessibility asked only when the double tap is on | seen live |
| SC-6 | Live test (section 11), docs (README, LLD, mac-app.md), PR, merge into staging | PR merged |
