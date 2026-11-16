"""The room-to-session rule that the agent service and the voice worker share: the web page's room for a session is
orb-<session id>."""
from __future__ import annotations

import hashlib

from orb_core.agent import SESSION_ID

ROOM_PREFIX = "orb-"


def room_for(session_id: str) -> str:
    return ROOM_PREFIX + session_id


def session_for(room: str) -> str:
    """Rooms that the web page makes are orb-<session id>. Any other room gets a stable session of its own."""
    if room.startswith(ROOM_PREFIX) and SESSION_ID.match(room[len(ROOM_PREFIX):]):
        return room[len(ROOM_PREFIX):]
    return "room-" + hashlib.sha256(room.encode()).hexdigest()[:12]
