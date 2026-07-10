"""Raster processing: windowed COG reads cropped to the drawn area.

Everything is read via HTTP range requests — only the bytes covering the
polygon are fetched, never whole scenes (PLAN.md §4). All outputs are warped
to EPSG:3857 (Web Mercator) so they overlay correctly in flutter_map, and
multi-band/multi-date work shares one pixel grid so the math stays aligned.
"""

import base64
import io
import math

import numpy as np
import rasterio
from PIL import Image
from pyproj import Geod, Transformer
from rasterio import features, warp, windows
from rasterio.enums import Resampling
from rasterio.transform import array_bounds

MAX_AREA_SQ_KM = 100.0
MAX_DIM_PX = 1536

# Sentinel-2 L2A scene classification (SCL) values treated as unusable:
# 0 nodata, 1 saturated/defective, 3 cloud shadow, 8/9 cloud medium/high
# probability, 10 thin cirrus.
SCL_MASKED = (0, 1, 3, 8, 9, 10)
SCL_CLOUD = (3, 8, 9, 10)

# Sentinel-2 L2A digital numbers → reflectance: divide by 10000; scenes with
# processing baseline ≥ 04.00 carry a +1000 offset unless already removed.
BOA_OFFSET = 1000
BOA_SCALE = 10000.0

_GDAL_ENV = {
    "GDAL_DISABLE_READDIR_ON_OPEN": "EMPTY_DIR",
    "CPL_VSIL_CURL_ALLOWED_EXTENSIONS": ".tif,.tiff",
    "GDAL_HTTP_MULTIPLEX": "YES",
    "VSI_CACHE": "TRUE",
}


class ProcessingError(Exception):
    """User-facing processing failure (bad area, no coverage, ...)."""


def polygon_area_sq_km(polygon: dict) -> float:
    ring = polygon["coordinates"][0]
    lons = [c[0] for c in ring]
    lats = [c[1] for c in ring]
    area, _ = Geod(ellps="WGS84").polygon_area_perimeter(lons, lats)
    return abs(area) / 1e6


def check_area(polygon: dict) -> None:
    if polygon.get("type") != "Polygon" or not polygon.get("coordinates"):
        raise ProcessingError("polygon must be a GeoJSON Polygon geometry")
    area = polygon_area_sq_km(polygon)
    if area > MAX_AREA_SQ_KM:
        raise ProcessingError(
            f"area is {area:.1f} km², over the {MAX_AREA_SQ_KM:.0f} km² limit"
        )


def needs_boa_offset(properties: dict) -> bool:
    """Whether the scene's DNs still carry the +1000 BOA offset."""
    if properties.get("earthsearch:boa_offset_applied"):
        return False
    baseline = properties.get("s2:processing_baseline")
    try:
        return float(baseline) >= 4.0
    except (TypeError, ValueError):
        # Baseline unknown: assume modern data (post-2022 → offset present).
        return True


def _reproject_polygon(polygon: dict, dst_crs) -> dict:
    transformer = Transformer.from_crs("EPSG:4326", dst_crs, always_xy=True)
    rings = [
        [list(transformer.transform(lon, lat)) for lon, lat in ring]
        for ring in polygon["coordinates"]
    ]
    return {"type": "Polygon", "coordinates": rings}


