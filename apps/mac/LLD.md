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
At the join, `AppModel.shareScreen` serves the worker's two RPCs (`orb.screen.read`, `orb.screen.show`, answered even
with the screen off, so Gemini hears why) and, with the setting on and Screen Recording allowed, starts the screen
track: `LiveKitTransport.startScreen` makes a `BufferCapturer` track (`screenShareVideo`, 2 fps, 2.5 Mbit/s, no
simulcast) and publishes it in the background, because a publish waits for the first frame's size. `MacScreen.feed`
sends it a `SCScreenshotManager.captureSampleBuffer` of the display under the pointer (`ScreenChoice`) every second,
longest side 1920 px, the pointer drawn and orb's own windows left out (`SCContentFilter` excluding this process).
- **Read:** `MacScreen.read` = the front app, its focused window's `AXTitle`, `AXSelectedText` (never from an
  `AXSecureTextField`), the window's `AXDocument` file through `Extractor`, and Vision's accurate OCR of a full
  resolution screenshot (lines in reading order). `ScreenReading.budgeted` keeps the JSON under 12,000 UTF-8 bytes
  (an RPC answer is at most 15 KB): selection 1,500, screen text 5,000, the document the rest, shrunk again if JSON
  escapes grow it.
- **Show:** `TextMatch.find` on the last OCR (at most 3 s old, else a fresh one) matches the quote on Unicode scalars,
  case, punctuation and line breaks ignored, exact first, else the closest run of words at ≥ 0.8 similarity.
  `VNRecognizedText.boundingBox(for:)` gives each line's box; `ScreenMap` turns it (and Gemini's 0–1000 points) into
  global AppKit points on the display it was read on. The answer is `{"found": true}` or why not.
- **Pointer:** `AppModel.pointer` holds the target. It clears when you start talking (not on orb's echo while it
  speaks), 6 s after orb stops speaking, 10 s after a show at most, and at hang-up.

## Companion
One transparent, click-through `NSPanel` per screen (all Spaces, full-screen auxiliary, status-bar level), rebuilt
when the screens change. The panels never move: on each display frame (`NSView.displayLink`, the screen's own rate),
the panel of the screen under the pointer moves its `CompanionView` to 14 pt right of and 16 pt under
`NSEvent.mouseLocation` (to the left near the right edge), with implicit animations off. There is no spring, so it
trails the hardware cursor by one to two frames. The display links run only while a call is on and the companion is
switched on (observation tracking on `AppModel`); otherwise they are paused and the panels hidden.
When `AppModel.pointer` changes, the companion follows a `Flight`: a quadratic curve that arcs above the straight line
(0.5 s there, 0.35 s back to the pointer, ease in and out), as a pure function of time so every screen's display link
asks it. Each screen's panel draws a highlighter layer over the target's rects on that screen (amber, rounded, a soft
glow), swept in left to right line by line with a mask, just before the companion lands. The companion's bubble then
shows the target's label.
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

## Tests (`swift test`)
| Suite | Covers |
|---|---|
| `CallMachineTests` | press held or released through the join, the tail, the idle timeout, the agent-join warning, failures, new session, mic denied, late events, reconnect |
| `ExtractorTests` | Markdown, code, PDF with and without text, DOCX and RTF |
| `TextMatchTests`, `ScreenMapTests`, `ScreenReadingTests`, `FlightTests`, `ScreenSettingsTests` | quotes across lines, misread letters, Devanagari; Vision and Gemini coordinates on two displays; the RPC byte budget with Hindi and escapes; bad show requests; the flight's arc; old settings |
| `AgentClientTests` | bodies and paths against a stub `URLProtocol`, the service's error text, 404, no answer, unchanged state |
| `VoiceTests` | agent state aliases, caption segment rules and polish, bench event decoding, the level smoother |
| `InspectorTests` | `EngineView` on a real state of the service (`Fixtures/session-state.json`, one note and one reply), a state without engine fields, the turn log's rows |
| `HandsFreeTests`, `DoubleTapTests` | hands-free start, stop, key presses that leave it open, the idle timeout, a toggle while connecting; quick, slow and interrupted taps |
| `AppModelTests` | a press makes a session and opens the mic; a forgotten session is made again; a blocked voice says why; a call shares the screen and answers read and show; the screen off or not allowed; the pointer clears when you talk but not on orb's echo |
