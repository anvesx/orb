# orb for Mac: low-level design

## Modules
| Module | Holds | Imports |
|---|---|---|
| `OrbKit` | the agent service client (`AgentAPI`, `AgentClient`), context (`ContextProvider`, `FilesProvider`, `Extractor`, `SourcePack`), the voice interface (`VoiceTransport`, `VoiceEvent`, `Captions`, `BenchEvent`, `AudioLevels`), the call machine (`CallMachine`) and `AppModel` | Foundation, AppKit (document text), PDFKit, AVFoundation (microphone permission) |
| `OrbVoice` | `LiveKitTransport`: the room, the muted microphone, the agent state, text streams, data packets, levels | OrbKit, LiveKit |
| `OrbUI` | `Theme` (every token), `Logo`, `OrbView`, `IslandView`, the panel, captions, context chips | OrbKit, SwiftUI |
| `OrbApp` | `Shell` (the model, the menu bar item, the shortcuts, the file picker), `IslandWindow` | all of the above, KeyboardShortcuts |
| `OrbProbe` | a command-line call for testing the voice path | OrbKit, OrbVoice |

`OrbKit` has no SwiftUI and no WebRTC, so its tests run fast with fakes. `OrbUI` never sees LiveKit.

## The call
`CallMachine.reduce(state, event) -> (state, effects)` is pure; `AppModel.run` performs the effects (tasks, timers,
the transport). Phases: idle → preparing (microphone permission, voice status, session, config, token) → connecting →
live. Hold to talk: key down opens the microphone; key up starts a 300 ms tail. A press during preparing or connecting
opens the microphone at the join only if the key is still held. The call ends after `idleMinutes` (3) with no speech,
on hang up, on a new session or a change of context, or when the room disconnects.

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
| `AppModelTests` | a press makes a session with the context's sources and opens the mic; a forgotten session is made again; a blocked voice says why; a change of context ends the session |
