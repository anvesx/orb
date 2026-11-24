"""Grounding (docs/design/screen-canvas.md section 3): where a described thing is on a screen frame.

The app sends a JPEG of the frame and a description; a Gemini vision model answers boxes as `box_2d`
([ymin, xmin, ymax, xmax], 0 to 1000). The key stays here: the app never holds one.
"""
from __future__ import annotations

import base64
import binascii
import io
import json
import os
import re
import time
from typing import Awaitable, Callable

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from orb_core import gemini

Locate = Callable[[bytes, str], Awaitable[str]]
Confirm = Callable[[bytes, str], Awaitable[bool]]

MODEL = "gemini-3.5-flash-lite"
MAX_IMAGE = 2_000_000
MAX_SHARE = 0.6  # a box over most of the screen is not "the thing"
SURE = 0.9  # an answer below this is checked on its crop
MARGIN = 0.15
PROMPT = ('Find on this screenshot: "{query}". Answer only JSON, a list of {{"found": true, "box_2d": [ymin, xmin, '
          'ymax, xmax], "label": "...", "confidence": 0.0 to 1.0}} with coordinates 0 to 1000, the best match first. '
          'An empty list when it is not on the screenshot: never box something else instead.')
CHECK = 'Is this picture "{query}" (or does it show it)? Answer only JSON: {{"yes": true}} or {{"yes": false}}.'


class GroundIn(BaseModel):
    image: str
    query: str = Field(min_length=1, max_length=200)
    strict: bool = False  # check every answer: a control that Accessibility did not find may not be there


def parse(raw: str) -> list[dict]:
    """The model's boxes, whatever the wrapper (a list, one object, a code fence), without impossible ones."""
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw.strip())
    try:
        data = json.loads(text)
    except ValueError:
        return []
    items = data if isinstance(data, list) else [data]
    return [box for item in items if isinstance(item, dict) and (box := checked(item)) is not None]


def checked(item: dict) -> dict | None:
    if item.get("found") is False:
        return None
    coords = item.get("box_2d", item.get("box"))
    if not (isinstance(coords, list) and len(coords) == 4 and all(isinstance(v, (int, float)) for v in coords)):
        return None
    y0, x0, y1, x1 = (int(min(max(v, 0), 1000)) for v in coords)
    if y1 <= y0 or x1 <= x0 or (y1 - y0) * (x1 - x0) > MAX_SHARE * 1_000_000:
        return None
    confidence = item.get("confidence")
    return {"box": [y0, x0, y1, x1], "label": str(item.get("label", ""))[:80],
            "confidence": min(max(float(confidence), 0.0), 1.0) if isinstance(confidence, (int, float)) else None}


def crop(image: bytes, box: list[int]) -> bytes:
    """The box of a JPEG frame and a margin around it, as a JPEG."""
    from PIL import Image

    img = Image.open(io.BytesIO(image))
    w, h = img.size
    y0, x0, y1, x1 = box
    my, mx = (y1 - y0) * MARGIN, (x1 - x0) * MARGIN
    area = (max(0, int((x0 - mx) * w / 1000)), max(0, int((y0 - my) * h / 1000)),
            min(w, round((x1 + mx) * w / 1000)), min(h, round((y1 + my) * h / 1000)))
    out = io.BytesIO()
    img.crop(area).convert("RGB").save(out, "JPEG", quality=85)
    return out.getvalue()


def gemini_model(model: str | None = None) -> tuple[Locate, Confirm] | None:
    """The real model's two questions (where is it, and is this it), or None without a key."""
    if not gemini.available():
        return None
    from google import genai
    from google.genai import types

    client = genai.Client()
    name = model or os.environ.get("ORB_GROUND_MODEL", MODEL)
    config = types.GenerateContentConfig(response_mime_type="application/json", temperature=0)

    async def ask(image: bytes, prompt: str) -> str:
        r = await client.aio.models.generate_content(
            model=name, contents=[types.Part.from_bytes(data=image, mime_type="image/jpeg"), prompt], config=config)
        return r.text or ""

    async def locate(image: bytes, query: str) -> str:
        return await ask(image, PROMPT.format(query=query))

    async def confirm(image: bytes, query: str) -> bool:
        try:
            return json.loads(await ask(image, CHECK.format(query=query))).get("yes") is True
        except (ValueError, AttributeError):
            return False

    return locate, confirm


def router(locate: Locate | None, confirm: Confirm | None) -> APIRouter:
    r = APIRouter()

    @r.post("/v1/ground")
    async def ground(body: GroundIn):
        if locate is None:
            raise HTTPException(503, f"Grounding needs {gemini.KEY} in the orb repo's .env.")
        try:
            image = base64.b64decode(body.image, validate=True)
        except (binascii.Error, ValueError):
            raise HTTPException(400, "image must be base64.")
        if not image.startswith(b"\xff\xd8") or len(image) > MAX_IMAGE:
            raise HTTPException(400, f"image must be a JPEG of at most {MAX_IMAGE} bytes.")
        t0 = time.perf_counter()
        try:
            raw = await locate(image, body.query)
        except Exception as e:
            raise HTTPException(502, f"The vision model failed: {type(e).__name__}: {e}")
        boxes = parse(raw)
        if confirm and boxes and (body.strict or (boxes[0]["confidence"] or 0) < SURE):
            try:
                kept = await confirm(crop(image, boxes[0]["box"]), body.query)
            except Exception as e:
                raise HTTPException(502, f"The vision model failed: {type(e).__name__}: {e}")
            boxes = boxes if kept else []
        return {"boxes": boxes, "ms": round((time.perf_counter() - t0) * 1000)}

    return r
