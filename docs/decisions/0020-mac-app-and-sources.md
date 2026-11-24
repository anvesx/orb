# 0020 · A native Mac app, and sources sent by the channel

Date: 2026-11-24 · Status: proposed

## Decision
- orb gets a native Mac app (`apps/mac`, Swift 6, SwiftUI and AppKit, SwiftPM). It is a channel: it makes the same
  LiveKit voice call as the web page and reads the same agent service. The design is `docs/design/mac-app.md`.
- A session can hold **sources**: the text of files, sent by the channel when the session is created
  (`POST /v1/sessions` field `sources`). The agent service never reads the person's disk; the app reads the files and
  sends their names, kinds and text.
- The prompt has a budget for sources (`ORB_SOURCES_MAX_CHARS`, 120,000 characters by default). Sources fill it in the
  order sent; the rest are cut, marked, or named only.
- In v1 the app makes Gemini Live calls only (decision 0019: no LLM writes replies).
- The web page stays: it is the bench (STT, TTS, suites) and a call page for other devices.

## Why
- The owner wants orb on the Mac as a voice companion, next to their work and their cursor, not in a browser tab.
- Sources are generic text with a name and a kind, so every later context provider (an open document, a web page, the
  clipboard) uses the same field.
- A channel that sends text keeps the service free of file-system access, works when the service runs on another
  machine, and lets each channel read files its own way (PDFKit on the Mac).
- A budget in one place (the prompt) keeps every channel inside the model's context.

## Rejected
- **The service reads a folder path:** it would need disk access and would break when the service is not on the Mac.
- **Electron or a web view around the page:** no native panel, no global shortcut without extra work, no cursor
  companion, and a second browser engine in memory.
- **An Xcode project:** a large generated file in the repo; SwiftPM builds from the command line and `make`.
- **Uploading files to Gemini's file API:** a provider-specific path the next brain (Claude) would not share.
