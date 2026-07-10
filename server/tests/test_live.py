"""Live smoke tests against the real Earth Search API and AWS COGs.

Run with:  pytest -m live
These need open egress (they run in CI; sandboxed dev environments may block
the hosts).
"""

import base64
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import main

pytestmark = pytest.mark.live

# Farmland near Dronten, NL — reliably inside Sentinel-2 coverage.
AOI = {
    "type": "Polygon",
    "coordinates": [[
        [5.66, 52.51], [5.70, 52.51], [5.70, 52.53], [5.66, 52.53], [5.66, 52.51],
    ]],
}
DATE_RANGE = "2026-04-01/2026-06-30"


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("API_KEY", raising=False)
    return TestClient(main.create_app())


def test_live_dates(client):
    response = client.post(
        "/dates", json={"polygon": AOI, "date_range": DATE_RANGE}
    )
    assert response.status_code == 200
    scenes = response.json()["scenes"]
    assert len(scenes) >= 3  # ~5-day revisit over 3 months
    assert all(s["id"].startswith("S2") for s in scenes)


def test_live_truecolor(client):
    response = client.post(
        "/process",
        json={
            "polygon": AOI,
            "analysis": "truecolor",
            "date_range": DATE_RANGE,
            "max_cloud": 40,
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    image = Image.open(io.BytesIO(base64.b64decode(body["image_b64"])))
    assert image.format == "WEBP"
    assert image.width > 100  # ~4 km wide AOI at 10 m
