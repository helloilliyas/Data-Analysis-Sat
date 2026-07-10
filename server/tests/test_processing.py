import base64
import io

import pytest
from PIL import Image

from app import processing


def test_polygon_area(small_triangle, oversized_polygon):
    small = processing.polygon_area_sq_km(small_triangle)
    assert 0.05 < small < 0.3
    assert processing.polygon_area_sq_km(oversized_polygon) > 1000


def test_check_area_rejects_oversized(oversized_polygon):
    with pytest.raises(processing.ProcessingError, match="over the 100"):
        processing.check_area(oversized_polygon)


def test_check_area_rejects_non_polygon():
    with pytest.raises(processing.ProcessingError):
        processing.check_area({"type": "Point", "coordinates": [0, 0]})


def test_render_truecolor(synthetic_tci, small_triangle):
    image_b64, bounds = processing.render_truecolor(synthetic_tci, small_triangle)

    image = Image.open(io.BytesIO(base64.b64decode(image_b64)))
    assert image.format == "WEBP"
    assert image.mode == "RGBA"
    assert image.width > 10 and image.height > 10

    # Bbox corners lie outside the triangle → transparent; centroid opaque.
    alpha = image.getchannel("A")
    assert alpha.getpixel((0, 0)) == 0
    assert alpha.getpixel((image.width - 1, 0)) == 0
    center = alpha.getpixel((image.width // 2, image.height // 2))
    assert center == 255

    west, south, east, north = bounds
    assert west < 9.0 < east
    assert south < 45.0 < north
    assert east - west < 0.02 and north - south < 0.02


def test_render_no_overlap(synthetic_tci):
    far_away = {
        "type": "Polygon",
        "coordinates": [[
            [10.5, 45.0], [10.51, 45.0], [10.51, 45.01], [10.5, 45.0],
        ]],
    }
    with pytest.raises(processing.ProcessingError):
        processing.render_truecolor(synthetic_tci, far_away)
