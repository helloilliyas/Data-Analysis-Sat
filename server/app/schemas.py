from typing import Literal, Optional

from pydantic import BaseModel, Field


class DatesRequest(BaseModel):
    """List available Sentinel-2 scenes for an area and date range."""

    polygon: dict = Field(description="GeoJSON Polygon geometry, [lng, lat]")
    date_range: str = Field(
        description="ISO interval, e.g. 2026-06-01/2026-06-30",
        pattern=r"^\d{4}-\d{2}-\d{2}/\d{4}-\d{2}-\d{2}$",
    )
    max_cloud: float = Field(default=100, ge=0, le=100)


class SceneInfo(BaseModel):
    id: str
    datetime: str
    cloud_pct: float


class DatesResponse(BaseModel):
    scenes: list[SceneInfo]


class ProcessRequest(BaseModel):
    """Crop imagery / run analysis for an area.

    Either pass scene_id (picked from /dates) or a date_range, in which case
    the least-cloudy matching scene is used.
    """

    polygon: dict
    analysis: Literal["truecolor", "ndvi", "ndvi_compare"] = "truecolor"
    scene_id: Optional[str] = None
    date_range: Optional[str] = Field(
        default=None, pattern=r"^\d{4}-\d{2}-\d{2}/\d{4}-\d{2}-\d{2}$"
    )
    max_cloud: float = Field(default=20, ge=0, le=100)


class ProcessResponse(BaseModel):
    scene: SceneInfo
    analysis: str
    image_b64: str = Field(description="WebP (RGBA) rendered for display")
    bounds: list[float] = Field(description="[west, south, east, north] EPSG:4326")
