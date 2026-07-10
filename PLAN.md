# Minimal-Cost Satellite Mobile App — Plan (v2)

A Flutter Android app for drawing a land area, fetching Sentinel-2 imagery for
selected dates, running NDVI analysis, comparing two dates, and storing
everything locally on the phone. Near-zero running cost, no user accounts, no
permanent cloud storage. Tested directly on a Samsung S22 via sideloaded APK.

---

## 1. App technology

- **Flutter**, Android first. iOS can come later with the same codebase.
- Test on the Samsung S22 over USB (`flutter run`) and via sideloaded release APKs.
- No Play Store publishing during development.
- **Map widget:** prefer **`flutter_map`** over `maplibre_gl` for the MVP.
  - `flutter_map` is pure Dart, mature, and has good plugins for polygon
    drawing/editing, tile caching, and current-location markers — exactly the
    features this app needs.
  - `maplibre_gl` gives smoother vector rendering but polygon *editing* support
    is weak, and native plugin issues cost time on a solo project. Revisit it
    later if vector basemaps become important.
- **Basemap tiles:** do not hammer the public OpenStreetMap tile server from an
  app (its usage policy forbids it). Use a free-tier API key from **MapTiler**
  or **Stadia Maps** (both $0 at prototype volumes), with proper attribution.
- **Location search (geocoding):** Nominatim's public API is free — respect its
  policy (max 1 request/second, identify the app in the User-Agent, debounce
  search-as-you-type). Photon (komoot) is a good alternative.

## 2. Core app features

- Open map, jump to phone GPS position
- Search for a location by name
- Draw / edit a polygon area on the map (with vertex dragging and undo)
- Browse available Sentinel-2 acquisition dates for that area (with per-date
  cloud cover shown, so the user picks a usable date)
- View true-colour Sentinel-2 imagery cropped to the area
- Run NDVI vegetation analysis (cloud-masked, with summary statistics)
- Compare two dates: side-by-side, swipe slider, and a ΔNDVI change map
- Save projects locally; reopen and re-run later
- Export / restore a whole project as a ZIP file (via the Android share sheet)

**Guardrail:** cap the drawable area (e.g. 100 km²) client-side. It keeps
requests fast, images small, and protects the free compute budget.

## 3. Local mobile storage

- **SQLite** for project metadata. Use **Drift** (or `sqflite`) in Flutter.
  Store *file paths* in the database, never image blobs.
- Files live in the **app-private documents directory**
  (`path_provider` → `getApplicationDocumentsDirectory()`). On Android 11+
  scoped storage, this needs **no storage permissions**; a fixed
  `SatelliteApp/` folder on shared storage would. Exports reach the user
  through the share sheet (`share_plus`) or the system file picker (SAF).

```
<app documents dir>/
├── app.db                      # SQLite (Drift)
├── projects/
│   └── project_001/
│       ├── area.geojson        # the drawn polygon
│       ├── scenes.json         # STAC items used (id, date, cloud %)
│       ├── truecolor_<date>.webp
│       ├── ndvi_<date>.png     # 16-bit PNG, real NDVI values (analysis)
│       ├── ndvi_<date>.webp    # colour-rendered (display)
│       ├── results_<date>.json # stats: mean/min/max/histogram, valid-pixel %
│       └── report.pdf
├── tile_cache/                 # opportunistic basemap tile cache
└── exports/                    # staging area for ZIPs before sharing
```

Key change from v1: **keep raw NDVI values, not just a rendered image.** A
lossy WebP of a colour ramp destroys the data — you can't recompute statistics,
re-threshold, or build ΔNDVI from it later. Store a 16-bit PNG (or compressed
GeoTIFF) of values alongside the pretty WebP for display.

No user account, cloud database, or permanent cloud storage.

## 4. Free satellite data

