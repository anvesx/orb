"""The voice channel of the agent service: LiveKit room tokens and status, and the Gemini Live settings and prompt of
a session. The brain routes (server.py) know nothing of voice; they ask `VoiceChannel.check` and `.warms`.

The agent service only signs tokens for rooms of sessions that exist. With no LIVEKIT_API_KEY and a loopback LIVEKIT_URL, it uses the public credentials of `livekit-server --dev`
(devkey / secret). Those are for this machine only. Any other server needs its own key and a secret of 32 or
more characters.
"""
from __future__ import annotations

import asyncio
import os
import secrets
from dataclasses import dataclass
from datetime import timedelta
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, HTTPException
from livekit import api as lkapi
from pydantic import BaseModel

from orb_core import gemini
from orb_agent import livekit_proxy

ROOM_PREFIX = "orb-"
DEV_KEY, DEV_SECRET = "devkey", "secret"
LOOPBACK = ("127.0.0.1", "localhost", "::1")


def room_for(session_id: str) -> str:
    return ROOM_PREFIX + session_id


def is_local(url: str) -> bool:
    """True when the address is on this machine. A browser on another device cannot reach such an address."""
    return urlparse(url).hostname in LOOPBACK


def host_port(url: str) -> tuple[str, int]:
    u = urlparse(url)
    return u.hostname or "", u.port or (443 if u.scheme in ("wss", "https") else 80)


async def listening(host: str, port: int, timeout: float = 0.4) -> bool:
    """True when something accepts a TCP connection there. It says that a server runs, not that it works."""
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    except (OSError, asyncio.TimeoutError):
        return False
    writer.close()
    return True


async def livekit_answers(url: str, timeout: float = 1.5) -> bool:
    """True when the LiveKit server answers at this address: its health page (GET /) says OK. A tunnel with no server
    behind it answers with a page of its own, so a TCP connection would say yes when the answer is no."""
    http = "http" + url[2:] if url.startswith("ws") else url  # ws -> http, wss -> https
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.get(http, headers={"ngrok-skip-browser-warning": "1"})
    except httpx.HTTPError:
        return False
    return r.status_code == 200 and r.text.strip() == "OK"


@dataclass(frozen=True)
class VoiceConfig:
    url: str          # what the browser connects to
    api_key: str
    api_secret: str
    dev: bool
    server_url: str = ""  # where this service and the voice worker reach the LiveKit server (LIVEKIT_URL); empty: `url`

    @property
    def local(self) -> bool:
        return is_local(self.url)

    @property
    def server(self) -> str:
        return self.server_url or self.url

    @classmethod
    def from_env(cls) -> "VoiceConfig | None":
        server = os.environ.get("LIVEKIT_URL") or "ws://127.0.0.1:7880"
        url = os.environ.get("LIVEKIT_PUBLIC_URL") or server
        key, secret = os.environ.get("LIVEKIT_API_KEY"), os.environ.get("LIVEKIT_API_SECRET")
        loopback = is_local(url)
        if key and secret:
            if not loopback and len(secret) < 32:
                raise ValueError("LIVEKIT_API_SECRET must have 32 or more characters for a server that is not local.")
            return cls(url, key, secret, dev=False, server_url=server)
        if loopback:
            return cls(url, DEV_KEY, DEV_SECRET, dev=True, server_url=server)
        return None  # no credentials for a remote server: voice is off

    def token(self, room: str, identity: str, name: str = "You", ttl_minutes: int = 60) -> str:
        grants = lkapi.VideoGrants(room_join=True, room=room, can_publish=True, can_subscribe=True, can_publish_data=True)
        return (lkapi.AccessToken(self.api_key, self.api_secret).with_identity(identity).with_name(name)
                .with_grants(grants).with_ttl(timedelta(minutes=ttl_minutes)).to_jwt())


class VoiceIn(BaseModel):
    session_id: str


async def unknown():
    return None


