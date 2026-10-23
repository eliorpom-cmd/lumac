#!/bin/zsh
# Builds Lumac, signs it, installs it in /Applications and launches it.
# Set LUMAC_SIGN_IDENTITY to a codesigning identity to keep "Open at login" valid across
# rebuilds; without it the app is signed ad hoc.
set -euo pipefail

cd "$(dirname "$0")"
APP="Lumac.app"

echo "→ Build"
xcodegen generate --quiet
xcodebuild -project Lumac.xcodeproj -scheme Lumac -configuration Release \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | tail -1

IDENTITY="${LUMAC_SIGN_IDENTITY:--}"
echo "→ Sign (${LUMAC_SIGN_IDENTITY:-ad hoc})"
codesign --force --options runtime --sign "$IDENTITY" "build/Build/Products/Release/$APP"

echo "→ Install /Applications/$APP"
pkill -x Lumac || true
ditto "build/Build/Products/Release/$APP" "/Applications/$APP"
open "/Applications/$APP"
echo "Done"
