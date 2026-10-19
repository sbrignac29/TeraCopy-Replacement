#!/bin/bash
# Builds VeriCopy.app from scratch: release binary, icon, bundle, ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Running engine self-tests"
swift run -c release vericopy-selftest

echo "==> Building release binary"
swift build -c release

echo "==> Rendering app icon"
mkdir -p build Resources
swift Scripts/make_icon.swift

echo "==> Assembling VeriCopy.app"
APP="VeriCopy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VeriCopy "$APP/Contents/MacOS/VeriCopy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Done: $(pwd)/$APP"
