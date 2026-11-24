# orb for Mac: low-level design

## Modules
| Module | Holds | Imports |
|---|---|---|
| `OrbKit` | the agent service client (`AgentAPI`, `AgentClient`), the screen (`ScreenService`, `ScreenRPC`, `ScreenReading`, `TextMatch`, `ScreenMap`, `ScreenChoice`, `Flight`, `Extractor`), the voice interface (`VoiceTransport`, `VoiceEvent`, `Captions`, `BenchEvent`, `AudioLevels`), the call machine (`CallMachine`), the inspector's data (`EngineView`, `TurnLog`) and `AppModel` | Foundation, AppKit (document text), PDFKit, AVFoundation (microphone permission) |
| `OrbVoice` | `LiveKitTransport`: the room, the muted microphone, the agent state, text streams, data packets, levels | OrbKit, LiveKit |
| `OrbUI` | `Theme` (every token), `Logo`, `OrbView`, `IslandView`, the panel, captions, the senses row, `CompanionView`, `InspectorView`, `SettingsView` | OrbKit, SwiftUI |
| `OrbApp` | `Shell` (the model, the menu bar item, the shortcuts, the Settings and Inspector windows), `MacScreen` (ScreenCaptureKit, Vision, Accessibility), `IslandWindow`, `CompanionOverlay`, `OptionTap`, `ShortcutRecorder` | all of the above, KeyboardShortcuts, ScreenCaptureKit, Vision |
| `OrbProbe` | a command-line call for testing the voice path | OrbKit, OrbVoice |

`OrbKit` has no SwiftUI and no WebRTC, so its tests run fast with fakes. `OrbUI` never sees LiveKit.

## The call
`CallMachine.reduce(state, event) -> (state, effects)` is pure; `AppModel.run` performs the effects (tasks, timers,
the transport). Phases: idle → preparing (microphone permission, voice status, session, config, token) → connecting →
live. Hold to talk: key down opens the microphone; key up starts a 300 ms tail. A press during preparing or connecting
opens the microphone at the join only if the key is still held. The call ends after `idleMinutes` (3) with no speech,
on hang up, or when the room disconnects.

**Hands-free:** `toggleHandsFree` (a double tap of ⌥) starts a call with the microphone open
and no key held, or opens and closes the microphone of a live call. The key's release does not close a hands-free
microphone; the model's turn detection ends each turn. A silent hands-free call ends after the idle timeout too.
`DoubleTap` (pure) counts two taps of ⌥ alone, each 0.3 s or shorter, the second within 0.4 s, with no other key
between; `OptionTap` (the app) feeds it from global and local `flagsChanged`/`keyDown` monitors, which macOS delivers
only with the Accessibility permission (asked once; until then the panel says why).

**The end of a turn:** a muted track sends no audio, so Gemini's turn detection (700 ms of silence) would wait for
ever after a release. `LiveKitTransport.setMicrophone(false)` first sets the voice-processing input to zeros
(`AudioManager.isMicrophoneMuted`) for 1.2 s, so the model sees silence and answers, then mutes the track.
Measured 2026-11-24 with a synthetic ⌥ Space hold released at the last word: orb began to speak 1.9 s after the
release (before: no answer).

**Logging:** `Logger` subsystem `ai.anvesx.orb` (categories `call` and `keys`): every event with the phase, the mic and
the effects; your words only as private. `log stream --level debug --predicate 'subsystem == "ai.anvesx.orb"'`.

**Mood:** "listening" only while the microphone is open; a live call with a closed microphone is "ready", whatever
the agent's own state says.

| Warning | When |
|---|---|
| "Voice is off…" | `/v1/voice/status` is null |
| "The voice server (LiveKit) / voice worker is not running…" | the status says so |
| "Gemini Live needs GOOGLE_API_KEY…" | `/v1/models` says the key is missing |
| "The voice agent did not join…" | no agent 15 s after the join (cleared when it joins) |
| "orb can't use the microphone…" | permission denied |
| the service's own error text | any other failed request |

