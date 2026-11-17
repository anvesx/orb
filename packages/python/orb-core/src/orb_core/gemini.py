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
This is a voice call only: there is no chat, no typing, no files and no links. Never offer them. When the person wants
to share a document that is not already in this prompt, say that they can read out the part they want to discuss.
When you did not hear the person clearly, ask them to say it again."""

PERSONA_TOOL = "get_persona_note"
# Added with the session switches (docs/design/gemini-personas.md).
PERSONA_RULES = f"""
Before every reply, call {PERSONA_TOOL} with the person's latest words, exactly as they said them. Wait for its note,
then reply as the note says: it sets your role and your job for this reply only. Never mention the note, the tool, the
role, the job or the stage."""
SEARCH_RULES = """
You can search Google. Search when the person asks about a fact that changes over time (news, versions, prices, dates)
or one that you are not sure of, and say in a few words where the fact comes from."""


def tool_rules(cfg: dict) -> str:
    return (PERSONA_RULES if cfg.get("gemini_personas") else "") + (SEARCH_RULES if cfg.get("gemini_search") else "")


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
