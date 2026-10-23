#!/bin/sh
# Builds and runs the brightness calibration. Lumac is quit during the run, so it doesn't
# set the external display at the same time, and opened again afterwards.
set -e
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -O Sources/DDC.swift Sources/SoftwareDimmer.swift Sources/BuiltInBrightness.swift \
    Tools/brightness-calibration/main.swift -o build/brightness-calibration
osascript -e 'quit app "Lumac"' 2>/dev/null || true
status=0
./build/brightness-calibration "$@" || status=$?
open -a Lumac 2>/dev/null || true
exit $status
