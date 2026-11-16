"""The orb agent service: one HTTP API for every channel.

    python -m orb_agent.server            # http://127.0.0.1:8100, or ORB_AGENT_PORT

POST /v1/sessions                 {"topic", "agent"?}       -> the session state (201)
GET  /v1/sessions                                           -> [{id, topic, agent}]
GET  /v1/sessions/{id}[?since=v]                            -> the state, or {"version": v, "unchanged": true}
PUT  /v1/sessions/{id}            {"topic", "agent"?}       -> the state; creates the session when it is missing
POST /v1/sessions/{id}/turns      {"text", "channel"?, "replace_last"?}
                                  -> NDJSON events: read, decision, token..., reply, check, state
GET  /v1/sessions/{id}/instructions                         -> {"instructions"}: the system prompt for Gemini Live
GET  /v1/models                                             -> {"llm": {...}, "gemini": {available, models, voices, ...}}
POST /v1/voice/token              {"session_id"}            -> {"url", "token", "room", "identity"}
GET  /v1/voice/status                                       -> {"url", "dev", "local", "livekit", "worker"} or null
GET  /health
GET  /                                                      -> the web chat

It listens on 127.0.0.1 only and has no user accounts. A request that comes through a tunnel or from another device
is refused unless it has the key ORB_SHARE_KEY (access.py).
"""
from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from orb_core.agent import CHANNELS, Event, InputError, SessionStore, check_session_id
from orb_agent.access import AccessMiddleware, check_key
from orb_agent.bench import make_router
from orb_agent.voice import VoiceChannel, VoiceConfig, listening, livekit_answers

log = logging.getLogger("orb.agent")
STATIC = Path(__file__).parent / "static"


class SessionConfig(BaseModel):
    """The models of one session, chosen in the bench. Empty fields use the service defaults."""
    stt_engine: str | None = Field(default=None, max_length=32)
    llm_model: str | None = Field(default=None, max_length=64)
    tts_engine: str | None = Field(default=None, max_length=32)
    tts_voice: str | None = Field(default=None, max_length=400)
    tts_style: str | None = Field(default=None, max_length=64)
    tts_lang: str | None = Field(default=None, max_length=16)
    # Gemini Live (docs/design/gemini-live.md): "gemini-live" sends the call to Google; empty means "orb"
    voice_mode: str | None = Field(default=None, max_length=16)
    gemini_model: str | None = Field(default=None, max_length=64)
    gemini_voice: str | None = Field(default=None, max_length=32)


class NewSession(BaseModel):
    topic: str = Field(min_length=1, max_length=2000)
    agent: str | None = None
    config: SessionConfig | None = None


class TurnIn(BaseModel):
    text: str = Field(min_length=1, max_length=8000)
    channel: str = "web"
    replace_last: bool = False  # voice: the last turn was never heard, and `text` says that sentence further


