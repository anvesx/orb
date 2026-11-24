# orb for Mac

A voice companion one key away: hold **⌥ Space** and talk with orb. It hears you, answers by voice, and shows what it
heard and what it says in an island under the menu bar. What you look at is the context: during a call orb sees your
screen, reads its text and the document open in the front app, and points at and highlights what it explains.
The design is [docs/design/mac-app.md](../../docs/design/mac-app.md) and
[docs/design/mac-screen.md](../../docs/design/mac-screen.md); the module design is [LLD.md](LLD.md).

```sh
make dev-gemini   # in one terminal: LiveKit, the agent service and the voice worker (Gemini Live, no local models)
make mac-run      # build apps/mac/build/orb.app and open it
make mac-test     # the unit tests (no network, no microphone)
```

- **Talk:** hold ⌥ Space (or press and hold *Hold to talk* in the panel). The first press connects (a few seconds);
  the call then stays up for 3 minutes after anyone last spoke, so the next press is instant.
- **Hands-free:** double-tap ⌥ and talk without holding a key; Gemini decides
  when you finished, and you can talk over orb. Double-tap ⌥ again to stop. macOS shows a lone ⌥ tap to an app only
  with the Accessibility permission, so orb asks for it once (Settings can switch the double tap off).
- **Ready vs Listening:** "Listening" means the microphone is open and orb hears you; between presses the call is
  "Ready" (the microphone is closed).
- **Your screen:** look at anything (a PDF, a page, code) and ask "what does this paragraph mean?" or "where is the
  export button?". During a call orb shares the display under your pointer with Gemini (1 frame/s, orb's own windows
  left out), reads the exact text when it needs it (`read_screen`: OCR, your selection, the open document), and draws
  on it by hand while it talks (`mark`: a box, an underline, a marker stroke, or a loop around a picture). orb finds
  what Gemini names by OCR, Accessibility or a vision model ([screen-canvas.md](../../docs/design/screen-canvas.md)).
  Nothing is shared outside a call; Settings › Screen switches it off.
- **Panel:** click the island or press ⌥⇧Space: the orb, the captions, one line of what orb can use (your screen,
  Google Search), and talk.
- **Companion:** during a call a small orb follows your pointer and shows orb's words. Switch it off in Settings.
- **Inspector** (menu bar › Inspector): the conversation, the next move and persona,
  the six promises, the debts, the last Jev call, timing and cost, and this call's turn latency.
- **Settings** (menu bar › Settings… or the gear): the service address, the Gemini model and voice, orb personas,
  Google Search (on by default), the screen, the talk shortcut, how long a call stays up, and the companion.
- **Permissions:** the microphone at the first press; Screen Recording at the first call with the screen on (macOS
  restarts orb when you allow it); Accessibility for the double tap and for the window, selection and document.
- **The voice path alone:** `swift run orb-probe 20` makes one call from the command line and prints the agent's
  states, the captions and the worker's events (the microphone stays muted; add `--talk` to speak).

Needs macOS 14 and Xcode 16 or later. The app talks to the agent service at `http://127.0.0.1:8100`.