class VoiceChannel:
    """`probe(host, port)` says whether a server listens there: with it, the voice status tells whether the LiveKit server
    and the voice worker (on `worker_port`) run. `livekit_probe(url)` checks the LiveKit server by its address instead
    (a tunnel accepts a connection also when no server is behind it). Without a probe, the status does not check.
    `gemini_available()` says whether the Gemini key is set (the "gemini-live" voice mode needs it). `gemini_only`
    (`scripts/dev.sh --gemini`): the speech service and the LLM are not meant to run, so a voice session must be
    gemini-live and no session warms the LLM."""

    def __init__(self, voice: VoiceConfig | None, *, probe=None, worker_port: int | None = None, livekit_probe=None,
                 gemini_available=None, gemini_only: bool = False):
        self.voice, self.probe, self.worker_port, self.livekit_probe = voice, probe, worker_port, livekit_probe
        self.gemini_available, self.gemini_only = gemini_available or gemini.available, gemini_only
        self.proxy = voice is not None and is_local(voice.server)  # a LiveKit server on this computer: its signal goes through this service too

    def check(self, config) -> None:
        """400 for a Gemini value that is not known, or a Gemini mode without key."""
        why = gemini.check(config.voice_mode, config.gemini_model, config.gemini_voice)
        if why:
            raise HTTPException(400, why)
        if self.gemini_only and config.voice_mode != "gemini-live" and (config.voice_mode or config.stt_engine or config.tts_engine):
            raise HTTPException(400, "This orb runs for Gemini Live only (scripts/dev.sh --gemini): choose Mode > "
                                     "Gemini Live, or restart scripts/dev.sh without --gemini for the orb pipeline.")
        if config.voice_mode == "gemini-live" and not self.gemini_available():
            raise HTTPException(400, f"Gemini Live needs {gemini.KEY} in the repo .env (a Gemini API key). "
                                     "Set it and restart scripts/dev.sh.")

    def warms(self, config: dict) -> bool:
        # a Gemini Live call never uses the LLM of the session: warming it would load gigabytes for nothing
        return config.get("voice_mode") != "gemini-live" and not self.gemini_only

    async def status(self) -> dict | None:
        voice, probe, livekit_probe = self.voice, self.probe, self.livekit_probe
        if voice is None:
            return None
        server = livekit_probe(voice.server) if livekit_probe else probe(*host_port(voice.server)) if probe else unknown()
        worker = probe("127.0.0.1", self.worker_port) if probe and self.worker_port else unknown()
        livekit, worker = await asyncio.gather(server, worker)
        return {"url": voice.url, "dev": voice.dev, "local": voice.local, "proxy": self.proxy, "livekit": livekit, "worker": worker}

    def models(self) -> dict:
        return {"available": self.gemini_available(), "only": self.gemini_only, "models": gemini.MODELS, "default_model": gemini.DEFAULT_MODEL,
                "voices": gemini.VOICES, "default_voice": gemini.DEFAULT_VOICE}

    def router(self, session_or_404) -> APIRouter:
        router = APIRouter()
        if self.proxy:
            router.include_router(livekit_proxy.make_router(self.voice.server))

        @router.get("/v1/voice/status")
        async def voice_state():  # light: the page asks for it each time that a person presses Talk
            return await self.status()

        @router.get("/v1/sessions/{sid}/instructions")
        async def instructions(sid: str):
            """The system prompt of a Gemini Live call: orb's prompt for the topic and its source, and the voice rules."""
            s = session_or_404(sid)
            if not hasattr(s, "realtime_prompt"):
                raise HTTPException(400, f"The agent of session {sid} has no prompt for Gemini Live.")
            await s.prepare(warm=False)  # the source named in the topic, when the session has not loaded it yet
            return {"instructions": s.realtime_prompt() + "\n" + gemini.VOICE_RULES.strip()}

        @router.post("/v1/voice/token")
        async def voice_token(body: VoiceIn):
            if self.voice is None:
                raise HTTPException(503, "Voice is off: set LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET.")
            s = session_or_404(body.session_id)
            identity = "user-" + secrets.token_hex(4)
            room = room_for(s.id)
            return {"url": self.voice.url, "room": room, "identity": identity, "token": self.voice.token(room, identity)}

        return router
