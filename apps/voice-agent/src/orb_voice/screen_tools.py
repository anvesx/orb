"""The screen tools of a Gemini Live call (docs/design/mac-screen.md): Gemini reads and points at the person's screen.

The worker never touches the screen: each tool is an RPC to the person's app in the room, which reads the screen
(OCR, Accessibility) or moves its companion there, and answers JSON. A failure becomes a short sentence that Gemini
can say, never an exception that would end its turn.
"""
from __future__ import annotations

import json
import logging
import time

from livekit import rtc
from livekit.agents import function_tool

log = logging.getLogger("orb.voice")

READ = "orb.screen.read"
SHOW = "orb.screen.show"
TIMEOUT = 4.0  # OCR of a display takes about half a second; Gemini waits in silence for the answer
NOT_SHARED = "The person's screen is not shared in this call: no orb app is in the room."


class ScreenTools:
    def __init__(self, room: rtc.Room, sid: str, bench=None):
        self.room, self.sid, self.bench = room, sid, bench

    def app(self) -> str | None:
        """The identity of the person's app: the one participant in the room that is not an agent."""
        for p in self.room.remote_participants.values():
            if p.kind != rtc.ParticipantKind.PARTICIPANT_KIND_AGENT:
                return p.identity
        return None

    async def call(self, method: str, payload: dict) -> str:
        identity = self.app()
        if identity is None:
            return json.dumps({"error": NOT_SHARED})
        t0 = time.perf_counter()
        try:
            out = await self.room.local_participant.perform_rpc(
                destination_identity=identity, method=method, payload=json.dumps(payload), response_timeout=TIMEOUT)
        except rtc.RpcError as e:
            log.warning("screen tool failed", extra={"session": self.sid, "method": method, "code": e.code,
                                                     "error": e.message})
            why = ("orb's app did not answer in time" if e.code == rtc.RpcError.ErrorCode.RESPONSE_TIMEOUT
                   else "this orb app can't do that yet" if e.code == rtc.RpcError.ErrorCode.UNSUPPORTED_METHOD
                   else "the screen's text was too long to send" if e.code == rtc.RpcError.ErrorCode.RESPONSE_PAYLOAD_TOO_LARGE
                   else e.message or "orb's app could not do it")
            return json.dumps({"error": why})
        ms = round((time.perf_counter() - t0) * 1000)
        log.info("screen tool", extra={"session": self.sid, "method": method, "ms": ms, "bytes": len(out)})
        if self.bench:
            self.bench.send("screen_tool", method=method, ms=ms)
        return out

    def tools(self) -> list:
        @function_tool(name="read_screen")
        async def read_screen() -> str:
            """Read the person's screen exactly: the front app and window, the text they selected, the text of the
            document open in the front app, and every line of text on the screen. Call it before you quote, explain or
            summarise words, numbers or code on the screen."""
            return await self.call(READ, {})

        @function_tool(name="highlight_text")
        async def highlight_text(text: str, note: str = "") -> str:
            """Highlight words on the person's screen and move orb's pointer to them, while you talk about them.

            Args:
                text: a few words exactly as they appear on the screen, from one passage (3 to 12 words is best).
                note: a very short label shown next to the highlight, or empty.
            """
            return await self.call(SHOW, {"text": text, "label": note})

        @function_tool(name="point_at")
        async def point_at(x: int, y: int, label: str = "") -> str:
            """Move orb's pointer to something on the screen that is not text: a button, an icon, a part of a picture.

            Args:
                x: 0 (left edge) to 1000 (right edge) of the screen you see.
                y: 0 (top edge) to 1000 (bottom edge) of the screen you see.
                label: a very short label shown next to the pointer, or empty.
            """
            return await self.call(SHOW, {"x": max(0, min(1000, x)), "y": max(0, min(1000, y)), "label": label})

        return [read_screen, highlight_text, point_at]
