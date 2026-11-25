# LibreFlow – browser version and Bluetooth tool

The same analysis as the [iPhone app](../README.md), as a single page for a Mac or PC, plus a command-line tool
that talks to the watch over Bluetooth.

![Latest Activity on a wide screen](../docs/screenshots/desktop-activity.png)

![Analysis on a wide screen](../docs/screenshots/desktop-analysis.png)

<img src="../docs/screenshots/settings.png" alt="Settings in the browser" width="320">

*Fictional demo data.* Try it yourself: open `libreflow.html#demo` (add `&view=trends`, `plan`, `runs` or `settings`).

## libreflow.html
Open it in Safari or Chrome (double-click it in the Finder) and load your Polar Flow export under **Settings**.

### What it shows
- **Latest Activity**: newest activity (older/newer), route on a map, splits, zones; *Edit* changes sport or shoes.
- **Analysis**: advice with its sources, charts, deeper analysis, predictions and records; all activities or one
  sport.
- **Running Plan**: adaptive training plan for a goal race, with the reasoning and sources per session.
- **All Activities**: list with a filter by sport.
- **Settings**, in order of use: shoes, training zones, heart rate, map, and *Your data* (import, backup, CSV, demo
  data, delete). Without any data, *Your data* comes first.

### Your data
- Imports the Polar Flow export (ZIP or unzipped folder), `training-session*.json` files, the `trainingen_json`
  folder from `polar_ble.py` and backups (ZIP, also from the app). Every import is added; duplicates are skipped.
- Data is kept only in this browser: local storage (summary) and IndexedDB (per-second data and routes).
  *Make backup* saves everything as a ZIP that the iPhone app can import too.
- Loads Chart.js, JSZip and Leaflet from cdnjs.cloudflare.com, and map tiles from openstreetmap.org (switch the map
  off under *Settings › Map* to draw routes without loading tiles). Your data itself is never sent anywhere.
- This page is the single source of the analysis: the app's version is generated from it
  (`tools/make_app_page.py`).

## polar_ble.py
Bluetooth tool (Polar's PSFTP protocol). Reading changes nothing on the watch (with `--sync` it also sends Polar's
sync start/stop notifications); only the write commands below change it, and each asks you to type WRITE or REMOVE
first.

### Setup
```
python3 -m pip install bleak
python3 polar_ble.py scan
python3 polar_ble.py --sync ls "Grit X" /U/0/
```
First time: put the watch in pairing mode (Settings › General settings › Pair and sync › Pair and sync phone) and
accept the pairing request. On macOS the address is a UUID; part of the name (`"Grit X"`) works too.
Terminal needs Bluetooth permission (System Settings › Privacy & Security › Bluetooth).

- macOS (CoreBluetooth): pairing, sync and reconnecting all work.
- Windows: pairing must happen in the same connection (`--pair`); reconnecting to the paired watch fails (link
  not encrypted, MTU 23, "Unreachable").

### Download all trainings
Resumable: interrupted? Just start again, it continues where it stopped.
```
python3 polar_ble.py --sync all "Grit X" --max 3     # trial run: 3 trainings
python3 polar_ble.py --sync all "Grit X"             # everything since 2023 (--since YYYYMMDD) -> horloge_data/
python3 polar_ble.py export                          # -> trainingen_json/ (with 1 s series, without GPS)
```
Then open `libreflow.html` › Settings › Your data › Choose folder › `trainingen_json`.
`export --full` also includes the GPS route. The earlier Dutch names (`alles`, `exporteer`, `--vanaf`,
`--volledig`) still work.

The folders it creates (`horloge_data/`, `horloge_dump/`, `trainingen_json/`) contain your trainings including
GPS routes: keep them private (they are in `.gitignore`).

### Writing to the watch
The iPhone app does all of this itself (Sync, *Settings › Routes*, *Training zones*, *Running Plan › Send to
watch*); these commands are the tested building blocks.
- **Routes**: `route-build` turns a GPX file into the watch's route files (offline); `route-put` writes them as a
  new route plus its favorite; `route-rm` lists the routes and removes a LibreFlow route, keeping the folders without
  gaps (`--fix-gaps` repairs a gap).
  ```
  python3 polar_ble.py route-build route.gpx route_out
  python3 polar_ble.py --sync route-put "Grit X" route_out
  python3 polar_ble.py --sync route-rm "Grit X"
  ```
- **Training zones**: `zones-put` replaces only the heart-rate and pace zone limits of the running profile
  (`--restore` writes the backup back).
- **Favorites**: `fav-put` writes one favorite to a new folder; `fav-rm` removes one that LibreFlow wrote.

Polar Flow's routes and favorites are never changed: LibreFlow's own use ids from 900000000 up.
