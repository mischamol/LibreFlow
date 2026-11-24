# LibreFlow – project context

See also `README.md` (the iPhone app, main product) and `web/README.md` (browser version + BLE tool). Personal, machine-specific details (device, signing team, data locations)
are in `CLAUDE.local.md`, which is not in git.

## Goal
- Analyse years of running data from a Polar watch (Grit X) locally and get advice, privacy first.
- iOS app with the same analyses, without Polar Flow/cloud, reading the watch directly over Bluetooth.
- Optional sharing to Strava, heart rate only by explicit choice, always with a preview.

## Preferences (important)
- Talk to the user in **Dutch**. All UI texts and documentation (app, `web/libreflow.html`, READMEs) in **English**.
- No external AI on the data. Advice is rule-based / on-device.
- Share nothing without permission. Process locally. Never commit personal data (watch downloads, exports, logs,
  signing settings): see `.gitignore`.
- Watch access is read-only: only GET operations. Never write/delete on the watch.
  The sync notifications (INITIALIZE_SESSION/START_SYNC/STOP_SYNC/TERMINATE_SESSION, as in the Polar BLE SDK) are
  approved by the user. Ask permission for any other message sent to the watch.
- The watch's own "sync" button is meant for Polar Flow and makes the watch wait for Flow; with the app the user
  just taps Sync in the app (the paired watch is found via `retrieveConnectedPeripherals` or scanning).
- Bluetooth commands of `web/polar_ble.py` on the Mac: Claude cannot run them (macOS TCC kills Python started by Claude).
  The user runs them in their own zsh terminal; never give a `!` prefix (zsh history expansion once emptied files via `tee`).

## Findings
- Proven: pairing, sync session, listing, downloading and decoding trainings (BASE/STATS/SAMPLES/ROUTE) on Windows,
  macOS (polar_ble.py) and iPhone (app). Windows cannot reconnect without pairing mode (MTU 23, "Unreachable").
- The watch keeps only a few complete trainings; the full history comes from the Polar Flow export (ZIP, imported
  directly in the app and in the Mac page).
- Polar running index: computed by the watch, stored in `00/BASE.BPB` field 9 › 1 (field 9 › 2 a duration); absent
  when the watch did not compute one. Matches Flow's `runningIndex`; read by both decoders.
- Sport names: the watch defines them in /SYS/SPORT/<id>/SPORT.BPB (field 1 › 1 id, field 2 › 1 parent, field 3 =
  translations {1 lang, 2 name}; no English entry). Verified ids: 1 running, 2 cycling, 3 walking, 5 mountain biking,
  7 downhill skiing, 11 hiking, 15 strength training, 16 other outdoor, 23 swimming, 27 trail running, 64 body & mind,
  82 multisport, 83 other indoor, 126 core, 127 mobility static. Other ids (e.g. 38) are shown as "unknown".
