"""The screen tools (docs/design/mac-screen.md section 4, 5): each one is an RPC to the person's app; failures are
sentences for Gemini. No room connects."""
import asyncio
import json
from pathlib import Path
from typing import get_args

from livekit import rtc

from orb_voice import screen_tools
from orb_voice.screen_tools import ScreenTools

CONTRACT = json.loads((Path(__file__).parents[3] / "contracts" / "canvas-ops.json").read_text())


class Participant:
    def __init__(self, identity, kind):
        self.identity, self.kind = identity, kind


class Local:
    def __init__(self, answer=None, error=None):
        self.calls, self.answer, self.error = [], answer, error

    async def perform_rpc(self, *, destination_identity, method, payload, response_timeout):
        self.calls.append((destination_identity, method, json.loads(payload), response_timeout))
        if self.error:
            raise self.error
        return self.answer


class Room:
    def __init__(self, local, people=True):
        self.local_participant = local
        agent = Participant("agent-1", rtc.ParticipantKind.PARTICIPANT_KIND_AGENT)
        app = Participant("mac-7", rtc.ParticipantKind.PARTICIPANT_KIND_STANDARD)
        self.remote_participants = {p.identity: p for p in ([agent, app] if people else [agent])}


def tool(tools, name):
    return next(t for t in tools.tools() if t.id == name)


def run(coro):
    return asyncio.run(coro)


def test_the_tools_are_gemini_function_tools():
    tools = ScreenTools(Room(Local()), "s1")
    assert [t.id for t in tools.tools()] == ["read_screen", "mark", "clear_marks"]


def test_read_screen_asks_the_app_and_returns_its_answer():
    local = Local(answer='{"app": "Preview"}')
    out = run(tool(ScreenTools(Room(local), "s1"), "read_screen")())
    assert out == '{"app": "Preview"}'
    assert local.calls == [("mac-7", screen_tools.READ, {}, screen_tools.TIMEOUT)]  # the app, never the agent


def test_mark_and_clear_send_ops_of_the_wire_format():
    local = Local(answer='{"found": true}')
    tools = ScreenTools(Room(local), "s1")
    run(tool(tools, "mark")(target="2 Related Work", kind="text", style="box", note="section"))
    run(tool(tools, "clear_marks")())
    sent = [c[2] for c in local.calls]
    assert {c[1] for c in local.calls} == {screen_tools.CANVAS}
    fixture = CONTRACT["ops"]
    assert [{k: v for k, v in op.items() if k != "opId"} for op in sent] == \
        [{k: v for k, v in fixture[i].items() if k != "opId"} for i in (0, 3)]
    assert len({op["opId"] for op in sent}) == 2  # each op its own id: a retry draws once


def test_the_contract_fixture_has_the_shapes_the_tools_send():
    for op in CONTRACT["ops"]:
        assert set(op) <= {"v", "op", "opId", "target", "kind", "style", "note"} and op["v"] == 1
        if op["op"] == "mark":
            assert op["kind"] in get_args(screen_tools.Kind) and op["style"] in get_args(screen_tools.Style)


def test_no_app_in_the_room_is_a_sentence_not_an_error():
    local = Local()
    out = json.loads(run(tool(ScreenTools(Room(local, people=False), "s1"), "read_screen")()))
    assert out == {"error": screen_tools.NOT_SHARED} and local.calls == []


def test_rpc_failures_become_short_reasons():
    cases = [(rtc.RpcError(rtc.RpcError.ErrorCode.RESPONSE_TIMEOUT, "timeout"), "did not answer in time"),
             (rtc.RpcError(rtc.RpcError.ErrorCode.UNSUPPORTED_METHOD, "no"), "can't do that yet"),
             (rtc.RpcError(rtc.RpcError.ErrorCode.RESPONSE_PAYLOAD_TOO_LARGE, "big"), "too long"),
             (rtc.RpcError(rtc.RpcError.ErrorCode.APPLICATION_ERROR, "Screen Recording is off"), "Screen Recording")]
    for error, says in cases:
        out = json.loads(run(tool(ScreenTools(Room(Local(error=error)), "s1"), "read_screen")()))
        assert says in out["error"]


def test_each_answer_is_reported_to_the_bench():
    sent = []
    bench = type("B", (), {"send": lambda self, kind, **d: sent.append((kind, d["method"]))})()
    run(tool(ScreenTools(Room(Local(answer="{}")), "s1", bench), "read_screen")())
    assert sent == [("screen_tool", screen_tools.READ)]