- **Sentinel-2 L2A** (surface reflectance — already atmospherically corrected;
  don't use L1C) via the **AWS Earth Search STAC API**:
  `https://earth-search.aws.element84.com/v1`, collection `sentinel-2-l2a`.
- The scenes are **Cloud-Optimized GeoTIFFs (COGs)**, so the server reads only
  the byte ranges covering the drawn polygon — never whole scenes. For a small
  field this is kilobytes per band, not gigabytes.
- Bands needed: `red` (B04) and `nir` (B08) at 10 m for NDVI, `visual` (TCI)
  for true colour, `scl` (scene classification) for cloud masking.
- **Two Sentinel-2 gotchas to handle server-side:**
  1. *Radiometric offset:* scenes processed with baseline ≥ 04.00 (roughly
     everything since Jan 2022) carry a BOA offset. Check the STAC item's
     `earthsearch:boa_offset_applied` property and subtract the 1000 DN offset
     when it hasn't been applied, or NDVI values will be skewed.
  2. *Cloud cover is scene-level:* `eo:cloud_cover` describes the whole
     ~100×100 km scene. A "10 % cloudy" scene can be fully clouded over a small
     field. Compute **AOI-level** cloud fraction from the SCL band and use that
     for date ranking and for masking pixels in the NDVI result.
- Expectation setting: 10 m pixels and a ~5-day revisit. Fields under ~1 ha
  will only be a handful of pixels.

## 5. Processing (FastAPI on Modal)

A small, **stateless** FastAPI service on Modal (rasterio + numpy). Modal's
starter plan includes ~$30/month of free compute — far more than a prototype
needs. Cold starts of a few seconds are acceptable here.

Request (polygon as real GeoJSON, not a string):

```json
{
  "polygon": { "type": "Polygon", "coordinates": [...] },
  "date_range": "2026-06-01/2026-06-30",
  "analysis": "ndvi",            // "truecolor" | "ndvi" | "ndvi_compare"
  "compare_date_range": null,     // second range when analysis = ndvi_compare
  "max_cloud": 20
}
```

Response:

```json
{
  "scene": { "id": "S2B_...", "datetime": "...", "scene_cloud_pct": 12.4,
             "aoi_cloud_pct": 3.1, "boa_offset_applied": true },
  "display_webp_b64": "...",      // rendered image for the UI
  "values_png16_b64": "...",      // raw NDVI values (analysis-grade)
  "stats": { "mean": 0.62, "min": -0.05, "max": 0.89,
             "histogram": [...], "valid_pixel_pct": 96.9 },
  "bounds": [w, s, e, n]
}
```

The service:

1. Queries Earth Search for items intersecting the polygon in the date range.
2. Ranks candidates by **AOI cloud fraction** (from SCL), not scene cloud.
3. Windowed-reads only the AOI pixels from the COGs (HTTP range requests).
4. Applies the BOA offset if needed; computes NDVI; masks cloud/shadow pixels.
5. For `ndvi_compare`: processes both dates on the same pixel grid and also
   returns a ΔNDVI raster — alignment must happen server-side.
6. Compresses and returns; writes nothing durable (temp files die with the
   container).

**Guardrails on the endpoint:** require a static API-key header (the endpoint
is on the public internet and burns your compute credits), reject AOIs over
the size cap, and set a hard request timeout.

Also expose a cheap `GET /dates` endpoint that returns available acquisition
dates + cloud info for a polygon, so the date-picker UI doesn't need full
processing requests.

## 6. Development order

The main change from v1: **the Modal service moves up to Phase 2**, because
even "just show true-colour imagery for my polygon" needs the same
crop-from-COG pipeline as NDVI. Building it once, early, and adding analysis
types to it keeps Phase 3 small.

**Phase 1 — App skeleton (no network beyond basemap)**
- Flutter project, map screen (`flutter_map` + MapTiler/Stadia key)
- GPS location + Nominatim search
- Polygon draw/edit with area readout and the size cap
- Drift/SQLite schema: `projects`, `analyses` tables

**Phase 2 — Imagery online**
- Minimal Modal/FastAPI service: `/dates` + `analysis: "truecolor"`
- Date picker fed by `/dates`, showing per-date AOI cloud cover
- Display cropped true-colour imagery overlaid on the map

**Phase 3 — Analysis**
- Add `ndvi` and `ndvi_compare` to the service (SCL masking, BOA offset)
- NDVI display with colour ramp + legend + stats panel
- Comparison UI: side-by-side, swipe slider, ΔNDVI map

**Phase 4 — Projects & polish**
- Save/reopen projects; store rasters + stats per the layout in §3
- Export/restore project ZIPs via share sheet
- PDF reports (`pdf` + `printing` packages): map snapshot, dates, stats, images
- Cache/storage controls (view usage, clear per-project, clear tile cache)

## 7. Install the APK directly on the Samsung S22

Build:

```
flutter build apk --release --split-per-abi
```

`--split-per-abi` produces a much smaller APK; use
`app-arm64-v8a-release.apk` (the S22 is arm64) from
`build/app/outputs/flutter-apk/`.

Transfer via USB cable, Google Drive, email, Quick Share, or WhatsApp document
transfer. On the phone: open the APK → allow **Install unknown apps** for the
file manager/browser → Install.

For USB development testing (much faster iteration than sideloading):

```
flutter devices
flutter run
```

Enable on the phone: Settings → About phone → Software information → tap
**Build number** seven times → Developer options → enable **USB debugging**.

Note: a release APK signed with the default debug/dev key is fine for personal
sideloading; set up a proper keystore only if you later distribute it.

## 8. Estimated initial cost

| Component | Cost |
|---|---|
| Flutter, Dart tooling | $0 |
| Sentinel-2 L2A data (AWS open data) | $0 |
| Earth Search STAC API | $0 |
| Basemap tiles (MapTiler/Stadia free tier) | $0 |
| Geocoding (Nominatim, within usage policy) | $0 |
| SQLite / Drift, phone storage | $0 |
| Modal compute (within ~$30/mo free credit) | $0 |
| Direct APK installation | $0 |
| Play Store publishing | Not needed initially ($25 one-time, later) |

**Recommended stack:** Flutter + flutter_map (+ MapTiler/Stadia basemap) +
Drift/SQLite + app-private phone storage + AWS Earth Search (Sentinel-2 L2A
COGs) + FastAPI on Modal.

---

## Appendix — decisions worth recording

- **Server-side processing is the right call** despite COGs technically
  allowing client-side range reads: Dart has no mature rasterio equivalent,
  and reprojection/masking/alignment on-device would dominate the schedule.
- **Future analyses** drop into the same endpoint cheaply: NDWI (water),
  EVI/SAVI (vegetation, low-biomass), NDMI (moisture) are all band math on the
  same pipeline — hence the `analysis` enum rather than an NDVI-only API.
- **Offline maps** are deferred: bulk tile downloads have licensing
  implications per provider; opportunistic tile caching covers the realistic
  "revisit my field with poor signal" case.