- Max speed (Flow's "max pace"): `00/STATS.BPB` field 2 {1 avg, 2 max} km/h; Flow `statistics SPEED max`.
- Favorites (read-only research, 23 Nov 2026): `/U/0/FAV/<nn>/TST.BPB` = `PbTrainingSessionTarget` (cmaion
  `training_session_target.proto`: 2 name, 6 exercise_target {1 type, 2 sport, 4 phases, 5 route id}) and `ID.BPB` =
  {1 id, 2 last_modified, 3 created (PbSystemDateTime)}; `/U/0/FAVCACHE.DAT` is a fixed-size binary index (not
  protobuf). Phased favorite decoded (from Polar Flow): exercise_target {1: 2 PHASED, 2: sport, 4: phases}, each
  phase {1 name, 2 change 1=automatic, 3 goal {1 type 1=time, 2 PbDuration {h,m,s,ms}}, 4 intensity {1 type
  1=sport (HR) zone, 2 zone {lower, upper}}, 5 repeat_count (extra repeats), 6 jump_index}; field 5 description.
  FAVCACHE.DAT = one 176-byte record per FAV folder: [0] 1, [1] folder index, [2..47] name (zero padded),
  [0x30] name length, [0x31] ? (1 for phased), [0x38] target type, [0x40] sport id, [0x58] route id,
  [0x60] uint32 total minutes (phased) or metres (route), [0x64] 0 = minutes / 1 = metres (hypothesis).
  Polar Flow rewrote FAV: new favorite at 00, existing one moved unchanged to 01, cache rebuilt in that order.
  Write test OK (23 Nov 2026, `fav-put`): a copy of the Flow favorite renamed "LibreFlow test" in new folder FAV/02/
  showed up on the watch, and the watch rebuilt FAVCACHE.DAT itself (3rd record: index 2, name, name length, the rest
  identical; [0x31] = 1 for phased). So only TST.BPB + ID.BPB need writing. Still unknown: distance-goal and
  speed-zone units, whether PUT overwrites an existing file, and whether a Polar Flow sync removes such favorites.
  Distance/pace test OK (23 Nov 2026, FAV/03 "LibreFlow dist test", built by hand, shown correctly on the watch):
  phase goal {1: 2 DISTANCE, 3: float metres}, intensity {1: 2 SPEED_ZONE, 3: speed_zone {1 lower, 2 upper} = zone
  numbers 1–5}, description field 5 {1 text}; recovery phase with repeat_count 2 / jump_index 2 loops back to the
  2nd phase (1-based) for 3 reps. Our favorites use ID values from 900000001 up (Flow's are ~84 million).
  Remove test (23 Nov 2026, `fav-rm 02`): files + folder removed fine (watch then sent D2H notification 0202), but the
  rebuilt FAVCACHE.DAT listed only FAV/00 and 01: FAV/03 after the gap was left out. Favorite folders must stay
  contiguous from 00 (as Polar Flow keeps them), so LibreFlow has to renumber its own folders when it removes some.
  Renumber test OK: fav-put of the same favorite to 02 + fav-rm 03 → cache 00/01/02 and the favorite visible again.
  Route favorites (type 3) do not appear in the watch's favorites list of trainings.
  Pace zones: Polar Flow only offers pace zone 1–5 in a favorite; the limits live in the sport profile
  /U/0/SPROF/<n>/PROFILE.BPB › 3 settings › 6 zone_limits › 2 speed_zone {1 lower, 2 upper} as float km/h (running =
  profile 0). Plan paces usually fall outside the user's narrow zones, so the idea is phase names with the target pace
  ("4:30/km – 1.6 km") plus distance goals / HR zones, without writing the sport profile. Next step (paused 23 Nov):
  read a Flow favorite with distance phases + pace zone 4 (fav_dump3) to confirm distance units and zone encoding.
  Zones write test OK (23 Nov 2026, `zones-put`): PUT overwrites an existing file; read-back identical; a training
  recorded afterwards used the new limits. Each training stores the zones it used in `00/ZONES.BPB`
  (`PbRecordedZones`: 1 HR zone {1 limits {lo, hi}, 2 time in zone}, 4 speed zone {1 limits {lo, hi km/h float},
  2 time, 3 distance}); the app keeps it under Documents/watch/<id>/00/. Whether a Polar Flow sync restores the
  Flow zones is still unknown.
  Writing (PSFTP PUT) is possible (SDK `PolarBleLowLevelApi.writeFile`) but NOT allowed without the user's explicit OK.
- Known caveats: altitude looks uncalibrated; BASE field 11 (~20 m) may be ascent or descent, not verified.
- Strava: file upload (TCX, manual at strava.com/upload/select) is free; the API (direct upload) needs a paid
  subscription. Both supported; the user has no subscription. In the app every run has Export… (GPX file via `GPXWriter`, TCX without GPS); with Settings › Strava on (default off) it becomes To Strava… (API upload). Settings › Privacy
  (`exportHeartRate` default off, `exportGPS` default on, UserDefaults) decides what exports/uploads contain.

## Files
- Layout: the iPhone app is the main product and lives at the repo root; the browser version and BLE tool are in
  `web/`. Screenshots in `docs/screenshots/` (demo data).
- `web/libreflow.html` – single source of the analysis page (English). Views: Latest Activity (newest run,
  older/newer, shoes choice, pace avg / max, running index vs. 8-week median), Analysis (advice at the top as compact
  expandable items with the top one open, KPIs, charts, deep analysis, predictions, records), All Activities (list),
  Running Plan (adaptive training plan, see below), Settings (Mac only: import, backup, HR settings, map, shoes).
  Training zones (`ZONES` {hr: 6 bpm limits | null, pace: 5 s/km limits slow→fast | null}, null = automatic; store +
  backups): auto HR from HRmax/rest/AeT/AnT (½max, AeT−10, AeT, mid, AnT, max), auto pace halfway between Daniels'
  paces (zone 1 recovery … 5 interval). Edited in the web Settings card and the app's Settings › Heart rate ›
  Training zones (`ZonesView`, bridge `appZones/appSetZones`); the plan shows each session's pace/HR zone.
  Send zones to watch (`BLE/WatchZones.swift`, `ProfileZones.swift`, `PolarWatch.put` with acknowledged frames): read
  /U/0/SPROF/0/PROFILE.BPB, preview old/new, write only after the user confirms (re-reads first, stops if changed),
  read back; zone 1 lower / zone 5 upper kept from the watch; first profile read saved as Documents/zones-backup/
  PROFILE-original.BPB (Restore). Byte-identical to `zones-put`, which was verified on the watch. One confirmation
  first (showing the zones), then one watch session reads, writes and verifies (no second confirm / second sync).
  Running Plan › Send to watch (`PlanToWatchView`, `WatchFavorites`, page `appPlanFavorites()`): next 7 days as
  phased favorites (distance goals, HR zones for easy parts, pace zones for fast parts; encoder byte-identical to the
  favorite verified on the watch); one confirmation, one session; LibreFlow favorites (id ≥ 900000000) are replaced
  or removed and renumbered so FAV stays gapless; Flow favorites are never touched.
  Sync Cancel: `PolarWatch.disconnect()` ends pending waits; the button resets at once.
  Plan: goal {dist 5k/10k/10mi/half/marathon/custom (+km), date, optional time, days/week, long-run day} in `PLAN` (store + backups).
  `buildPlan()` recomputes everything from the actual running on every refresh (volume from the 4-week average,
  +≤10%/week, lighter week every 4th week anchored to `PLAN.created`, long run ≤ +10% of the longest in 30 days,
  phases counted back from the race, taper per Bosquet, paces from current VDOT); this week's past sessions are
  marked done/missed and the rest shares the remaining distance. History (2 years, `planMetrics`): best 8-week average volume, active months (≥ 4 runs), best VDOT; experienced
  (≥ 12 of 24 months) → peak may aim for that volume and grow 15%/week while below 90% of it; no recent VDOT →
  best of 2 years × 0.93; regaining that VDOT counts in the target check (sources van Poppel 2021, Mujika 2000,
  Coyle 1984; marked as rule of thumb). Other distances: `goalSpec()` interpolates the parameters between the four `GOALS` anchors; > 42.2 km is
  treated as a marathon with an ultra warning and no VDOT prediction. Dates use calendar arithmetic (`addDays`), not ms, because of DST.
  Without history: `#vPlan` sits outside `#app` (works with 0 trainings; startup renders it); optional
  `goal.self` {km, long, m, sec} counts only for its window after `PLAN.created` (28/30/120 days) and only where
  the data shows less (`selfReport`). Per distance `longNeed` (long run worth reaching: 7/11/16/28 km) and `minPeak`
  (15/22/30/45 km/week) drive the feasibility check; the long run grows on its own (≤ +10%/week, ≤ half the week).
  After a short break (experienced, 4-week avg < 1/1.2 of weeks 5–8): start at 70% of the pre-break volume (`resume`).
  The last full week counts too (`fromLast`: experienced up to the best 8-week block, others ≤ 1.3× the 4-week avg),
  and for experienced runners a week ≤ 1.1× that block is no load spike (`usualWeek`). The page recomputes when the
  date changed (`catchUpDay` on view switch, visibilitychange and the app's scenePhase → `appResume`).
  Peak ≥ longNeed / 0.5 so the long run (≤ half the week) can reach longNeed; when it still cannot, the status says
  whether weekly distance or the 10%-per-week growth limits it. Beginners (not experienced, < 10 km/week): run/walk hint, start ~8 km/week; target-time check allows up to ~0.4
  VDOT/week for runners without history (Milanović 2015). Below 25 km/week no hard sessions; warm-up/cool-down 2 km below 35 km/week.
  Flags: load spike (ACWR > 1.3), efficiency drop
  (fatigue), ≥ 14 days off. Feasibility (time, volume, long run, target VDOT) → status, Analysis advice and an
  alert() once when it turns infeasible after a new activity; `PLAN.log` keeps the last 20 updates. Every session
  has a "Why" with numbered sources (`PLAN_SRC`). App tab 4 = page view `plan`.
  **Plan and Analysis must always use the same rules**: both take their signals from `trainingSignals(list, asOf)`
  (acute/chronic, block, experienced, load ratio vs max(4-week avg, block), gap49, effDrop, Banister form via
  `formSeries`) at the same moment (end of today; Analysis falls back to its last activity day when the data is > 28
  days old). The plan's flags: spike = ratio > 1.3, fatigue = effDrop or form < −40% (break-nuanced text). Change a
  rule there, never in one view only.
  Analysis advice uses the same history baseline (`analyse()` → `block` = best 8-week avg of 2 years, `experienced` =
  ≥ 12 of 24 months with ≥ 4 activities): load ratio and weekly jump compare with max(4-week avg, block) for
  experienced runners ("Back to your usual volume" when the plain ratio > 1.3 but vs. block ≤ 1.3), and the long-run
  share uses max(4-week avg, min(block, 2× 4-week avg)). Checked on the user's data: 47.3 km vs block 42.1 → 1.12. `analyse()` builds weeks
  with calendar days keyed by `ymdStr` (the old ms stepping lost weeks around DST: ~95 km/year in a test).
  Every Analysis advice shows "Based on: [n]" (`SRC_OF` maps titles to `PLAN_SRC` keys; list in the Advice card's
  Sources) or "Rule of thumb" where no study backs the exact limit. Fitness/fatigue = Banister impulse-response with
  TRIMP (Morton 1990; limits per Hellard 2006), 42/7-day constants are a software convention, the −20/−40% form
  limits a rule of thumb; after a 10+ day gap in the last 7 weeks it says "Fatigue after your break" (warn).
  Latest Activity / All Activities show every sport (speed km/h and no shoes for non-shoe sports; sport filter);
  Analysis has its own selector at the top (All activities, default, or one sport; `ANA_SPORT`, localStorage);
  pace-based parts (pace, efficiency, VDOT, predictions, best efforts, cadence) only use running sports. No sport
  toggles in Settings any more. Edit… per activity: sport, shoes, delete (stored as `edits`/`deleted`, which
  survive re-imports). Page alert()/confirm() are shown natively in the app (WKUIDelegate).
  Raw data per activity (full 1 s series + GPS route, `rawOf`) is kept apart from the summary: app files
  Documents/raw/<key>.json, browser IndexedDB `libreflow-raw`; backups are ZIPs (libreflow-backup.json + raw/). Route view:
  Leaflet + OpenStreetMap tiles (Leaflet shipped locally in the app; the app's content rule only lets
  tile.openstreetmap.org through) or, with Show map off, an SVG line. Older/Newer/Export are disabled when they cannot act. Shoes: brand/model/nickname, "in use since",
  default sports, reminder km (default 400), optional distance before tracking, retire/delete; runs auto-assigned to
  the newest default pair in use that day; stored as `gear`/`assign` in the store and backups. No tap/double-tap zoom
  (touch-action, 16px inputs on touch); pinch zoom kept. Computes compact per-second metrics at import (HR histogram,
  efficiency, decoupling, best 1/5/10/21 km, km splits, 30 s series) and keeps them in localStorage (~1.7 MB);
  the preview pane (data: URL) cannot store. In the app (`window.webkit.messageHandlers.libreflow`) storage, share,
  Strava and view switching go through the native side; the app's Settings tab uses
  `appSettings/appSetSettings/appCommand/appImportZip` and `appShoes/appSaveShoe/appDeleteShoe`.
- iPhone app "LibreFlow" at the root: `LibreFlow/` sources (SwiftUI, xcodegen `project.yml`; the `.xcodeproj` is generated and not in git).
  Native BLE PSFTP (`BLE/`), decoder/storage (`Training/`, identical to Python), Strava upload with the user's own
  Strava API app + TCX (`Strava/`). Tabs Latest Activity / Analysis / All Activities share one WKWebView (`WebSlot`), plus a
  native Settings tab. `LibreFlow/Web/index.html` is generated from `web/libreflow.html` by `tools/make_app_page.py`
  (pre-build step). Signing: `Local.xcconfig` (from `Local.xcconfig.example`). Build with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if xcode-select points to the Command Line Tools;
  install with `xcrun devicectl device install app`. Sync log on the phone: `Documents/sync-log.txt`
  (`devicectl device copy from --domain-type appDataContainer`).
- `web/polar_ble.py` – scan/services/ls/get/pull/explore/training/decode, `all` (bulk download, resumable, `index.json` +
  `.compleet` markers, `--since`, `--max`) and `export` (-> `trainingen_json/`, `--full` adds GPS). Options `--debug`,
  `--pair` (Windows only), `--sync`. `fav-put <addr> <dir> <nn>` is the only write: PUT of a new folder
  /U/0/FAV/<nn>/ with TST.BPB + ID.BPB, refuses existing folders, asks to type WRITE (approved by the user for one
  test on 23 Nov 2026; any further write use needs a new OK). `zones-put <addr> <backup> --hr 6 bpm --pace 4 min:sec`
  replaces only settings›zone_limits HR/speed zones of /U/0/SPROF/0/PROFILE.BPB (refuses if the watch file differs from
  the backup; zone 1 lower and zone 5 upper kept; reads back to verify; `--restore` writes the backup). Also needs
  the user's explicit OK per use. `fav-rm <addr> <nn>` REMOVEs (PbPFtpOperation command 3) the files and folder
  of one favorite, only when its ID.BPB id ≥ 900000000 (written by LibreFlow); asks to type REMOVE. Old Dutch names (`alles`, `exporteer`, `--vanaf`, `--volledig`) are aliases.
  Internal names in `horloge_data/` (`.compleet`, `gecontroleerde_dagen`) are kept for compatibility.

## Sources
- Polar BLE SDK: https://github.com/polarofficial/polar-ble-sdk (PSFTP in `BlePsFtpUtils.kt`/`BlePsFtpClient.kt`,
  sync in `BDBleApiImpl.kt`, `documentation/SyncImplementationGuideline.md`)
- File formats/protobufs: https://github.com/cmaion/polar (`lib/protobuf/*.proto`)
