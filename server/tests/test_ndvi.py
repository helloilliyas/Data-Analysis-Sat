import base64
import io

import numpy as np
import pytest
from PIL import Image

from app import processing


def test_needs_boa_offset():
    assert not processing.needs_boa_offset(
        {"earthsearch:boa_offset_applied": True, "s2:processing_baseline": "05.00"}
    )
    assert processing.needs_boa_offset(
        {"earthsearch:boa_offset_applied": False, "s2:processing_baseline": "05.00"}
    )
    assert not processing.needs_boa_offset({"s2:processing_baseline": "03.01"})
    assert processing.needs_boa_offset({})  # unknown → assume modern


@pytest.fixture()
def ndvi_result(synthetic_bands, small_triangle):
    return processing.compute_ndvi(
        synthetic_bands["red"],
        synthetic_bands["nir"],
        synthetic_bands["scl"],
        small_triangle,
        apply_offset=True,
    )


def test_ndvi_values_with_offset(ndvi_result):
    values = ndvi_result.ndvi[ndvi_result.valid]
    assert values.size > 0
    # red 0.04, nir 0.44 → NDVI 0.8333
    assert values.mean() == pytest.approx(0.8333, abs=0.01)


def test_offset_matters(synthetic_bands, small_triangle):
    biased = processing.compute_ndvi(
        synthetic_bands["red"],
        synthetic_bands["nir"],
        synthetic_bands["scl"],
        small_triangle,
        apply_offset=False,
    )
    # Without removing the offset NDVI is diluted: (0.54-0.14)/(0.54+0.14).
    values = biased.ndvi[biased.valid]
    assert values.mean() == pytest.approx(0.588, abs=0.01)


def test_scl_cloud_masks_pixels(ndvi_result):
    # The synthetic SCL marks the northern quarter cloudy; the triangle's
    # apex reaches north, so some inside pixels must be excluded.
    assert ndvi_result.aoi_cloud_pct > 1
    stats = ndvi_result.stats()
    assert stats["valid_pixel_pct"] < 100
    assert stats["aoi_cloud_pct"] == pytest.approx(
        ndvi_result.aoi_cloud_pct, abs=0.11
    )
    assert sum(stats["histogram"]) == int(ndvi_result.valid.sum())


def test_render_and_values_roundtrip(ndvi_result):
    webp = processing.render_ndvi(ndvi_result)
    image = Image.open(io.BytesIO(base64.b64decode(webp)))
    assert image.mode == "RGBA"

    png16 = processing.encode_values_png16(ndvi_result)
    values = np.array(Image.open(io.BytesIO(base64.b64decode(png16))))
    assert values.dtype == np.uint16
    valid = values != 65535
    decoded = values[valid].astype(np.float64) / 10000 - 1
    assert decoded.mean() == pytest.approx(0.8333, abs=0.01)


def test_delta_between_dates(synthetic_bands, small_triangle, tmp_path):
    import rasterio

    # Build a second date with lower NIR (vegetation loss) on disk.
    with rasterio.open(synthetic_bands["nir"]) as src:
        profile = src.profile
        nir_b = src.read()
    nir_b[:] = 3000  # reflectance 0.2 → NDVI (0.2-0.04)/(0.24) = 0.6667
    nir_b_path = tmp_path / "nir_b.tif"
    with rasterio.open(nir_b_path, "w", **profile) as dst:
        dst.write(nir_b)

    a = processing.compute_ndvi(
        synthetic_bands["red"], synthetic_bands["nir"], synthetic_bands["scl"],
        small_triangle, apply_offset=True,
    )
    b = processing.compute_ndvi(
        synthetic_bands["red"], str(nir_b_path), synthetic_bands["scl"],
        small_triangle, apply_offset=True, grid=a.grid,
    )
    webp, delta = processing.render_delta(a, b)
    assert len(base64.b64decode(webp)) > 100
    values = delta.ndvi[delta.valid]
    assert values.mean() == pytest.approx(0.6667 - 0.8333, abs=0.01)
