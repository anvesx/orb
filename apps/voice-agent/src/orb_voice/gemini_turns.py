"""What happens in each turn of a Gemini Live call: the tools that Gemini used, and orb's personas
(docs/design/gemini-personas.md).

With the personas on, Gemini calls the persona tool before each reply: Jev reads the person's words, the debt rules
choose the persona, and its note is the tool's result. Gemini's reply goes back to the session, so the ledger keeps
every message in order. A turn in which Gemini did not call the tool is recorded too, with the words that Gemini heard.
A call that the server cancelled (the person went on talking) is read again with the whole sentence.

Each reply ends the turn with one log line, `gemini turn`: the persona tool, Google Search and what went wrong.
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from difflib import SequenceMatcher

import httpx
from livekit.agents import function_tool

from orb_core import gemini

log = logging.getLogger("orb.voice")

NOTE_TIMEOUT = 8.0
FALLBACK = "There is no note for this reply. Reply as a fair discussion partner, in one to three short sentences."


def words(text: str | None) -> list[str]:
    return re.findall(r"[\w']+", (text or "").lower())


def match(a: str | None, b: str | None) -> float | None:
    a, b = words(a), words(b)
    return round(SequenceMatcher(a=a, b=b, autojunk=False).ratio(), 2) if a and b else None


class GeminiTurns:
    def __init__(self, http: httpx.AsyncClient, agent_url: str, sid: str, bench, log_text: bool, personas: bool):
        self.http, self.url, self.sid, self.bench = http, f"{agent_url}/v1/sessions/{sid}", sid, bench
        self.log_text, self.personas = log_text, personas
        self.turn = 0
        self._last: asyncio.Task | None = None
        self._reset()

    def _reset(self) -> None:
        self.heard: list[str] = []
        self.asked: str | None = None
        self.calls = 0
        self.note_s: float | None = None
        self.note_error: str | None = None
        self.queries: list[str] = []
        self.cancelled = False
        self._note: asyncio.Task | None = None

    def tool(self):
        @function_tool(name=gemini.PERSONA_TOOL)
        async def get_persona_note(text: str) -> str:
            """Call this before every reply, with no exception: also for a short question, a follow-up, a fact
            question, a complaint, a greeting, half a sentence, and a turn in which you search Google. It returns your
            role and your job for the next reply.

            Args:
                text: The person's latest words, exactly as they said them.
            """
            return await self.note(text)

        return get_persona_note

    def hear(self, transcript: str) -> None:
        self.heard.append(transcript)

    def searched(self, grounding) -> None:
        self.queries += [q for q in dict.fromkeys(grounding.web_search_queries or []) if q not in self.queries]

    def cancel(self) -> None:
        self.cancelled = True

    async def note(self, text: str) -> str:
        t0 = time.perf_counter()
        self.calls += 1
        if self._note is None or self.cancelled or words(text) != words(self.asked):
            again = self._note is not None  # the person went on talking: the whole sentence replaces the part
            self.asked, self.cancelled = text, False
            self._note = self._then(self._post_note, text, again)
        try:
            note = (await asyncio.wait_for(asyncio.shield(self._note), NOTE_TIMEOUT))["note"]
        except Exception as e:
            self.note_error = f"{type(e).__name__}: {e}"[:300]
            log.error("persona note failed: Gemini replies without one", extra={"session": self.sid, "error": self.note_error})
            note = FALLBACK
        if self.note_s is None:
            self.note_s = round(time.perf_counter() - t0, 3)
        return note

    def replied(self, text: str, interrupted: bool) -> None:
        self.turn += 1
        heard = " ".join(self.heard).strip()
        note = self._note
        if self.personas and heard and (note is None or self.cancelled):
            note = self._then(self._post_note, heard, note is not None)
        turn = {"turn": self.turn, "personas": self.personas, "called": self.calls > 0, "calls": self.calls,
                "note_s": self.note_s, "note_error": self.note_error, "match": match(self.asked, heard),
                "searched": bool(self.queries), "searches": len(self.queries), "cancelled": self.cancelled,
                "interrupted": interrupted, "reply_chars": len(text),
                **({"asked": self.asked, "heard": heard, "queries": " | ".join(self.queries), "reply": text}
                   if self.log_text else {})}
        self._reset()
        self._then(self._finish, text, interrupted, note, turn)

    async def drain(self) -> None:
        if self._last is not None:
            await asyncio.wait([self._last], timeout=10.0)

    def _then(self, fn, *args) -> asyncio.Task:
        prev = self._last

        async def run():
            if prev is not None:
                await asyncio.wait([prev])
            return await fn(*args)

        self._last = asyncio.create_task(run())
        return self._last

    async def _post(self, path: str, body: dict) -> dict:
        r = await self.http.post(f"{self.url}/{path}", json=body, timeout=60.0)
        if r.status_code != 200:
            raise RuntimeError(f"HTTP {r.status_code}: {r.text[:300]}")
        return r.json()

    async def _post_note(self, text: str, replace_last: bool = False) -> dict:
        d = (await self._post("notes", {"text": text, "replace_last": replace_last}))["decision"]
        self.bench.send("agent_decision", persona=d.get("persona"), debt=d.get("debt"), stage=d.get("stage"))
        return d

    async def _finish(self, text: str, interrupted: bool, note: asyncio.Task | None, turn: dict) -> None:
        d, check = {}, {}
        if self.personas:
            try:
                d = await note if note is not None else {}
            except Exception:
                pass
            try:
                check = (await self._post("replies", {"text": text, "interrupted": interrupted}))["check"]
            except Exception as e:
                log.error("Gemini reply not recorded", extra={"session": self.sid, "error": f"{type(e).__name__}: {e}"})
            self.bench.send("agent_check", debt=check.get("debt"), done=check.get("done"))
        log.info("gemini turn", extra={"session": self.sid, "persona": d.get("persona"), "debt": d.get("debt"),
                                       "stage": d.get("stage"), "done": check.get("done"), **turn})
