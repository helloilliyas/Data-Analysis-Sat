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


def _write_tif(path, data, res):
    """Writes bands centered on the test point at the given resolution."""
    size = data.shape[-1]
    # Recompute origin per resolution so 10 m and 20 m rasters cover the
    # same ground extent, like real Sentinel-2 bands.
    cx, cy = Transformer.from_crs("EPSG:4326", UTM, always_xy=True).transform(
        CENTER_LON, CENTER_LAT
    )
    transform = from_origin(cx - size / 2 * res, cy + size / 2 * res, res, res)
    count = data.shape[0] if data.ndim == 3 else 1
    with rasterio.open(
        path,
        "w",
        driver="GTiff",
        width=size,
        height=size,
        count=count,
        dtype=data.dtype.name,
        crs=UTM,
        transform=transform,
    ) as dst:
        dst.write(data if data.ndim == 3 else data[np.newaxis])
    return str(path)


@pytest.fixture(scope="session")
def synthetic_tci(tmp_path_factory):
    """A 3-band uint8 GeoTIFF (2 km × 2 km at 10 m) mimicking a TCI asset."""
    data = np.zeros((3, 200, 200), dtype=np.uint8)
    data[0], data[1], data[2] = 60, 120, 40  # a flat green field
    return _write_tif(tmp_path_factory.mktemp("scenes") / "tci.tif", data, 10)


@pytest.fixture(scope="session")
def synthetic_bands(tmp_path_factory):
    """red/nir/scl assets over the same 2 km extent.

    DNs include the +1000 BOA offset: red 0.04, nir 0.44 reflectance →
    NDVI ≈ (0.44-0.04)/(0.44+0.04) = 0.8333. The SCL marks the northern
    quarter as cloud (class 9).
    """
    directory = tmp_path_factory.mktemp("bands")
    red = np.full((200, 200), 1400, dtype=np.uint16)  # (1400-1000)/1e4
    nir = np.full((200, 200), 5400, dtype=np.uint16)  # (5400-1000)/1e4
    scl = np.full((100, 100), 4, dtype=np.uint8)  # vegetation
    # Cloud (class 9) over the northern 40 rows (+1000 m … +200 m from the
    # center) so it overlaps the test triangle's northern apex (~+333 m).
    scl[:40, :] = 9
    return {
        "red": _write_tif(directory / "red.tif", red, 10),
        "nir": _write_tif(directory / "nir.tif", nir, 10),
        "scl": _write_tif(directory / "scl.tif", scl, 20),
    }


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
