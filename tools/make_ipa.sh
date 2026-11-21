#!/bin/zsh
# Builds an unsigned Release LibreFlow.ipa for SideStore (or another sideloading tool that signs the app itself).
# Output: build/LibreFlow.ipa (ignored by git). Run from anywhere: zsh tools/make_ipa.sh
# Uses a neutral bundle id (app.libreflow) and no team, so nothing from your Local.xcconfig ends up in the .ipa.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ project.yml -nt LibreFlow.xcodeproj/project.pbxproj ]] && command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
fi

xcodebuild -quiet -project LibreFlow.xcodeproj -scheme LibreFlow -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" PRODUCT_BUNDLE_IDENTIFIER=app.libreflow \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" build   # new build number each time, so iOS/SideStore see an update

APP="build/Build/Products/Release-iphoneos/LibreFlow.app"
STAGE="build/ipa"
rm -rf "$STAGE" build/LibreFlow.ipa
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
# remove debug symbols: they contain build paths on this Mac (including the user name)
xcrun strip -S -x "$STAGE/Payload/LibreFlow.app/LibreFlow"
if strings -a "$STAGE/Payload/LibreFlow.app/LibreFlow" | grep -q "$HOME"; then
  echo "error: the app binary still contains paths under $HOME" >&2; exit 1
fi
(cd "$STAGE" && zip -qr -X ../LibreFlow.ipa Payload)
rm -rf "$STAGE"

echo "Created $ROOT/build/LibreFlow.ipa ($(du -h build/LibreFlow.ipa | cut -f1))"
