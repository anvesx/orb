"""Each turn of a Gemini Live call: the persona tool, Google Search, cancels (docs/design/gemini-personas.md), with a fake
agent service. No network."""
import asyncio
import json

import httpx
import pytest
from google.genai import types

from orb_voice import gemini_turns
from orb_voice.gemini_turns import FALLBACK, GeminiTurns, match

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


def call(transport, steps, log_text=False, personas=True):
    bench = Bench()

    async def go():
        async with httpx.AsyncClient(transport=transport) as http:
            turns = GeminiTurns(http, "http://agent", "web-1", bench, log_text, personas)
            out = [await step(turns) for step in steps]
            await turns.drain()
            return out

    return asyncio.run(go()), bench


async def ask(turns, text="We should store sessions in Redis."):
    return await turns.note(text)


def say(text="Signed cookies need no server.", heard=None):
    async def step(turns):
        if heard:
            turns.hear(heard)
        turns.replied(text, False)
    return step


def note(text):
    return lambda turns: turns.note(text)


def logged(caplog):
    return [r for r in caplog.records if r.getMessage() == "gemini turn"]


def test_the_tool_gets_the_note_and_the_reply_is_recorded_after_it(caplog):
    transport, posts = service()
    with caplog.at_level("INFO", logger="orb.voice"):
        (got, _), bench = call(transport, [ask, say(heard="We should store sessions in Redis.")])
    assert got == DECISION["note"]
    assert posts == [("notes", {"text": "We should store sessions in Redis.", "replace_last": False}),
                     ("replies", {"text": "Signed cookies need no server.", "interrupted": False})]
    (turn,) = logged(caplog)
    assert (turn.turn, turn.called, turn.calls, turn.persona, turn.done, turn.match) == (1, True, 1, "Rival", True, 1.0)
    assert turn.note_s is not None and turn.note_error is None and turn.searched is False
    assert not hasattr(turn, "asked") and not hasattr(turn, "reply")  # no words without ORB_LOG_TEXT=1
    assert ("agent_decision", {"persona": "Rival", "debt": "D1", "stage": "Open"}) in bench.sent


def test_a_turn_without_a_tool_call_is_recorded_with_the_words_gemini_heard(caplog):
    transport, posts = service()
    with caplog.at_level("INFO", logger="orb.voice"):
        call(transport, [say("Hello!", heard="hi there")], log_text=True)
    assert [p[0] for p in posts] == ["notes", "replies"] and posts[0][1]["text"] == "hi there"
    (turn,) = logged(caplog)
    assert (turn.called, turn.heard, turn.reply) == (False, "hi there", "Hello!")


def test_a_reply_with_nothing_heard_is_recorded_alone():
    transport, posts = service()
    call(transport, [say("Hello! What shall we discuss?")])
    assert [p[0] for p in posts] == ["replies"]


def test_two_calls_with_the_same_words_read_the_message_once(caplog):
    transport, posts = service()
    with caplog.at_level("INFO", logger="orb.voice"):
        (a, b, _), _ = call(transport, [ask, note("We should store sessions in Redis!"), say()])
    assert a == b == DECISION["note"] and [p[0] for p in posts] == ["notes", "replies"]
    assert logged(caplog)[0].calls == 2


def test_a_call_with_more_words_reads_the_whole_sentence_in_place_of_the_part():
    transport, posts = service()
    call(transport, [note("Let's say I want to"), note("Let's say I want to automate my tickets."), say()])
    assert [(p[0], p[1].get("replace_last")) for p in posts] == [("notes", False), ("notes", True), ("replies", None)]


def test_after_a_cancelled_call_the_words_gemini_heard_replace_the_part(caplog):
    transport, posts = service()

    async def cancelled(turns):
        turns.cancel()

    with caplog.at_level("INFO", logger="orb.voice"):
        call(transport, [note("Let's say I want to"), cancelled, say(heard="Let's say I want to automate my tickets.")])
    assert [(p[0], p[1].get("text"), p[1].get("replace_last")) for p in posts][1] == (
        "notes", "Let's say I want to automate my tickets.", True)
    assert logged(caplog)[0].cancelled is True


def test_searches_are_counted_per_turn_and_the_queries_logged_only_with_text(caplog):
    transport, _ = service()

    async def search(turns):
        turns.searched(types.GroundingMetadata(web_search_queries=["new James Bond actor", "new James Bond actor"]))
        turns.searched(types.GroundingMetadata(web_search_queries=["Amazon MGM Bond casting"]))

    with caplog.at_level("INFO", logger="orb.voice"):
        call(transport, [search, say(), say()], log_text=True, personas=False)
    first, second = logged(caplog)
    assert (first.searched, first.searches, first.queries) == (True, 2, "new James Bond actor | Amazon MGM Bond casting")
    assert (second.searched, second.searches, first.personas) == (False, 0, False)


def test_without_the_personas_nothing_is_posted_and_each_turn_is_still_logged(caplog):
    transport, posts = service()
    with caplog.at_level("INFO", logger="orb.voice"):
        call(transport, [say(heard="hi")], personas=False)
    assert posts == [] and logged(caplog)[0].called is False


def test_a_failed_note_gives_gemini_the_fallback_and_the_reply_is_still_recorded(caplog):
    transport, posts = service(notes_status=502)
    with caplog.at_level("INFO", logger="orb.voice"):
        (got, _), _ = call(transport, [ask, say()])
    assert got == FALLBACK and [p[0] for p in posts] == ["notes", "replies"]
    (turn,) = logged(caplog)
    assert turn.persona is None and "HTTP 502" in turn.note_error


def test_a_slow_brain_gives_the_fallback_in_time(monkeypatch):
    monkeypatch.setattr(gemini_turns, "NOTE_TIMEOUT", 0.05)
    transport, _ = service(delay=0.3)
    (got,), _ = call(transport, [ask])
    assert got == FALLBACK


@pytest.mark.parametrize("a, b, ratio", [("Store it in Redis.", "store it in redis", 1.0), ("", "x", None),
                                         ("Redis please", "store it in Redis", 0.33)])
def test_match(a, b, ratio):
    assert match(a, b) == ratio
