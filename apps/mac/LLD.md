# orb for Mac: low-level design

## Modules
| Module | Holds | Imports |
|---|---|---|
| `OrbKit` | the agent service client (`AgentAPI`, `AgentClient`), context (`ContextProvider`, `FilesProvider`, `Extractor`, `SourcePack`), the voice interface (`VoiceTransport`, `VoiceEvent`, `Captions`, `BenchEvent`, `AudioLevels`), the call machine (`CallMachine`), the inspector's data (`EngineView`, `TurnLog`) and `AppModel` | Foundation, AppKit (document text), PDFKit, AVFoundation (microphone permission) |
| `OrbVoice` | `LiveKitTransport`: the room, the muted microphone, the agent state, text streams, data packets, levels | OrbKit, LiveKit |
| `OrbUI` | `Theme` (every token), `Logo`, `OrbView`, `IslandView`, the panel, captions, context chips, `CompanionView`, `InspectorView`, `SettingsView` | OrbKit, SwiftUI |
| `OrbApp` | `Shell` (the model, the menu bar item, the shortcuts, the file picker, the Settings and Inspector windows), `IslandWindow`, `CompanionOverlay`, `ShortcutRecorder` | all of the above, KeyboardShortcuts |
| `OrbProbe` | a command-line call for testing the voice path | OrbKit, OrbVoice |

`OrbKit` has no SwiftUI and no WebRTC, so its tests run fast with fakes. `OrbUI` never sees LiveKit.

## The call
`CallMachine.reduce(state, event) -> (state, effects)` is pure; `AppModel.run` performs the effects (tasks, timers,
the transport). Phases: idle → preparing (microphone permission, voice status, session, config, token) → connecting →
live. Hold to talk: key down opens the microphone; key up starts a 300 ms tail. A press during preparing or connecting
opens the microphone at the join only if the key is still held. The call ends after `idleMinutes` (3) with no speech,
on hang up, on a new session or a change of context, or when the room disconnects.

**Hands-free:** `toggleHandsFree` (a double tap of ⌥, or the panel's button) starts a call with the microphone open
and no key held, or opens and closes the microphone of a live call. The key's release does not close a hands-free
microphone; the model's turn detection ends each turn. A silent hands-free call ends after the idle timeout too.
`DoubleTap` (pure) counts two taps of ⌥ alone, each 0.3 s or shorter, the second within 0.4 s, with no other key
between; `OptionTap` (the app) feeds it from global and local `flagsChanged`/`keyDown` monitors, which macOS delivers
only with the Accessibility permission (asked once; until then the panel says why).

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
creates the session again with the context's sources (otherwise the worker would open a bare one).

## Context
A `ContextProvider` offers `suggestions()` and turns items into `Source`s (`{name, kind, text}`). The files provider:
a folder gives its readable files newest first (no subfolders, no hidden files, no packages); extraction is UTF-8 text
(first 2 MB), PDFKit page text with `--- page N ---` marks, and `NSAttributedString` for RTF and DOCX. A file with no
text (a scan) is left out. `SourcePack.fit` keeps the service's request limits (100 files, 150,000 characters each,
500,000 in all); the service packs its prompt within its own budget and answers `used` and `whole` for each file.

## Companion
One transparent, click-through `NSPanel` per screen (all Spaces, full-screen auxiliary, status-bar level), rebuilt
when the screens change. The panels never move: on each display frame (`NSView.displayLink`, the screen's own rate),
the panel of the screen under the pointer moves its `CompanionView` to 14 pt right of and 16 pt under
`NSEvent.mouseLocation` (to the left near the right edge), with implicit animations off. There is no spring, so it
trails the hardware cursor by one to two frames. The display links run only while a call is on and the companion is
switched on (observation tracking on `AppModel`); otherwise they are paused and the panels hidden.
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
Search, the idle minutes, the companion and its bubble. The config goes to the session before each call, so a change
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
| `ContextTests` | Markdown, code, PDF with and without text, DOCX and RTF; folder listing and order; Desktop suggestions; request limits |
| `AgentClientTests` | bodies and paths against a stub `URLProtocol`, the service's error text, 404, no answer, unchanged state |
| `VoiceTests` | agent state aliases, caption segment rules and polish, bench event decoding, the level smoother |
| `InspectorTests` | `EngineView` on a real state of the service (`Fixtures/session-state.json`, one note and one reply), a state without engine fields, the turn log's rows |
| `HandsFreeTests`, `DoubleTapTests` | hands-free start, stop, key presses that leave it open, the idle timeout, a toggle while connecting; quick, slow and interrupted taps |
| `AppModelTests` | a press makes a session with the context's sources and opens the mic; a forgotten session is made again; a blocked voice says why; a change of context ends the session |
