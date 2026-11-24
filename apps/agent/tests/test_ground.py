"""POST /v1/ground (docs/design/screen-canvas.md section 3): a screen frame and a description in, boxes out. The model is
a fake; nothing calls Google."""
import base64

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from orb_agent import ground

JPEG = base64.b64encode(b"\xff\xd8\xff\xe0 a frame").decode()


def client(answer: str | Exception):
    calls = []

    async def locate(image: bytes, query: str) -> str:
        calls.append((image, query))
        if isinstance(answer, Exception):
            raise answer
        return answer

    app = FastAPI()
    app.include_router(ground.router(locate))
    return TestClient(app), calls


@pytest.mark.parametrize("raw", [
    '[{"found": true, "box_2d": [243, 331, 292, 362], "label": "blue robot", "confidence": 0.9}]',
    '{"box_2d": [243, 331, 292, 362], "label": "blue robot", "confidence": 0.9}',
    '```json\n[{"box": [243, 331, 292, 362], "label": "blue robot", "confidence": 0.9}]\n```',
])
def test_the_models_answer_in_any_usual_shape_becomes_boxes(raw):
    c, calls = client(raw)
    r = c.post("/v1/ground", json={"image": JPEG, "query": "the blue robot"})
    assert r.status_code == 200
    assert r.json()["boxes"] == [{"box": [243, 331, 292, 362], "label": "blue robot", "confidence": 0.9}]
    assert calls[0][0].startswith(b"\xff\xd8") and calls[0][1] == "the blue robot"


def test_boxes_that_cannot_be_right_are_dropped():
    raw = ('[{"box_2d": [0, 0, 1000, 1000]}, {"box_2d": [500, 500, 400, 600]}, {"box_2d": [10, 20, 30]},'
           ' {"found": false, "box_2d": [1, 1, 50, 50]}, {"box_2d": [-5, 20, 40, 1200], "confidence": 7},'
           ' {"box_2d": [100, 100, 200, 300], "label": "ok"}]')
    boxes = client(raw)[0].post("/v1/ground", json={"image": JPEG, "query": "x"}).json()["boxes"]
    assert boxes == [{"box": [0, 20, 40, 1000], "label": "", "confidence": 1.0},
                     {"box": [100, 100, 200, 300], "label": "ok", "confidence": None}]


def test_nothing_found_is_an_empty_list():
    for raw in ("[]", "no idea", '{"boxes": "none"}'):
        assert client(raw)[0].post("/v1/ground", json={"image": JPEG, "query": "x"}).json()["boxes"] == []


def test_bad_input_is_refused_before_the_model():
    c, calls = client("[]")
    assert c.post("/v1/ground", json={"image": "not base64!", "query": "x"}).status_code == 400
    assert c.post("/v1/ground", json={"image": base64.b64encode(b"GIF89a").decode(), "query": "x"}).status_code == 400
    assert c.post("/v1/ground", json={"image": JPEG, "query": ""}).status_code == 422
    assert c.post("/v1/ground", json={"image": JPEG, "query": "x" * 201}).status_code == 422
    assert calls == []


def test_a_model_failure_is_a_502_with_the_reason():
    r = client(RuntimeError("quota"))[0].post("/v1/ground", json={"image": JPEG, "query": "x"})
    assert r.status_code == 502 and "quota" in r.json()["detail"]


def test_without_a_model_the_route_says_so():
    app = FastAPI()
    app.include_router(ground.router(None))
    r = TestClient(app).post("/v1/ground", json={"image": JPEG, "query": "x"})
    assert r.status_code == 503 and "GOOGLE_API_KEY" in r.json()["detail"]
