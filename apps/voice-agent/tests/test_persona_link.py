"""orb's personas in a Gemini Live call (docs/design/gemini-personas.md), with a fake agent service. No network."""
import asyncio
import json

import httpx
import pytest

from orb_voice import persona_link
from orb_voice.persona_link import FALLBACK, PersonaLink, match

DECISION = {"persona": "Rival", "debt": "D1", "stage": "Open", "note": "Persona: The Rival. Offer a second option."}


class Bench:
    def __init__(self):
        self.sent = []

    def send(self, kind, **data):
        self.sent.append((kind, data))


def service(notes_status=200, delay=0.0):
    posts = []

    async def handler(req):
        body = json.loads(req.content)
        posts.append((req.url.path.rsplit("/", 1)[-1], body))
        await asyncio.sleep(delay)
        if req.url.path.endswith("/notes"):
            if notes_status != 200:
                return httpx.Response(notes_status, json={"error": "The reader failed"})
            return httpx.Response(200, json={"read": {}, "decision": DECISION})
        return httpx.Response(200, json={"check": {"debt": "D1", "done": True}, "state": {}})

    return httpx.MockTransport(handler), posts


def call(transport, steps, log_text=False):
    bench = Bench()

    async def go():
        async with httpx.AsyncClient(transport=transport) as http:
            link = PersonaLink(http, "http://agent", "web-1", bench, log_text)
            out = [await step(link) for step in steps]
            await link.drain()
            return out

    return asyncio.run(go()), bench


async def ask(link, text="We should store sessions in Redis."):
    return await link.note(text)


def say(text="Signed cookies need no server.", heard=None):
    async def step(link):
        if heard:
            link.hear(heard)
        link.replied(text, False)
    return step


def turns(caplog):
    return [r for r in caplog.records if r.getMessage() == "persona turn"]


def test_the_tool_gets_the_note_and_the_reply_is_recorded_after_it(caplog):
    transport, posts = service()
    with caplog.at_level("INFO", logger="orb.voice"):
        (note, _), bench = call(transport, [ask, say(heard="We should store sessions in Redis.")])
    assert note == DECISION["note"]
    assert posts == [("notes", {"text": "We should store sessions in Redis."}),
                     ("replies", {"text": "Signed cookies need no server.", "interrupted": False})]
    (turn,) = turns(caplog)
    assert (turn.called, turn.persona, turn.done, turn.match) == (True, "Rival", True, 1.0)
    assert turn.note_s is not None and not hasattr(turn, "asked")  # no words without ORB_LOG_TEXT=1
    assert ("agent_decision", {"persona": "Rival", "debt": "D1", "stage": "Open"}) in bench.sent


def test_a_turn_without_a_tool_call_is_recorded_with_the_words_gemini_heard(caplog):
    transport, posts = service()
    with caplog.at_level("INFO", logger="orb.voice"):
        call(transport, [say("Hello!", heard="hi there")], log_text=True)
    assert [p[0] for p in posts] == ["notes", "replies"] and posts[0][1] == {"text": "hi there"}
    (turn,) = turns(caplog)
    assert (turn.called, turn.persona, turn.heard) == (False, "Rival", "hi there")


def test_a_reply_with_nothing_heard_is_recorded_alone():
    transport, posts = service()
    call(transport, [say("Hello! What shall we discuss?")])
    assert [p[0] for p in posts] == ["replies"]


def test_two_calls_before_a_reply_read_the_message_once():
    transport, posts = service()
    (a, b, _), _ = call(transport, [ask, lambda link: link.note("We should store sessions in Redis!"), say()])
    assert a == b == DECISION["note"] and [p[0] for p in posts] == ["notes", "replies"]


def test_a_failed_note_gives_gemini_the_fallback_and_the_reply_is_still_recorded(caplog):
    transport, posts = service(notes_status=502)
    with caplog.at_level("INFO", logger="orb.voice"):
        (note, _), _ = call(transport, [ask, say()])
    assert note == FALLBACK and [p[0] for p in posts] == ["notes", "replies"]
    assert turns(caplog)[0].persona is None


def test_a_slow_brain_gives_the_fallback_in_time(monkeypatch):
    monkeypatch.setattr(persona_link, "NOTE_TIMEOUT", 0.05)
    transport, _ = service(delay=0.3)
    (note,), _ = call(transport, [ask])
    assert note == FALLBACK


@pytest.mark.parametrize("a, b, ratio", [("Store it in Redis.", "store it in redis", 1.0), ("", "x", None),
                                         ("Redis please", "store it in Redis", 0.33)])
def test_match(a, b, ratio):
    assert match(a, b) == ratio