def create_app(store: SessionStore, voice: VoiceConfig | None = None, *, model_agent=None, installed_models=None,
               default_model: str = "", speech_url: str | None = None, self_url: str = "http://127.0.0.1:8100",
               share_key: str | None = None, probe=None, worker_port: int | None = None, livekit_probe=None,
               gemini_available=None, gemini_only: bool = False) -> FastAPI:
    """`model_agent(model)` makes an agent that uses another LLM; `installed_models()` lists the models it may use.
    With `speech_url`, the bench API (bench.py) is on too. `share_key` lets a remote request in (access.py). The voice
    arguments go to `VoiceChannel` (voice.py)."""
    app = FastAPI(title="orb agent", docs_url=None, redoc_url=None)
    app.add_middleware(AccessMiddleware, key=check_key(share_key))  # checked here: Starlette makes the middleware at the first request
    channel = VoiceChannel(voice, probe=probe, worker_port=worker_port, livekit_probe=livekit_probe,
                           gemini_available=gemini_available, gemini_only=gemini_only)
    if speech_url:
        app.include_router(make_router(speech_url, self_url))
    configs: dict[str, dict] = {}  # session id -> its SessionConfig, without empty fields
    app.mount("/static", StaticFiles(directory=STATIC), name="static")
    background: set[asyncio.Task] = set()

    def later(coro):
        task = asyncio.create_task(coro)
        background.add(task)
        task.add_done_callback(background.discard)

    def session_or_404(sid: str):
        try:
            check_session_id(sid)
        except InputError as e:
            raise HTTPException(400, str(e))
        s = store.get(sid)
        if s is None:
            raise HTTPException(404, f"There is no session {sid}. Start one with POST /v1/sessions.")
        return s

    app.include_router(channel.router(session_or_404))

    async def agent_for(body: NewSession) -> str | None:
        """The agent of a new session: the default one, or one for the LLM that the config names."""
        model = body.config.llm_model if body.config else None
        if not model or model == default_model or model_agent is None:
            return body.agent
        name = f"discussion@{model}"
        if name not in store.agents:
            models = await installed_models() if installed_models else []
            if model not in models:
                raise HTTPException(400, f"Ollama has no model {model!r}. Installed: {', '.join(models) or 'none'}.")
            store.agents[name] = model_agent(model)
        return name

    def with_config(s) -> dict:
        return {**s.state(), "config": configs.get(s.id, {})}

    def checked(config: SessionConfig | None) -> dict:
        """The config without empty fields; the voice channel refuses voice values it cannot use (400)."""
        if config is None:
            return {}
        channel.check(config)
        return config.model_dump(exclude_none=True)

    def started(s, config: dict):
        if hasattr(s, "prepare"):
            later(s.prepare(warm=channel.warms(config)))
        return s

    async def save_after(s):
        await s.settle()
        try:
            store.save(s)
        except OSError as e:
            log.warning("could not save session %s: %s", s.id, e)

    @app.get("/")
    async def page():
        return FileResponse(STATIC / "index.html")

    @app.get("/bench")
    async def bench_page():  # the bench tools are tabs of the chat page now
        return RedirectResponse("/", status_code=307)

    @app.get("/health")
    async def health():
        agents = {}
        for name, agent in store.agents.items():
            try:
                agents[name] = await agent.health()
            except Exception as e:
                agents[name] = {"error": f"{type(e).__name__}: {e}"}
        return {"ok": True, "agents": agents, "sessions": len(store.list()), "voice": await channel.status()}

    @app.post("/v1/sessions", status_code=201)
    async def create(body: NewSession):
        config = checked(body.config)
        agent = await agent_for(body)
        try:
            s = started(store.create(body.topic, agent), config)
        except InputError as e:
            raise HTTPException(400, str(e))
        if config:
            configs[s.id] = config
        return with_config(s)

    @app.get("/v1/models")
    async def models():
        return {"llm": {"default": default_model, "installed": await installed_models() if installed_models else []},
                "gemini": channel.models()}

    @app.put("/v1/sessions/{sid}/config")
    async def set_config(sid: str, body: SessionConfig):
        s = session_or_404(sid)
        old = configs.get(sid, {})
        if body.llm_model and body.llm_model != old.get("llm_model", default_model):
            raise HTTPException(400, "The LLM of a session is fixed when it starts. Start a new session for another LLM.")
        # checked as a whole: a change of gemini_model alone in a gemini-live session still needs the key
        configs[sid] = checked(SessionConfig(**{**old, **body.model_dump(exclude_none=True)}))
        return configs[s.id]

    @app.get("/v1/sessions")
    async def listing():
        return store.list()

    @app.get("/v1/sessions/{sid}")
    async def read(sid: str, since: int | None = None):
        s = session_or_404(sid)
        state = with_config(s)
        if since is not None and state.get("version") == since:
            return {"version": since, "unchanged": True}
        return state

    @app.put("/v1/sessions/{sid}")
    async def ensure(sid: str, body: NewSession):
        try:
            s = store.get(check_session_id(sid))
            config = checked(body.config)  # also for a session that exists: a bad config is refused, not ignored
            if s is None:
                s = started(store.create(body.topic, await agent_for(body), sid), config)
                if config:
                    configs[s.id] = config
        except InputError as e:
            raise HTTPException(400, str(e))
        return with_config(s)

    @app.post("/v1/sessions/{sid}/turns")
    async def turn(sid: str, body: TurnIn):
        s = session_or_404(sid)
        if body.channel not in CHANNELS:
            raise HTTPException(400, f"channel must be one of {', '.join(CHANNELS)}.")

        async def stream():
            try:
                async for ev in s.turn(body.text, body.channel, replace_last=body.replace_last):
                    yield ev.to_json() + "\n"
            except InputError as e:
                yield Event("error", str(e)).to_json() + "\n"
            finally:
                later(save_after(s))

        return StreamingResponse(stream(), media_type="application/x-ndjson")

    @app.exception_handler(HTTPException)
    async def http_error(request, exc):
        return JSONResponse({"error": exc.detail}, status_code=exc.status_code)

    return app


def build() -> FastAPI:
    from orb_core import config
    from orb_core.jev import make_reader
    from orb_core.ollama import Ollama
    from orb_discussion.agent import DiscussionAgent

    config.bootstrap()
    root = config.repo_root()
    url = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
    default_model = os.environ.get("ORB_LLM_MODEL", "gemma4:e2b")
    reader = make_reader()
    store = SessionStore({"discussion": DiscussionAgent(reader, Ollama(base_url=url, model=default_model))},
                         save_dir=root / "data" / "sessions")

    async def installed() -> list[str]:
        return (await Ollama(base_url=url, model=default_model).health()).get("available") or []

    port = int(os.environ.get("ORB_AGENT_PORT", "8100"))
    return create_app(store, VoiceConfig.from_env(), default_model=default_model, installed_models=installed,
                      model_agent=lambda model: DiscussionAgent(reader, Ollama(base_url=url, model=model)),
                      speech_url=os.environ.get("ORB_SPEECH_URL", "http://127.0.0.1:8200"),
                      self_url=f"http://127.0.0.1:{port}", share_key=os.environ.get("ORB_SHARE_KEY"),
                      probe=listening, worker_port=int(os.environ.get("ORB_VOICE_PORT", "8081")),
                      livekit_probe=livekit_answers, gemini_only=os.environ.get("ORB_GEMINI_ONLY") == "1")


def main():
    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    uvicorn.run(build(), host="127.0.0.1", port=int(os.environ.get("ORB_AGENT_PORT", "8100")), log_level="warning")


if __name__ == "__main__":
    main()
