# Gemini personas: orb's brain behind Gemini Live, and Google Search

Status: built · Branch: `feat/gemini-personas` · Date: 2026-11-17

## 1. Goal
In the orb pipeline, Jev reads each message, the debt rules pick a persona, and Gemma writes the reply with the
persona note. In Gemini Live none of that runs: Gemini is a good, but generic, partner. This change gives Gemini
orb's brain: **Jev and the rules decide, Gemini writes and speaks.** It also lets Gemini search Google.

## 2. One turn
```
person speaks ─▶ Gemini Live hears it
   Gemini calls get_persona_note(text)                      tool behaviour BLOCKING: Gemini waits for the note
   voice worker ─ POST /v1/sessions/{id}/notes {text} ─▶ agent service
                  Jev reads the message → the rules → persona and note       (no Gemma, no Ollama)
              ◀─ {read, decision: {persona, debt, stage, note, …}}
   the note is the tool's result ─▶ Gemini replies as that persona
Gemini's reply transcript ─ POST /v1/sessions/{id}/replies {text, interrupted} ─▶ Jev reads the reply, the check
```
The session's chat, debt board and persona panel fill as in the orb pipeline, because the same session records both
messages.

## 3. Design
| Part | Change |
|---|---|
| `orb_core/agent.py` | `ReplyWriter`: an optional protocol for a session whose replies another model writes. `note(text)` yields `read` and `decision`; `add_reply(text)` yields `check` and `state`. |
| `orb_discussion/agent.py` | `DiscussionSession` implements it with the read and check of `turn()`, shared, not copied. |
| agent service | `POST /notes` (traced as an `orb.turn` span) and `POST /replies`. A session that is not a `ReplyWriter` gets 400. |
| `orb_core/gemini.py` | Session switches `gemini_personas` and `gemini_search`; the prompt rules for each. The personas need `gemini-3.8-live`: the extended-thinking model refuses a tool that it must wait for. |
| voice worker | `GeminiTurns` (`gemini_turns.py`): the tool, the posts to the agent service in order, a fallback note when the brain fails or takes more than 8 s, a new read after a cancelled call, and one log line per turn. `GoogleSearch` from the LiveKit Google plugin; `gemini_live.Model` passes on its queries and the cancels, which the plugin drops. |
| page | Two switches in the Gemini fields: "orb personas" and "Google Search". |

Both switches are off by default: a Gemini call without them is unchanged, and the orb pipeline is not touched.

## 4. What only a live call can tell, and how it is measured
| Question | Measure (worker log `gemini turn`, New Relic page "Gemini tools") |
|---|---|
| Does Gemini call the tool on every turn? | `called`: true or false for each reply. A turn without a call is still recorded (the words that Gemini heard go to `/notes` before the reply), so the ledger stays complete. |
| Which words does Jev read? | `match`: how closely the tool's `text` matches Gemini's transcript of the person (0 to 1, words compared, no words logged unless `ORB_LOG_TEXT=1`). |
| How long does the note take? | `note_s`: the tool's time, from the call to the note. |
| Does the reply do the persona's job? | `done`: Jev's check of each reply, as in the orb pipeline. It counts only on turns with `called`: on the others the persona is chosen after Gemini spoke. |
| Did Gemini search Google, and for what? | `searched`, `searches` and `queries`, from the search metadata that Gemini sends with the reply. |

## 5. First live test (2026-11-17, 31 turns)
- The tool was called on 16 of 31 turns (52%). Skipped: short follow-ups, fact questions, complaints, half sentences.
  When called: note in 0.37 s (median; p90 0.51 s), the tool's words matched the transcript (14 of 16 at 0.89 or
  more), and 14 of 16 replies did the persona's job.
- A call that the server cancelled kept the note of half a sentence for the whole sentence. Fixed: a new read with
  `replace_last`.
- Search was not visible: the plugin drops the search metadata. Fixed: `gemini_live._Session`.
- Every orb log line reached New Relic twice: LiveKit Agents adopted orb's global logger provider and added a root
  handler, which also sent orb's lines to LiveKit Cloud. Fixed: the provider stays private (`orb_core.telemetry`).
- The persona rule now comes first in Gemini's prompt and names the cases that it skipped.

## 6. Tickets
| # | Ticket |
|---|---|
| GP-0 | This document and decision 0018 |
| GP-1 | `ReplyWriter`, the discussion session's `note` and `add_reply`, the agent service routes, tests |
| GP-2 | Voice worker: the persona tool, the switches, the prompt rules, tests |
| GP-3 | Google Search switch |
| GP-4 | Page switches, docs, the New Relic page; the owner's live test |
| GP-5 | The fixes of the first live test (section 5) and the New Relic page "Gemini tools" |
