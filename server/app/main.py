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

    def _resolve_scene(request: ProcessRequest):
        if request.scene_id:
            item = stac.get_scene(request.scene_id)
            if item is None:
                raise HTTPException(status_code=404, detail="scene not found")
            return item
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
        return min(items, key=lambda i: i.properties.get("eo:cloud_cover", 101))

    def _band_hrefs(item) -> tuple[str, str, str | None]:
        red = item.assets.get("red")
        nir = item.assets.get("nir")
        scl = item.assets.get("scl")
        if red is None or nir is None:
            raise HTTPException(
                status_code=502, detail="scene is missing red/nir bands"
            )
        return red.href, nir.href, scl.href if scl else None

    def _ndvi_for(item, polygon, grid=None) -> processing.NdviResult:
        red, nir, scl = _band_hrefs(item)
        return processing.compute_ndvi(
            red,
            nir,
            scl,
            polygon,
            apply_offset=processing.needs_boa_offset(item.properties),
            grid=grid,
        )

    @app.post("/process", dependencies=[Depends(_require_api_key)])
    def process(request: ProcessRequest) -> ProcessResponse:
        try:
            processing.check_area(request.polygon)
        except processing.ProcessingError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

        item = _resolve_scene(request)

        try:
            if request.analysis == "truecolor":
                visual = item.assets.get("visual")
                if visual is None:
                    raise HTTPException(
                        status_code=502, detail="scene has no true-colour asset"
                    )
                image_b64, bounds = processing.render_truecolor(
                    visual.href, request.polygon
                )
                return ProcessResponse(
                    scene=_scene_info(item),
                    analysis=request.analysis,
                    image_b64=image_b64,
                    bounds=bounds,
                )

            if request.analysis == "ndvi":
                result = _ndvi_for(item, request.polygon)
                return ProcessResponse(
                    scene=_scene_info(item),
                    analysis=request.analysis,
                    image_b64=processing.render_ndvi(result),
                    bounds=processing.bounds_wgs84(result.grid),
                    stats=result.stats(),
                    values_png16_b64=processing.encode_values_png16(result),
                )

            # ndvi_compare: A = request.scene_id (earlier), B = scene_id_b.
            if not request.scene_id_b:
                raise HTTPException(
                    status_code=400,
                    detail="ndvi_compare needs scene_id and scene_id_b",
                )
            item_b = stac.get_scene(request.scene_id_b)
            if item_b is None:
                raise HTTPException(status_code=404, detail="scene_b not found")

            result_a = _ndvi_for(item, request.polygon)
            result_b = _ndvi_for(item_b, request.polygon, grid=result_a.grid)
            image_b64, delta = processing.render_delta(result_a, result_b)
            return ProcessResponse(
                scene=_scene_info(item),
                scene_b=_scene_info(item_b),
                analysis=request.analysis,
                image_b64=image_b64,
                bounds=processing.bounds_wgs84(delta.grid),
                stats=delta.stats(),
                stats_a=result_a.stats(),
                stats_b=result_b.stats(),
                values_png16_b64=processing.encode_values_png16(delta),
            )
        except processing.ProcessingError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

    return app
