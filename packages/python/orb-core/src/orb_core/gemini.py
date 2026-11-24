"""Gemini Live: the facts that the agent service and the voice worker share (docs/design/gemini-live.md).

In the "gemini-live" voice mode one Google model hears, thinks and speaks; the orb pipeline (speech service, orb
agent, Ollama) is not used for the call. The lists below are the ones of livekit-plugins-google 1.8.9
(`realtime.api_proto`); the voice worker's tests check that the plugin still has them.
"""
from __future__ import annotations

import os

MODES = ("orb", "gemini-live")
MODELS = ("gemini-3.8-live", "gemini-3.8-live-extended-thinking")
DEFAULT_MODEL = MODELS[0]
VOICES = ("Achernar", "Achird", "Algenib", "Algieba", "Alnilam", "Aoede", "Autonoe", "Callirrhoe", "Charon", "Despina",
          "Enceladus", "Erinome", "Fenrir", "Gacrux", "Iapetus", "Kore", "Laomedeia", "Leda", "Orus", "Pulcherrima",
          "Puck", "Rasalgethi", "Sadachbia", "Sadaltager", "Schedar", "Sulafat", "Umbriel", "Vindemiatrix", "Zephyr",
          "Zubenelgenubi")
DEFAULT_VOICE = "Kore"  # a female voice (Google: "firm")
KEY = "GOOGLE_API_KEY"

# Added to orb's system prompt: Gemini speaks every word it writes, and no per-turn note comes (no personas).
VOICE_RULES = """
You are speaking, not writing: answer in one to three short sentences, then let the person talk.
Language: answer in the language of the person's latest sentence, not the first one. When they speak English, answer
in English; when they mix Hindi or Gujarati with English, mix them the same way, in Latin letters. When they ask for a
language ("speak in English"), use it for the rest of the call until they ask for another.
This is a voice call only: there is no chat and no typing. When files are in this prompt, the person chose them: name
the file you use.
When you did not hear the person clearly, ask them to say it again."""

PERSONA_TOOL = "get_persona_note"
# Added with the session switches (docs/design/gemini-personas.md).
PERSONA_RULES = f"""The first rule, above all others: before every reply, call {PERSONA_TOOL} with the person's latest
words, exactly as they said them. No exception: also for a short question, a follow-up, a fact question, a complaint,
a greeting, half a sentence, and a turn in which you search Google. Wait for its note, then reply as the note says: it
sets your role and your job for this reply only. Never mention the note, the tool, the role, the job or the stage.
"""
SEARCH_RULES = """
You can search Google. Search when the person asks about a fact that changes over time (news, versions, prices, dates)
or one that you are not sure of, and say in a few words where the fact comes from."""

SCREEN_RULES = """
You can see the person's screen: frames of it arrive while they talk. "This", "here" and "that" mean what is on their
screen, near their pointer. When you need exact words (a paragraph, a number, a line of code, a name), call read_screen
first and use its text; it also has the whole document open in the front app. To show something while you explain,
call highlight_text with a few words exactly as they appear on the screen, or point_at for something that is not text.
Show first, then talk about it. Never say coordinates out loud. When a tool says it found nothing or failed, say so in a
few words. When the screen is not shared, say that you can't see it and that they can allow it in orb."""


def with_tool_rules(instructions: str, cfg: dict) -> str:
    """The persona rule goes first, above the topic's prompt (with it last, Gemini called the tool on 16 of 31 turns,
    2026-11-17)."""
    return ((PERSONA_RULES + "\n" if cfg.get("gemini_personas") else "") + instructions
            + (SEARCH_RULES if cfg.get("gemini_search") else "") + (SCREEN_RULES if cfg.get("gemini_screen") else ""))


def available() -> bool:
    """Whether a Gemini key is set. The value is never read out of this module."""
    return bool(os.environ.get(KEY, "").strip())


def check(mode: str | None, model: str | None, voice: str | None, personas: bool = False) -> str | None:
    """Why a session config cannot use these values, or None. Empty values mean the defaults."""
    if mode and mode not in MODES:
        return f"voice_mode must be one of {', '.join(MODES)}, not {mode!r}."
    if model and model not in MODELS:
        return f"gemini_model must be one of {', '.join(MODELS)}, not {model!r}."
    if voice and voice not in VOICES:
        return f"gemini_voice {voice!r} is not a Gemini voice. Voices: {', '.join(VOICES)}."
    if personas and (model or DEFAULT_MODEL).endswith("-extended-thinking"):
        return f"The orb personas need {DEFAULT_MODEL}: the extended-thinking model refuses a tool that it must wait for."
    return None
