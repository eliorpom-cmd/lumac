#!/bin/bash
# Builds a Developer ID signed, notarized and stapled DMG of Lumac.
#
# Usage: ./scripts/make-dmg.sh
# Environment (optional):
#   LUMAC_DMG_IDENTITY   codesigning identity (default: the Developer ID below)
#   LUMAC_NOTARY_PROFILE notarytool keychain profile (default: tbd-notary)
#   SKIP_NOTARIZE=1      sign only, skip notarization and stapling
#
# Output: build/dmg/Lumac-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${LUMAC_DMG_IDENTITY:-Developer ID Application: Bruno POMMIER (6388M5PCTC)}"
PROFILE="${LUMAC_NOTARY_PROFILE:-tbd-notary}"
VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
OUT=build/dmg
APP="$OUT/export/Lumac.app"
DMG="$OUT/Lumac-$VERSION.dmg"

echo "==> Lumac $VERSION"
# Previous output goes to the Trash rather than being deleted.
[ -e "$OUT" ] && trash "$OUT"
mkdir -p "$OUT/export"

echo "==> Generating the Xcode project"
xcodegen generate --quiet

echo "==> Building Release"
xcodebuild -project Lumac.xcodeproj -scheme Lumac -configuration Release \
  -derivedDataPath "$OUT/derived" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=6388M5PCTC \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

BUILT="$OUT/derived/Build/Products/Release/Lumac.app"
[ -d "$BUILT" ] || { echo "Build failed"; exit 1; }
ditto "$BUILT" "$APP"

echo "==> Signing the app (hardened runtime, timestamp)"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Creating the DMG"
STAGE="$OUT/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Lumac.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Lumac $VERSION" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "==> Skipping notarization"; echo "$DMG"; exit 0
fi

echo "==> Notarizing (profile $PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
# stapler sometimes fails with error 68 right after notarization: retry.
for i in 1 2 3 4 5; do
  if xcrun stapler staple "$DMG"; then break; fi
  [ "$i" = 5 ] && { echo "Stapling failed"; exit 1; }
  echo "stapler failed, retrying in 15 s ($i/5)"; sleep 15
done

echo "==> Checks"
xcrun stapler validate "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"
shasum -a 256 "$DMG"
echo "$DMG"
