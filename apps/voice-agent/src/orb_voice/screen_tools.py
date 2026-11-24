"""The screen tools of a Gemini Live call (docs/design/screen-canvas.md): Gemini reads the person's screen and marks it.

The worker never touches the screen: each tool is an RPC to the person's app in the room, which reads the screen
(OCR, Accessibility) or finds the target and draws on it, and answers JSON. A failure becomes a short sentence that Gemini
can say, never an exception that would end its turn.
"""
from __future__ import annotations

import json
import logging
import time
import uuid
from typing import Literal

from livekit import rtc
from livekit.agents import function_tool

log = logging.getLogger("orb.voice")

READ = "orb.screen.read"
CANVAS = "orb.canvas"
Kind = Literal["text", "ui", "visual"]
Style = Literal["underline", "box", "marker", "circle"]
TIMEOUT = 9.0  # the app's own budgets end first (sight 6 s); this only catches an app that is gone
NOT_SHARED = "The person's screen is not shared in this call: no orb app is in the room."


class ScreenTools:
    def __init__(self, room: rtc.Room, sid: str, bench=None, log_text: bool = False):
        self.room, self.sid, self.bench, self.log_text = room, sid, bench, log_text

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
        log.info("screen tool", extra={"session": self.sid, "method": method, "ms": ms, "bytes": len(out),
                                       **({"payload": payload, "answer": out[:200]} if self.log_text else {})})
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

        @function_tool(name="mark")
        async def mark(target: str, kind: Kind, style: Style = "underline", note: str = "") -> str:
            """Draw on the person's screen by hand, as a teacher would with a pen, while you talk about it. orb finds
            the target itself: never give coordinates.

            Args:
                target: for kind "text", the words copied exactly from read_screen (3 to 12 words of one passage);
                    otherwise a short description of the thing ("the blue robot", "the Export button").
                kind: "text" for words on the screen, "ui" for a button, menu, field or tab, "visual" for a picture,
                    an icon or a part of a figure.
                style: "underline" for a phrase, "box" for a number, a name or a short block, "marker" for a sentence
                    to read, "circle" for a thing or a picture.
                note: a very short label shown next to the mark, or empty.
            """
            return await self.call(CANVAS, canvas_op("mark", target=target, kind=kind, style=style, note=note))

        @function_tool(name="clear_marks")
        async def clear_marks() -> str:
            """Remove every mark orb drew on the screen."""
            return await self.call(CANVAS, canvas_op("clear"))

        return [read_screen, mark, clear_marks]


def canvas_op(op: str, **fields) -> dict:
    """An op of the canvas wire format (contracts/canvas-ops.json); the id makes a retried call draw once."""
    return {"v": 1, "op": op, "opId": uuid.uuid4().hex[:8], **fields}
