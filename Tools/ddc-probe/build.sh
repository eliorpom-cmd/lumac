#!/bin/sh
# Builds the DDC probe from the app's DDC module into build/ddc-probe.
set -e
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -O Sources/DDC.swift Tools/ddc-probe/main.swift -o build/ddc-probe
echo "build/ddc-probe"
