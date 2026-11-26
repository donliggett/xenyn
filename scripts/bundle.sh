#!/usr/bin/env bash
# Builds Xenyn in release mode and wraps it in dist/Xenyn.app (ad-hoc signed).
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Xenyn.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Xenyn" "$APP/Contents/MacOS/Xenyn"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"

echo "Built $APP"
