"""Raster processing: windowed COG reads cropped to the drawn area.

Everything is read via HTTP range requests — only the bytes covering the
polygon are fetched, never whole scenes (PLAN.md §4).
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


def _reproject_polygon(polygon: dict, dst_crs) -> dict:
    transformer = Transformer.from_crs("EPSG:4326", dst_crs, always_xy=True)
    rings = [
        [list(transformer.transform(lon, lat)) for lon, lat in ring]
        for ring in polygon["coordinates"]
    ]
    return {"type": "Polygon", "coordinates": rings}


def read_window_webmercator(href: str, polygon: dict):
    """Read the polygon's window from a COG and warp it to EPSG:3857.

    flutter_map renders in Web Mercator, so an image on a 3857 grid overlays
    correctly between its corner coordinates.

    Returns (array[bands, h, w] uint8-or-native, transform, "EPSG:3857").
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

            dst_transform, dst_w, dst_h = warp.calculate_default_transform(
                src.crs,
                "EPSG:3857",
                int(window.width),
                int(window.height),
                *src_bounds,
            )
            # Cap output size (a 100 km² AOI at 10 m is ~1000 px, usually
            # under the cap already).
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

            dest = np.zeros((data.shape[0], dst_h, dst_w), dtype=data.dtype)
            warp.reproject(
                source=data,
                destination=dest,
                src_transform=win_transform,
                src_crs=src.crs,
                dst_transform=dst_transform,
                dst_crs="EPSG:3857",
                resampling=Resampling.bilinear,
            )
            return dest, dst_transform, "EPSG:3857"


def polygon_alpha_mask(polygon: dict, shape, transform) -> np.ndarray:
    """255 inside the polygon, 0 outside (for transparent WebP corners)."""
    poly_3857 = _reproject_polygon(polygon, "EPSG:3857")
    inside = features.geometry_mask(
        [poly_3857], out_shape=shape, transform=transform, invert=True
    )
    return (inside * 255).astype(np.uint8)


def bounds_wgs84(shape, transform) -> list[float]:
    left, bottom, right, top = array_bounds(shape[0], shape[1], transform)
    to_wgs = Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True)
    west, south = to_wgs.transform(left, bottom)
    east, north = to_wgs.transform(right, top)
    return [west, south, east, north]


def encode_webp_rgba(rgb: np.ndarray, alpha: np.ndarray, quality: int = 85) -> str:
    rgba = np.dstack([rgb[0], rgb[1], rgb[2], alpha])
    image = Image.fromarray(rgba.astype(np.uint8))
    buffer = io.BytesIO()
    image.save(buffer, "WEBP", quality=quality)
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def render_truecolor(tci_href: str, polygon: dict) -> tuple[str, list[float]]:
    """Crop the scene's true-colour (TCI) asset to the polygon.

    Returns (webp_base64, [west, south, east, north]).
    """
    data, transform, _ = read_window_webmercator(tci_href, polygon)
    if data.shape[0] < 3:
        raise ProcessingError("true-colour asset does not have 3 bands")
    shape = (data.shape[1], data.shape[2])
    alpha = polygon_alpha_mask(polygon, shape, transform)
    return encode_webp_rgba(data[:3], alpha), bounds_wgs84(shape, transform)