def read_window_webmercator(
    href: str,
    polygon: dict,
    grid: tuple | None = None,
    resampling: Resampling = Resampling.bilinear,
):
    """Read the polygon's window from a COG, warped to EPSG:3857.

    Returns (array[bands, h, w], grid) where grid = (transform, width,
    height). Pass a previous call's grid to force byte-identical alignment
    across bands, resolutions (SCL is 20 m) and dates.
    """
    with rasterio.Env(**_GDAL_ENV):
        with rasterio.open(href) as src:
            poly_src = _reproject_polygon(polygon, src.crs)
            xs = [p[0] for p in poly_src["coordinates"][0]]
            ys = [p[1] for p in poly_src["coordinates"][0]]
            window = windows.from_bounds(
                min(xs), min(ys), max(xs), max(ys), src.transform
            )
            full = windows.Window(0, 0, src.width, src.height)
            try:
                window = window.intersection(full)
            except windows.WindowError as e:
                raise ProcessingError("area does not overlap this scene") from e
            window = window.round_offsets().round_lengths()
            if window.width < 1 or window.height < 1:
                raise ProcessingError("area is too small for this scene's pixels")

            data = src.read(window=window)
            win_transform = src.window_transform(window)
            src_bounds = windows.bounds(window, src.transform)

            if grid is None:
                dst_transform, dst_w, dst_h = warp.calculate_default_transform(
                    src.crs,
                    "EPSG:3857",
                    int(window.width),
                    int(window.height),
                    *src_bounds,
                )
                scale = max(dst_w, dst_h) / MAX_DIM_PX
                if scale > 1:
                    dst_transform, dst_w, dst_h = warp.calculate_default_transform(
                        src.crs,
                        "EPSG:3857",
                        int(window.width),
                        int(window.height),
                        *src_bounds,
                        dst_width=math.ceil(dst_w / scale),
                        dst_height=math.ceil(dst_h / scale),
                    )
                grid = (dst_transform, dst_w, dst_h)
            else:
                dst_transform, dst_w, dst_h = grid

            dest = np.zeros((data.shape[0], dst_h, dst_w), dtype=data.dtype)
            warp.reproject(
                source=data,
                destination=dest,
                src_transform=win_transform,
                src_crs=src.crs,
                dst_transform=dst_transform,
                dst_crs="EPSG:3857",
                resampling=resampling,
            )
            return dest, grid


def polygon_inside_mask(polygon: dict, grid) -> np.ndarray:
    """Boolean array, True inside the polygon."""
    transform, width, height = grid
    poly_3857 = _reproject_polygon(polygon, "EPSG:3857")
    return features.geometry_mask(
        [poly_3857], out_shape=(height, width), transform=transform, invert=True
    )


def bounds_wgs84(grid) -> list[float]:
    transform, width, height = grid
    left, bottom, right, top = array_bounds(height, width, transform)
    to_wgs = Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True)
    west, south = to_wgs.transform(left, bottom)
    east, north = to_wgs.transform(right, top)
    return [west, south, east, north]


def _encode_webp(rgb: np.ndarray, alpha: np.ndarray, quality: int = 85) -> str:
    rgba = np.dstack([*rgb, alpha]).astype(np.uint8)
    image = Image.fromarray(rgba)
    buffer = io.BytesIO()
    image.save(buffer, "WEBP", quality=quality)
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def render_truecolor(tci_href: str, polygon: dict) -> tuple[str, list[float]]:
    """Crop the scene's true-colour (TCI) asset to the polygon.

    Returns (webp_base64, [west, south, east, north]).
    """
    data, grid = read_window_webmercator(tci_href, polygon)
    if data.shape[0] < 3:
        raise ProcessingError("true-colour asset does not have 3 bands")
    alpha = polygon_inside_mask(polygon, grid).astype(np.uint8) * 255
    return _encode_webp([data[0], data[1], data[2]], alpha), bounds_wgs84(grid)


# --- NDVI ------------------------------------------------------------------

# Colour ramp for NDVI in [-1, 1]: water/bare browns → yellows → deep green.
_NDVI_STOPS = [-1.0, 0.0, 0.2, 0.4, 0.6, 1.0]
_NDVI_COLORS = [
    (110, 70, 40),
    (205, 185, 145),
    (230, 225, 120),
    (120, 190, 80),
    (35, 145, 55),
    (0, 90, 30),
]

# Diverging ramp for ΔNDVI in [-0.5, 0.5]: loss red → neutral → gain green.
_DELTA_STOPS = [-0.5, -0.1, 0.0, 0.1, 0.5]
_DELTA_COLORS = [
    (170, 30, 30),
    (235, 160, 130),
    (245, 245, 240),
    (150, 210, 150),
    (20, 130, 45),
]


def _apply_colormap(values: np.ndarray, stops, colors) -> list[np.ndarray]:
    clipped = np.clip(values, stops[0], stops[-1])
    return [
        np.interp(clipped, stops, [c[i] for c in colors]).astype(np.uint8)
        for i in range(3)
    ]


