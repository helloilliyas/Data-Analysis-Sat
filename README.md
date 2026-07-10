# Data-Analysis-Sat

A minimal-cost mobile app for satellite land analysis: draw a land area on a
map, fetch Sentinel-2 imagery, run NDVI vegetation analysis, and compare
dates — with everything stored locally on the phone.

See [PLAN.md](PLAN.md) for the full architecture and phased roadmap.

## Layout

- `app/` — the Flutter Android app
- `server/` — FastAPI processing service, deployed on Modal
  (see [server/README.md](server/README.md))

Every push builds the APK and runs all tests on GitHub Actions — grab
`satellite-app-apk` from the workflow run's artifacts to install on a phone.

## Running the app (Phase 1)

```bash
cd app
flutter pub get
flutter run                 # with a connected Android device
```

Optional: pass a MapTiler key for production basemap tiles (falls back to
OpenStreetMap dev tiles without one):

```bash
flutter run --dart-define=MAPTILER_KEY=yourkey
```

Build a sideloadable APK for a Samsung S22 (arm64):

```bash
flutter build apk --release --split-per-abi
# install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

## Tests

```bash
cd app && flutter analyze && flutter test
```

## Status

Phase 1 — done
- [x] Map screen (flutter_map) with GPS locate and Nominatim location search
- [x] Polygon draw/edit (add / move / delete vertices, undo, clear) with live
      area readout and 100 km² cap
- [x] Local SQLite database (Drift): save, reopen, edit, delete projects

Phase 2 — done
- [x] FastAPI service: Earth Search STAC scene search + true-colour crops
      from Sentinel-2 COGs, Modal deploy wrapper, API-key + area guardrails
- [x] In-app date picker with per-scene cloud cover
- [x] True-colour overlay on the map with opacity control
- [x] Server settings screen (URL + API key, stored locally)
- [x] CI: tests + APK artifact on every push

Phase 3 — done
- [x] NDVI with SCL cloud masking and BOA offset handling, colour ramp,
      per-area stats, analysis-grade 16-bit values
- [x] Before/after comparison: ΔNDVI on a shared pixel grid
- [x] OSM paths & trails overlay (Overpass API), coloured by type

Phase 4 — next
- [ ] Persist analyses per project (files + results.json)
- [ ] Export/restore project ZIPs, PDF reports, storage controls
