import asyncio

from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from opentelemetry.trace import StatusCode

from orb_core import telemetry
from orb_core.agent import Event

TURN = [
    Event("read", {"claim": True}),
    Event("decision", {"persona": "rival", "debt": "D1", "kind": "option", "stage": "open", "note": "Argue for Redis."}),
    Event("token", "Redis "),
    Event("reply", {"text": "Redis is faster.", "timing": {"wait": 0.0, "read_human": 0.5, "llm_first_token": 0.1,
                                                          "llm_total": 0.3}}),
    Event("check", {"debt": "D1", "done": True}),
    Event("state", {"id": "s1"}),
]


async def _events(items):
    for ev in items:
        yield ev


def run(items, provider=None):
    async def go():
        return [ev async for ev in telemetry.traced(_events(items), "s1", "voice", "Use a cache?", provider)]
    return asyncio.run(go())


def memory():
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    return provider, exporter


def test_off_without_a_key(monkeypatch):
    monkeypatch.delenv(telemetry.KEY, raising=False)
    assert telemetry.start("orb-test") is None
    assert run(TURN) == TURN


def test_a_turn_is_one_span_with_the_read_and_the_llm_inside(monkeypatch):
    monkeypatch.setenv("ORB_LOG_TEXT", "1")
    provider, exporter = memory()
    assert run(TURN, provider) == TURN
    spans = {s.name: s for s in exporter.get_finished_spans()}
    assert set(spans) == {"orb.turn", "jev.read", "llm"}
    turn = spans["orb.turn"]
    assert spans["jev.read"].parent.span_id == spans["llm"].parent.span_id == turn.context.span_id
    assert abs((spans["jev.read"].end_time - spans["jev.read"].start_time) / 1e9 - 0.5) < 1e-6
    assert abs((spans["llm"].end_time - spans["llm"].start_time) / 1e9 - 0.3) < 1e-6
    a = turn.attributes
    assert (a["orb.session"], a["orb.channel"], a["orb.persona"], a["orb.debt"]) == ("s1", "voice", "rival", "D1")
    assert a["orb.timing.read_human"] == 0.5 and a["orb.check_done"] is True and a["orb.reply_chars"] == 16
    assert (a["orb.text"], a["orb.reply"], a["orb.note"]) == ("Use a cache?", "Redis is faster.", "Argue for Redis.")


def test_no_words_without_orb_log_text(monkeypatch):
    monkeypatch.setenv("ORB_LOG_TEXT", "0")
    provider, exporter = memory()
    run(TURN, provider)
    turn = next(s for s in exporter.get_finished_spans() if s.name == "orb.turn")
    assert not {"orb.text", "orb.reply", "orb.note"} & set(turn.attributes)
    assert turn.attributes["orb.persona"] == "rival"


def test_an_error_event_marks_the_turn():
    provider, exporter = memory()
    run([Event("error", "The LLM failed: down")], provider)
    (turn,) = exporter.get_finished_spans()
    assert turn.status.status_code == StatusCode.ERROR and "down" in turn.status.description
