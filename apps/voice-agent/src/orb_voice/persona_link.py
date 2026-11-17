"""orb's personas in a Gemini Live call (docs/design/gemini-personas.md).

Gemini calls the tool before each reply: Jev reads the person's words, the debt rules choose the persona, and its note
is the tool's result. Gemini's reply goes back to the session, so the ledger keeps every message in order. A turn in
which Gemini did not call the tool is recorded too, with the words that Gemini heard.
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


class PersonaLink:
    def __init__(self, http: httpx.AsyncClient, agent_url: str, sid: str, bench, log_text: bool):
        self.http, self.url, self.sid, self.bench, self.log_text = http, f"{agent_url}/v1/sessions/{sid}", sid, bench, log_text
        self.heard: list[str] = []
        self.asked: str | None = None
        self.note_s: float | None = None
        self._note: asyncio.Task | None = None
        self._last: asyncio.Task | None = None

    def tool(self):
        @function_tool(name=gemini.PERSONA_TOOL)
        async def get_persona_note(text: str) -> str:
            """Call this before every reply. It returns your role and your job for the next reply.

            Args:
                text: The person's latest words, exactly as they said them.
            """
            return await self.note(text)

        return get_persona_note

    def hear(self, transcript: str) -> None:
        self.heard.append(transcript)

    async def note(self, text: str) -> str:
        t0 = time.perf_counter()
        if self._note is None:  # a second call before the reply reads nothing new
            self.asked = text
            self._note = self._then(self._post_note, text)
        try:
            decision = await asyncio.wait_for(asyncio.shield(self._note), NOTE_TIMEOUT)
            note = decision["note"]
        except Exception as e:
            log.error("persona note failed: Gemini replies without one",
                      extra={"session": self.sid, "error": f"{type(e).__name__}: {e}"})
            note = FALLBACK
        if self.note_s is None:
            self.note_s = round(time.perf_counter() - t0, 3)
        return note

    def replied(self, text: str, interrupted: bool) -> None:
        heard = " ".join(self.heard).strip()
        note = self._note or (self._then(self._post_note, heard) if heard else None)
        turn = {"called": self._note is not None, "note_s": self.note_s, "match": match(self.asked, heard),
                "interrupted": interrupted, **({"asked": self.asked, "heard": heard} if self.log_text else {})}
        self.heard, self.asked, self.note_s, self._note = [], None, None, None
        self._then(self._post_reply, text, interrupted, note, turn)

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

    async def _post_note(self, text: str) -> dict:
        d = (await self._post("notes", {"text": text}))["decision"]
        self.bench.send("agent_decision", persona=d.get("persona"), debt=d.get("debt"), stage=d.get("stage"))
        return d

    async def _post_reply(self, text: str, interrupted: bool, note: asyncio.Task | None, turn: dict) -> None:
        try:
            d = await note if note is not None else {}
        except Exception:
            d = {}
        try:
            check = (await self._post("replies", {"text": text, "interrupted": interrupted}))["check"]
        except Exception as e:
            log.error("Gemini's reply was not recorded", extra={"session": self.sid, "error": f"{type(e).__name__}: {e}"})
            check = {}
        self.bench.send("agent_check", debt=check.get("debt"), done=check.get("done"))
        log.info("persona turn", extra={"session": self.sid, "persona": d.get("persona"), "debt": d.get("debt"),
                                        "stage": d.get("stage"), "done": check.get("done"), **turn})
