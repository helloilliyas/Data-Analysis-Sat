# Processing service (FastAPI on Modal)

Stateless service that finds Sentinel-2 L2A scenes via the AWS Earth Search
STAC API and returns imagery cropped to the drawn area. Only the bytes
covering the area are read from the COGs (HTTP range requests) — never whole
scenes. Nothing is stored server-side.

## Endpoints

- `GET /health` — liveness.
- `POST /dates` — `{polygon, date_range, max_cloud?}` → available scenes with
  scene-level cloud cover, newest first. Feeds the app's date picker.
- `POST /process` — `{polygon, analysis, scene_id | date_range, max_cloud?}`.
  Phase 2 implements `analysis: "truecolor"`; `ndvi` / `ndvi_compare` return
  501 until Phase 3. Returns a base64 WebP (transparent outside the polygon)
  and its `[west, south, east, north]` bounds for the map overlay.

Guardrails: areas over 100 km² are rejected; if the `API_KEY` env var is set,
requests must send it in the `x-api-key` header.

## Deploy to Modal

```bash
pip install modal
modal setup                                             # one-time auth
modal secret create satellite-api API_KEY=$(openssl rand -hex 24)
modal deploy modal_app.py
```

Modal prints the public URL (like
`https://<workspace>--satellite-processor-web.modal.run`). In the app, open
**Settings** (gear icon) and paste the URL and the API key.

Prototype usage fits comfortably in Modal's free monthly compute credit.

## Run locally

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
API_KEY=dev .venv/bin/uvicorn "app.main:create_app" --factory --host 0.0.0.0 --port 8000
```

An Android phone on the same Wi-Fi can then use `http://<your-pc-ip>:8000`
as the server URL.

## Tests

```bash
.venv/bin/python -m pytest            # offline: synthetic rasters, mocked STAC
.venv/bin/python -m pytest -m live    # hits real Earth Search + AWS COGs
```
