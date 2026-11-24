"""The agent service's public surface: the routes of every setup and the fields of each answer. A refactor must leave
this file unchanged."""
import tempfile

from fastapi.testclient import TestClient

from orb_core.agent import SessionStore
from orb_discussion.agent import DiscussionAgent
from orb_agent.server import create_app
from orb_agent.voice import VoiceConfig
from test_server import LOCAL, FakeLLM, ScriptedReader

BRAIN_AND_PAGE = {
    "GET /", "GET /bench", "GET /health", "GET /openapi.json", "HEAD /openapi.json", "Mount /static",
    "GET /v1/models", "GET /v1/sessions", "POST /v1/sessions", "GET /v1/sessions/{sid}", "PUT /v1/sessions/{sid}",
    "PUT /v1/sessions/{sid}/config", "POST /v1/sessions/{sid}/turns", "POST /v1/sessions/{sid}/notes",
    "POST /v1/sessions/{sid}/replies",
    "GET /v1/sessions/{sid}/instructions", "GET /v1/voice/status", "POST /v1/voice/token",
}
LIVEKIT_PROXY = {"APIWebSocketRoute /rtc", "APIWebSocketRoute /rtc/{rest:path}", "GET /rtc/{rest:path}"}
BENCH = {
    "GET /v1/bench/audio/{run}/{name}", "GET /v1/bench/clip/{group:path}/{name}", "GET /v1/bench/corpus/{group:path}",
    "GET /v1/bench/results/{suite}", "GET /v1/bench/results/{suite}/{run}", "GET /v1/bench/runs/{job_id}",
    "POST /v1/bench/runs", "POST /v1/bench/stt", "GET /v1/speech/engines", "POST /v1/speech/stt",
    "POST /v1/speech/tts",
}
LOCAL_LIVEKIT = VoiceConfig("ws://127.0.0.1:7880", "devkey", "secret", dev=True)
CLOUD_LIVEKIT = VoiceConfig("wss://orb.livekit.cloud", "key", "s" * 40, dev=False)


def routes(items, prefix=""):
    out = set()
    for r in items:
        if hasattr(r, "original_router"):
            out |= routes(r.original_router.routes, prefix + (getattr(r.include_context, "prefix", "") or ""))
        elif getattr(r, "methods", None):
            out |= {f"{m} {prefix}{r.path}" for m in r.methods}
        else:
            out.add(f"{type(r).__name__} {prefix}{r.path}")
    return out


def app(**kw):
    agent = DiscussionAgent(ScriptedReader([]), FakeLLM(), load_source=lambda url: {"url": url, "error": "offline"})
    return create_app(SessionStore({"discussion": agent}, save_dir=tempfile.mkdtemp()), **kw)


def test_routes_of_every_setup():
    assert routes(app().routes) == BRAIN_AND_PAGE
    assert routes(app(voice=CLOUD_LIVEKIT).routes) == BRAIN_AND_PAGE
    assert routes(app(voice=LOCAL_LIVEKIT).routes) == BRAIN_AND_PAGE | LIVEKIT_PROXY
    assert routes(app(speech_url="http://127.0.0.1:8200").routes) == BRAIN_AND_PAGE | BENCH


def test_answer_fields():
    c = TestClient(app(voice=LOCAL_LIVEKIT, gemini_available=lambda: True), base_url=LOCAL)
    assert set(c.get("/health").json()) == {"ok", "agents", "sessions", "voice"}
    assert set(c.get("/v1/voice/status").json()) == {"url", "dev", "local", "proxy", "livekit", "worker"}
    models = c.get("/v1/models").json()
    assert set(models) == {"gemini"}
    assert set(models["gemini"]) == {"available", "only", "models", "default_model", "voices", "default_voice"}
    s = c.post("/v1/sessions", json={"topic": "Cache API answers?", "config": {"voice_mode": "gemini-live"}}).json()
    assert s["config"] == {"voice_mode": "gemini-live"} and s["sources"] == []
    assert set(c.post("/v1/voice/token", json={"session_id": s["id"]}).json()) == {"url", "room", "identity", "token"}
    assert set(c.get(f"/v1/sessions/{s['id']}/instructions").json()) == {"instructions"}


def test_voice_off_keeps_its_routes_and_answers():
    c = TestClient(app(), base_url=LOCAL)
    assert c.get("/v1/voice/status").json() is None and c.get("/health").json()["voice"] is None
    sid = c.post("/v1/sessions", json={"topic": "Cache API answers?"}).json()["id"]
    r = c.post("/v1/voice/token", json={"session_id": sid})
    assert r.status_code == 503 and "LIVEKIT_URL" in r.json()["error"]
