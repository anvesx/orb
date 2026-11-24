# orb for Mac

A voice companion one key away: hold **⌥ Space** and talk with orb. It hears you, answers by voice, and shows what it
heard and what it says in an island under the menu bar. Add files or folders as context, and orb talks about them.
The design is [docs/design/mac-app.md](../../docs/design/mac-app.md); the module design is [LLD.md](LLD.md).

```sh
make dev-gemini   # in one terminal: LiveKit, the agent service and the voice worker (Gemini Live, no local models)
make mac-run      # build apps/mac/build/orb.app and open it
make mac-test     # the unit tests (no network, no microphone)
```

- **Talk:** hold ⌥ Space (or press and hold *Hold to talk* in the panel). The first press connects (a few seconds);
  the call then stays up for 3 minutes after anyone last spoke, so the next press is instant.
- **Panel:** click the island or press ⌥⇧Space. *Add* offers the folders on your Desktop, or any files and folders.
- **Companion:** during a call a small orb follows your pointer and shows orb's words. Switch it off in Settings.
- **Inspector** (menu bar › Inspector, or the split button in the panel): the conversation, the next move and persona,
  the six promises, the debts, the last Jev call, timing and cost, and this call's turn latency.
- **Settings** (menu bar › Settings… or the gear): the service address, the Gemini model and voice, orb personas,
  Google Search, the talk shortcut, how long a call stays up, and the companion.
- **Permissions:** macOS asks for the microphone at the first press and for the Desktop folder at the first listing.
- **The voice path alone:** `swift run orb-probe 20` makes one call from the command line and prints the agent's
  states, the captions and the worker's events (the microphone stays muted; add `--talk` to speak).

Needs macOS 14 and Xcode 16 or later. The app talks to the agent service at `http://127.0.0.1:8100`.
