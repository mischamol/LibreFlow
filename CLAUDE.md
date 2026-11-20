# LibreFlow – project context

See also `README.md` and `ios/README.md`. Personal, machine-specific details (device, signing team, data locations)
are in `CLAUDE.local.md`, which is not in git.

## Goal
- Analyse years of running data from a Polar watch (Grit X) locally and get advice, privacy first.
- iOS app with the same analyses, without Polar Flow/cloud, reading the watch directly over Bluetooth.
- Optional sharing to Strava, heart rate only by explicit choice, always with a preview.

## Preferences (important)
- Talk to the user in **Dutch**. All UI texts and documentation (app, `libreflow.html`, READMEs) in **English**.
- No external AI on the data. Advice is rule-based / on-device.
- Share nothing without permission. Process locally. Never commit personal data (watch downloads, exports, logs,
  signing settings): see `.gitignore`.
- Watch access is read-only: only GET operations. Never write/delete on the watch.
  The sync notifications (INITIALIZE_SESSION/START_SYNC/STOP_SYNC/TERMINATE_SESSION, as in the Polar BLE SDK) are
  approved by the user. Ask permission for any other message sent to the watch.
- The watch's own "sync" button is meant for Polar Flow and makes the watch wait for Flow; with the app the user
  just taps Sync in the app (the paired watch is found via `retrieveConnectedPeripherals` or scanning).
- Bluetooth commands of `polar_ble.py` on the Mac: Claude cannot run them (macOS TCC kills Python started by Claude).
  The user runs them in their own zsh terminal; never give a `!` prefix (zsh history expansion once emptied files via `tee`).

## Findings
- Proven: pairing, sync session, listing, downloading and decoding trainings (BASE/STATS/SAMPLES/ROUTE) on Windows,
  macOS (polar_ble.py) and iPhone (app). Windows cannot reconnect without pairing mode (MTU 23, "Unreachable").
- The watch keeps only a few complete trainings; the full history comes from the Polar Flow export (ZIP, imported
  directly in the app and in the Mac page).
- Polar running index: computed by the watch, stored in `00/BASE.BPB` field 9 › 1 (field 9 › 2 a duration); absent
  when the watch did not compute one. Matches Flow's `runningIndex`; read by both decoders.
- Max speed (Flow's "max pace"): `00/STATS.BPB` field 2 {1 avg, 2 max} km/h; Flow `statistics SPEED max`.
- Known caveats: altitude looks uncalibrated; BASE field 11 (~20 m) may be ascent or descent, not verified.
- Strava: file upload (TCX, manual at strava.com/upload/select) is free; the API (direct upload) needs a paid
  subscription. Both supported; the user has no subscription. In the app every run has Export… (GPX file via `GPXWriter`, TCX without GPS); with Settings › Strava on (default off) it becomes To Strava… (API upload).

## Files
- `libreflow.html` – single source of the analysis page (English). Views: Latest Run (newest run,
  older/newer, shoes choice, pace avg / max, running index vs. 8-week median), Analysis (advice at the top as compact
  expandable items with the top one open, KPIs, charts, deep analysis, predictions, records), All Runs (list),
  Settings (Mac only: import, backup, HR settings, sports, shoes). Shoes: brand/model/nickname, "in use since",
  default sports, reminder km (default 400), optional distance before tracking, retire/delete; runs auto-assigned to
  the newest default pair in use that day; stored as `gear`/`assign` in the store and backups. No tap/double-tap zoom
  (touch-action, 16px inputs on touch); pinch zoom kept. Computes compact per-second metrics at import (HR histogram,
  efficiency, decoupling, best 1/5/10/21 km, km splits, 30 s series) and keeps them in localStorage (~1.7 MB);
  the preview pane (data: URL) cannot store. In the app (`window.webkit.messageHandlers.libreflow`) storage, share,
  Strava and view switching go through the native side; the app's Settings tab uses
  `appSettings/appSetSettings/appCommand/appImportZip` and `appShoes/appSaveShoe/appDeleteShoe`.
- `ios/` – iPhone app "LibreFlow" (SwiftUI, xcodegen `project.yml`; the `.xcodeproj` is generated and not in git).
  Native BLE PSFTP (`BLE/`), decoder/storage (`Training/`, identical to Python), Strava upload with the user's own
  Strava API app + TCX (`Strava/`). Tabs Latest Run / Analysis / All Runs share one WKWebView (`WebSlot`), plus a
  native Settings tab. `Web/index.html` is generated from `libreflow.html` by `ios/tools/make_app_page.py`
  (pre-build step). Signing: `ios/Local.xcconfig` (from `Local.xcconfig.example`). Build with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if xcode-select points to the Command Line Tools;
  install with `xcrun devicectl device install app`. Sync log on the phone: `Documents/sync-log.txt`
  (`devicectl device copy from --domain-type appDataContainer`).
- `polar_ble.py` – scan/services/ls/get/pull/explore/training/decode, `all` (bulk download, resumable, `index.json` +
  `.compleet` markers, `--since`, `--max`) and `export` (-> `trainingen_json/`, `--full` adds GPS). Options `--debug`,
  `--pair` (Windows only), `--sync`. Old Dutch names (`alles`, `exporteer`, `--vanaf`, `--volledig`) are aliases.
  Internal names in `horloge_data/` (`.compleet`, `gecontroleerde_dagen`) are kept for compatibility.

## Sources
- Polar BLE SDK: https://github.com/polarofficial/polar-ble-sdk (PSFTP in `BlePsFtpUtils.kt`/`BlePsFtpClient.kt`,
  sync in `BDBleApiImpl.kt`, `documentation/SyncImplementationGuideline.md`)
- File formats/protobufs: https://github.com/cmaion/polar (`lib/protobuf/*.proto`)
