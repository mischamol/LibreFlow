# LibreFlow – iPhone app

An iPhone app that reads your Polar watch directly over Bluetooth, analyses your trainings and – only when you
choose to – sends a training to Strava, with or without heart rate.
No Polar Flow, no account, no cloud, no external AI. Everything stays on your iPhone.

## What is in it
- **Latest Run / Analysis / All Runs**: the same analysis as `libreflow.html` (generated from it at every build by
  `tools/make_app_page.py`; inside the app the page cannot load anything from the internet). Tabs **Latest Run** (your newest run, older/newer), **Analysis** (advice and
  charts) and **All Runs**. At the top: **Sync** (reads the watch: read-only plus
  Polar's sync notifications, new days only) and a button for the **sync log**.
  With *Settings › Strava* switched on, a run gets a *To Strava…* button.
- **Strava export** (off by default): preview with map, *Include heart rate* switch (**off** by default), then
  *Save file for Strava…* to upload yourself at strava.com/upload/select. Direct upload only with your own Strava API
  application (the Strava API may require a subscription).
- **Settings**: import (Polar export ZIP, backup, JSON), make backup, CSV, demo data, heart rate and thresholds,
  sports, connect Strava, forget watch, delete data.

## Installing without a paid developer account
1. Install **Xcode** from the Mac App Store and open it once (install the iOS platform when asked).
2. Xcode › Settings › Accounts › **+** › Apple ID: sign in with your normal Apple ID. A *Personal Team* appears.
3. In the `ios` folder: copy `Local.xcconfig.example` to `Local.xcconfig` and fill in your Team ID (Xcode › Settings ›
   Accounts › your Apple ID) and a unique bundle identifier. This file stays out of git.
4. Install XcodeGen (`brew install xcodegen`), run `xcodegen generate` in the `ios` folder, and open
   `ios/LibreFlow.xcodeproj` (generated, not in git).
5. Connect the iPhone with a cable, unlock it and tap *Trust This Computer*.
6. iPhone: Settings › Privacy & Security › **Developer Mode** on (the iPhone restarts).
7. Choose your iPhone as destination in Xcode and click **▶︎ (Run)**.
8. First time: iPhone › Settings › General › VPN & Device Management › your Apple ID › **Trust**. Then ▶︎ again.

Command line instead of Xcode's ▶︎ (from the `ios` folder):
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project LibreFlow.xcodeproj -scheme LibreFlow -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <iPhone UDID> build/Build/Products/Debug-iphoneos/LibreFlow.app
```

**Free account:** the app works for 7 days. Then connect the iPhone and install again. Your data is kept as long
as you do not delete the app. At most 3 self-installed apps at a time.

## First use
1. **Watch**: tap **Sync** in *Analysis*. If the watch is already paired with the iPhone you do not need to do
   anything on the watch (the watch's own sync button is meant for Polar Flow and makes the watch wait for
   Polar Flow). Never paired? Put the watch in pairing mode (Settings › General settings › Pair and sync ›
   Pair and sync phone) and accept the pairing request.
2. **History**: import the Polar export ZIP (account.polar.com › Download your data, ~75 MB) directly via
   *Settings › Import file…*. A backup made on the Mac (*Make backup*) works too.
3. **Strava (optional)**: see the main README › *Strava*: switch on *Settings › Strava*, save a run as a file and
   upload it at strava.com/upload/select.

## Troubleshooting
- The sync log is also written to `sync-log.txt` in the app's folder (Files app, or
  `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle id> --source Documents/sync-log.txt`).

## After changes
- Changed `libreflow.html`? Just build again (the app version is generated automatically).
- Changed `project.yml`? Run `xcodegen generate` in this folder first.
