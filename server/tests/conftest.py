import numpy as np
import pytest
import rasterio
from pyproj import Transformer
from rasterio.transform import from_origin

# Test area near (9.0E, 45.0N) — inside UTM zone 32N.
CENTER_LON, CENTER_LAT = 9.0, 45.0
UTM = "EPSG:32632"


@pytest.fixture(scope="session")
def utm_center():
    to_utm = Transformer.from_crs("EPSG:4326", UTM, always_xy=True)
    return to_utm.transform(CENTER_LON, CENTER_LAT)


@pytest.fixture(scope="session")
def synthetic_tci(tmp_path_factory, utm_center):
    """A 3-band uint8 GeoTIFF (2 km × 2 km at 10 m) mimicking a TCI asset."""
    cx, cy = utm_center
    size, res = 200, 10
    transform = from_origin(cx - size / 2 * res, cy + size / 2 * res, res, res)
    data = np.zeros((3, size, size), dtype=np.uint8)
    data[0], data[1], data[2] = 60, 120, 40  # a flat green field

    path = tmp_path_factory.mktemp("scenes") / "tci.tif"
    with rasterio.open(
        path,
        "w",
        driver="GTiff",
        width=size,
        height=size,
        count=3,
        dtype="uint8",
        crs=UTM,
        transform=transform,
    ) as dst:
        dst.write(data)
    return str(path)


@pytest.fixture()
def small_triangle():
    """~500 m triangle around the test center; corners of its bbox fall
    outside the polygon, which exercises the alpha mask."""
    d = 0.003
    return {
        "type": "Polygon",
        "coordinates": [[
            [CENTER_LON - d, CENTER_LAT - d],
            [CENTER_LON + d, CENTER_LAT - d],
            [CENTER_LON, CENTER_LAT + d],
            [CENTER_LON - d, CENTER_LAT - d],
        ]],
    }


@pytest.fixture()
def oversized_polygon():
    """~1° square ≈ 8800 km², far over the 100 km² cap."""
    return {
        "type": "Polygon",
        "coordinates": [[
            [8.0, 44.5], [9.0, 44.5], [9.0, 45.5], [8.0, 45.5], [8.0, 44.5],
        ]],
    }
