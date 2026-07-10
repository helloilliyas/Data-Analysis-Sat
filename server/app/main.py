"""FastAPI service: Sentinel-2 scene listing and AOI-cropped imagery.

Stateless — nothing is written to disk; results stream back to the phone.
Guardrails (PLAN.md §5): optional API key, 100 km² area cap.
"""

import os

from fastapi import Depends, FastAPI, Header, HTTPException

from . import processing, stac
from .schemas import (
    DatesRequest,
    DatesResponse,
    ProcessRequest,
    ProcessResponse,
    SceneInfo,
)


def _require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    expected = os.environ.get("API_KEY", "")
    if expected and x_api_key != expected:
        raise HTTPException(status_code=401, detail="invalid or missing API key")


def _scene_info(item) -> SceneInfo:
    return SceneInfo(
        id=item.id,
        datetime=item.properties.get("datetime", ""),
        cloud_pct=float(item.properties.get("eo:cloud_cover", -1)),
    )


def create_app() -> FastAPI:
    app = FastAPI(title="Satellite Land Analysis processor", version="0.2.0")

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok"}

    @app.post("/dates", dependencies=[Depends(_require_api_key)])
    def dates(request: DatesRequest) -> DatesResponse:
        try:
            processing.check_area(request.polygon)
        except processing.ProcessingError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e
        items = stac.search_scenes(
            request.polygon, request.date_range, request.max_cloud
        )
        return DatesResponse(scenes=[_scene_info(i) for i in items])

    @app.post("/process", dependencies=[Depends(_require_api_key)])
    def process(request: ProcessRequest) -> ProcessResponse:
        try:
            processing.check_area(request.polygon)
        except processing.ProcessingError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

        if request.analysis != "truecolor":
            raise HTTPException(
                status_code=501,
                detail=f"analysis '{request.analysis}' arrives in Phase 3",
            )

        if request.scene_id:
            item = stac.get_scene(request.scene_id)
            if item is None:
                raise HTTPException(status_code=404, detail="scene not found")
        else:
            if not request.date_range:
                raise HTTPException(
                    status_code=400, detail="provide scene_id or date_range"
                )
            items = stac.search_scenes(
                request.polygon, request.date_range, request.max_cloud
            )
            if not items:
                raise HTTPException(
                    status_code=404,
                    detail="no scenes match the area, dates and cloud limit",
                )
            item = min(
                items, key=lambda i: i.properties.get("eo:cloud_cover", 101)
            )

        visual = item.assets.get("visual")
        if visual is None:
            raise HTTPException(
                status_code=502, detail="scene has no true-colour asset"
            )

        try:
            image_b64, bounds = processing.render_truecolor(
                visual.href, request.polygon
            )
        except processing.ProcessingError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

        return ProcessResponse(
            scene=_scene_info(item),
            analysis=request.analysis,
            image_b64=image_b64,
            bounds=bounds,
        )

    return app