class NdviResult:
    """NDVI values plus masks on a shared grid — enough to render, summarise
    or difference against another date."""

    def __init__(self, ndvi, valid, cloud, inside, grid):
        self.ndvi = ndvi
        self.valid = valid  # data present + not cloud + inside polygon
        self.cloud = cloud  # cloudy per SCL (within data)
        self.inside = inside
        self.grid = grid

    @property
    def aoi_cloud_pct(self) -> float:
        denom = int(self.inside.sum())
        if denom == 0:
            return 0.0
        return float(self.cloud[self.inside].sum()) * 100.0 / denom

    def stats(self) -> dict:
        selected = self.ndvi[self.valid]
        denom = max(int(self.inside.sum()), 1)
        base = {
            "valid_pixel_pct": round(int(self.valid.sum()) * 100.0 / denom, 1),
            "aoi_cloud_pct": round(self.aoi_cloud_pct, 1),
        }
        if selected.size == 0:
            return {**base, "mean": None, "min": None, "max": None,
                    "histogram": []}
        hist, _ = np.histogram(selected, bins=20, range=(-1, 1))
        return {
            **base,
            "mean": round(float(selected.mean()), 3),
            "min": round(float(selected.min()), 3),
            "max": round(float(selected.max()), 3),
            "histogram": hist.tolist(),
        }


def compute_ndvi(
    red_href: str,
    nir_href: str,
    scl_href: str | None,
    polygon: dict,
    apply_offset: bool,
    grid: tuple | None = None,
) -> NdviResult:
    red_dn, grid = read_window_webmercator(red_href, polygon, grid=grid)
    nir_dn, _ = read_window_webmercator(nir_href, polygon, grid=grid)

    red_dn = red_dn[0].astype(np.float64)
    nir_dn = nir_dn[0].astype(np.float64)
    has_data = (red_dn > 0) & (nir_dn > 0)

    offset = BOA_OFFSET if apply_offset else 0
    red = np.maximum(red_dn - offset, 0) / BOA_SCALE
    nir = np.maximum(nir_dn - offset, 0) / BOA_SCALE

    denom = red + nir
    ndvi = np.zeros_like(red)
    ok = denom > 0
    ndvi[ok] = (nir[ok] - red[ok]) / denom[ok]
    ndvi = np.clip(ndvi, -1, 1)

    cloud = np.zeros(ndvi.shape, dtype=bool)
    if scl_href is not None:
        scl, _ = read_window_webmercator(
            scl_href, polygon, grid=grid, resampling=Resampling.nearest
        )
        cloud = np.isin(scl[0], SCL_CLOUD)
        has_data &= ~np.isin(scl[0], SCL_MASKED)

    inside = polygon_inside_mask(polygon, grid)
    valid = has_data & ok & inside
    return NdviResult(ndvi, valid, cloud, inside, grid)


def render_ndvi(result: NdviResult) -> str:
    rgb = _apply_colormap(result.ndvi, _NDVI_STOPS, _NDVI_COLORS)
    alpha = result.valid.astype(np.uint8) * 255
    return _encode_webp(rgb, alpha)


def render_delta(a: NdviResult, b: NdviResult) -> tuple[str, "NdviResult"]:
    """ΔNDVI = later (b) − earlier (a) on the shared grid."""
    if a.grid[1:] != b.grid[1:]:
        raise ProcessingError("comparison rasters are not on the same grid")
    delta = b.ndvi - a.ndvi
    valid = a.valid & b.valid
    cloud = a.cloud | b.cloud
    result = NdviResult(delta, valid, cloud, a.inside, a.grid)
    rgb = _apply_colormap(delta, _DELTA_STOPS, _DELTA_COLORS)
    alpha = valid.astype(np.uint8) * 255
    return _encode_webp(rgb, alpha), result


def encode_values_png16(result: NdviResult) -> str:
    """Analysis-grade values: uint16 PNG, value = (ndvi + 1) * 10000,
    nodata = 65535 (PLAN.md §3 — keep raw NDVI, not just the render)."""
    scaled = np.round((np.clip(result.ndvi, -1, 1) + 1) * 10000).astype(np.uint16)
    scaled[~result.valid] = 65535
    image = Image.fromarray(scaled)
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")
