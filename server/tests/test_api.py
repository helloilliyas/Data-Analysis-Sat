import base64

import pytest
from fastapi.testclient import TestClient

from app import main, stac


class FakeAsset:
    def __init__(self, href):
        self.href = href


class FakeItem:
    def __init__(self, item_id, cloud, href=None, date="2026-06-15T10:30:00Z",
                 bands=None):
        self.id = item_id
        self.properties = {
            "datetime": date,
            "eo:cloud_cover": cloud,
            "earthsearch:boa_offset_applied": False,
            "s2:processing_baseline": "05.11",
        }
        self.assets = {"visual": FakeAsset(href)} if href else {}
        for name, band_href in (bands or {}).items():
            self.assets[name] = FakeAsset(band_href)


@pytest.fixture()
def client(monkeypatch, synthetic_tci, synthetic_bands):
    scenes = [
        FakeItem("S2A_TEST_1", 42.0, synthetic_tci, "2026-06-20T10:30:00Z",
                 bands=synthetic_bands),
        FakeItem("S2B_TEST_2", 7.5, synthetic_tci, "2026-06-15T10:30:00Z",
                 bands=synthetic_bands),
    ]
    monkeypatch.setattr(stac, "search_scenes", lambda *a, **k: scenes)
    monkeypatch.setattr(
        stac,
        "get_scene",
        lambda scene_id: next((s for s in scenes if s.id == scene_id), None),
    )
    monkeypatch.delenv("API_KEY", raising=False)
    return TestClient(main.create_app())


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_dates(client, small_triangle):
    response = client.post(
        "/dates",
        json={"polygon": small_triangle, "date_range": "2026-06-01/2026-06-30"},
    )
    assert response.status_code == 200
    scenes = response.json()["scenes"]
    assert [s["id"] for s in scenes] == ["S2A_TEST_1", "S2B_TEST_2"]
    assert scenes[1]["cloud_pct"] == 7.5


def test_dates_rejects_oversized_area(client, oversized_polygon):
    response = client.post(
        "/dates",
        json={"polygon": oversized_polygon, "date_range": "2026-06-01/2026-06-30"},
    )
    assert response.status_code == 400
    assert "km²" in response.json()["detail"]


def test_process_by_scene_id(client, small_triangle):
    response = client.post(
        "/process",
        json={
            "polygon": small_triangle,
            "analysis": "truecolor",
            "scene_id": "S2B_TEST_2",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["scene"]["id"] == "S2B_TEST_2"
    assert len(base64.b64decode(body["image_b64"])) > 100
    west, south, east, north = body["bounds"]
    assert west < east and south < north


def test_process_picks_least_cloudy(client, small_triangle):
    response = client.post(
        "/process",
        json={
            "polygon": small_triangle,
            "analysis": "truecolor",
            "date_range": "2026-06-01/2026-06-30",
        },
    )
    assert response.status_code == 200
    assert response.json()["scene"]["id"] == "S2B_TEST_2"


def test_process_unknown_scene(client, small_triangle):
    response = client.post(
        "/process",
        json={"polygon": small_triangle, "scene_id": "NOPE"},
    )
    assert response.status_code == 404


def test_process_ndvi(client, small_triangle):
    response = client.post(
        "/process",
        json={
            "polygon": small_triangle,
            "analysis": "ndvi",
            "scene_id": "S2B_TEST_2",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["analysis"] == "ndvi"
    assert 0.8 < body["stats"]["mean"] < 0.87
    assert body["stats"]["aoi_cloud_pct"] > 0
    assert len(base64.b64decode(body["image_b64"])) > 100
    assert len(base64.b64decode(body["values_png16_b64"])) > 100


def test_process_ndvi_compare(client, small_triangle):
    response = client.post(
        "/process",
        json={
            "polygon": small_triangle,
            "analysis": "ndvi_compare",
            "scene_id": "S2B_TEST_2",
            "scene_id_b": "S2A_TEST_1",
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["scene"]["id"] == "S2B_TEST_2"
    assert body["scene_b"]["id"] == "S2A_TEST_1"
    # Identical synthetic dates → ΔNDVI ≈ 0.
    assert abs(body["stats"]["mean"]) < 0.01
    assert body["stats_a"]["mean"] == pytest.approx(
        body["stats_b"]["mean"], abs=0.001
    )


def test_ndvi_compare_requires_second_scene(client, small_triangle):
    response = client.post(
        "/process",
        json={
            "polygon": small_triangle,
            "analysis": "ndvi_compare",
            "scene_id": "S2B_TEST_2",
        },
    )
    assert response.status_code == 400


def test_api_key_enforced(monkeypatch, client, small_triangle):
    monkeypatch.setenv("API_KEY", "sekrit")
    body = {"polygon": small_triangle, "date_range": "2026-06-01/2026-06-30"}

    assert client.post("/dates", json=body).status_code == 401
    ok = client.post("/dates", json=body, headers={"x-api-key": "sekrit"})
    assert ok.status_code == 200