**A forgotten session:** before each call the app saves the config; a 404 means the service restarted, so the app
creates the session again (otherwise the worker would open a bare one).

## Screen
The design is [screen-canvas.md](../../docs/design/screen-canvas.md). At the join, `AppModel.shareScreen` serves the
worker's two RPCs (`orb.screen.read`, and `orb.canvas` for the canvas wire format in `contracts/canvas-ops.json`;
both answered even with the screen off, so Gemini hears why) and, with the setting on and Screen Recording allowed,
starts the screen track.
- **Capture:** `ScreenStream` keeps one ScreenCaptureKit stream of the display under the pointer for the whole call
  (2 fps at most, full pixel size, orb's windows excluded) and its latest complete frame (`ScreenFrame`, with an id).
  A stream keeps macOS's capture indicator steady; a screenshot a second made it blink. The 1 fps video track
  (`LiveKitTransport.startScreen`, a `BufferCapturer`) and the OCR both read that frame.
- **Read:** `MacScreen.read` = `FrontApp.read` (Accessibility: app, window, selection never from a secure field, the
  `AXDocument` file through `Extractor`, cached by file and date) and Vision's OCR of the frame, cached by frame id.
  `ReadingOrder` puts the lines column by column, so text of two-column pages comes in reading order.
  `ScreenReading.budgeted` keeps the answer under 12,000 UTF-8 bytes.
- **Ground:** `Grounding` (OrbKit) routes a `Target` by kind (`text` → text, sight; `ui` → element, text, sight;
  `visual` → sight), each grounder within its budget (2 s, 0.2 s, 6 s), ranks candidates (score, then nearness to
  the pointer), counts ties as `matches`, and refuses boxes outside the frame, over 60 % of it, or over orb's island.
  `TextGrounder`: `TextMatch.all` + `ScreenMap.passage`. `ElementGrounder`: the focused window's Accessibility tree,
  `ElementMatch` (exact > prefix > contains). `SightGrounder`: a 1280 px JPEG of the frame to `POST /v1/ground`; the
  service checks an answer on its crop when it is unsure or the target is a control.
- **Canvas:** `Canvas.reduce` (OrbKit) keeps the annotations: an op id draws once; marks go when you talk, 6 s after
  orb stops speaking, or 12 s after a mark orb never spoke about; a call's end clears them. `AppModel.canvas` holds it.

## Companion
One transparent, click-through `NSPanel` per screen (all Spaces, full-screen auxiliary, status-bar level), rebuilt
when the screens change. The panels never move: on each display frame (`NSView.displayLink`, the screen's own rate),
the panel of the screen under the pointer moves its `CompanionView` to 14 pt right of and 16 pt under
`NSEvent.mouseLocation` (to the left near the right edge), with implicit animations off. There is no spring, so it
trails the hardware cursor by one to two frames. The display links run only while a call is on and the companion is
switched on (observation tracking on `AppModel`); otherwise they are paused and the panels hidden.
When the canvas's focus changes, the companion follows a `Flight`: a quadratic curve that arcs above the straight line
(0.5 s there, 0.35 s back to the pointer, ease in and out), as a pure function of time so every screen's display link
asks it. Each screen's `CanvasRenderer` draws the annotations anchored on its display, diffed by id; `RoughMarkLayer`
draws a mark's `Rough` strokes (seeded, doubled, loose loops), one `CAShapeLayer` each, a pen's `strokeEnd` 0 → 1 one
stroke after another. The companion's bubble shows the mark's note.
`CompanionView`: a 28 pt orb with a level ring, and a bubble with orb's words while it speaks (your interim words while
you speak). Settings switch the companion and the bubble.

## Inspector
While the inspector window is open, `AppModel.inspect(true)` polls `GET /v1/sessions/{id}?since=version` every 0.7 s
(the web page's rate on this machine) and decodes `EngineView`: messages, turns (decision, check, timing), stage,
scores, board, need, last Jev call, tokens and cost. Every field is optional. A 404 forgets the session, so the next
call makes it again. `TurnLog` is the web page's latency table, built from the worker's `orb.bench` events
(`eou_metrics`, `agent_read`, `agent_decision`, `llm_metrics`, `tts_metrics`, `turn_latency`) and reset at each call.

## Settings
`Settings` (UserDefaults, one JSON value): the service address, the Gemini model and voice, orb personas, Google
Search (`webSearch`, a new key so an old saved "off" does not hide it; on by default), the screen (on by default), the
idle minutes, the double tap, the companion and its bubble. The config goes to the session before each call, so a change
applies from the next call. The talk shortcut is stored by KeyboardShortcuts; `ShortcutRecorder` takes the next key
press with a modifier (Esc cancels).

## Audio levels
`Meter` (an `AudioRenderer`) computes each buffer's RMS on the audio thread, maps −50…−10 dB to 0…1 and stores it in
`AudioLevels` (a lock). The orb reads it each frame and smooths it (`LevelSmoother`: attack 0.5, release 0.15).

## Bundle
`scripts/build_app.sh` copies the release binary, `LiveKitWebRTC.framework` and `RustLiveKitFFI.framework` (with an
rpath to `Contents/Frameworks`), the SwiftPM resource bundles, `Info.plist` and the icon (`scripts/make_icon.swift`),
then signs the frameworks and the app. SwiftPM's resource accessor looks for bundles next to the app, not in
`Contents/Resources`; only KeyboardShortcuts' recorder strings use one, so the app does not use its recorder view.

## Live tests without a person
`ORB_TEST_VOICE=<folder>` (for example `open --env ORB_TEST_VOICE=/tmp/voice-in build/orb.app`) installs `TestVoice`,
a LiveKit `capturePostProcessingDelegate`: each audio file put in the folder replaces the microphone's samples after
echo cancellation, so Gemini hears it exactly as it hears a person. `say -o q.wav --data-format=LEI16@24000 "…"`
writes one. Playing it through the speakers does not work: echo cancellation removes what the Mac itself plays.
With `ORB_LOG_TEXT=1` the worker logs each screen tool's payload and answer.

## Tests (`swift test`)
| Suite | Covers |
|---|---|
| `CallMachineTests` | press held or released through the join, the tail, the idle timeout, the agent-join warning, failures, new session, mic denied, late events, reconnect |
| `ExtractorTests` | Markdown, code, PDF with and without text, DOCX and RTF |
| `GroundingTests`, `GroundingPartsTests`, `CanvasReducerTests`, `CanvasContractTests`, `RoughTests`, `ReadingOrderTests` | routing and fall-through, ties and the pointer, refused sight boxes, budgets; all occurrences, control names, box and Accessibility coordinates; the canvas's lifetimes and op ids; the shared wire fixture; hand-drawn strokes; two-column reading order |
| `TextMatchTests`, `ScreenMapTests`, `ScreenReadingTests`, `FlightTests`, `ScreenSettingsTests` | quotes across lines, misread letters, Devanagari; Vision and Gemini coordinates on two displays; the RPC byte budget with Hindi and escapes; bad show requests; the flight's arc; old settings |
| `AgentClientTests` | bodies and paths against a stub `URLProtocol`, the service's error text, 404, no answer, unchanged state |
| `VoiceTests` | agent state aliases, caption segment rules and polish, bench event decoding, the level smoother |
| `InspectorTests` | `EngineView` on a real state of the service (`Fixtures/session-state.json`, one note and one reply), a state without engine fields, the turn log's rows |
| `HandsFreeTests`, `DoubleTapTests` | hands-free start, stop, key presses that leave it open, the idle timeout, a toggle while connecting; quick, slow and interrupted taps |
| `AppModelTests` | a press makes a session and opens the mic; a forgotten session is made again; a blocked voice says why; a call shares the screen and answers read and show; the screen off or not allowed; the pointer clears when you talk but not on orb's echo |
