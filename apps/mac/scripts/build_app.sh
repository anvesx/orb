#!/usr/bin/env bash
# Build orb.app into apps/mac/build: the release binary, its frameworks, the icon and Info.plist, then sign it.
#   scripts/build_app.sh          # build
#   scripts/build_app.sh --open   # build, then open the app
# It signs with the first "Apple Development" identity it finds, else ad hoc. An ad-hoc build changes its signature
# every time, so macOS asks again for the microphone and the Desktop folder.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product orb
BIN=.build/release
APP=build/orb.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/orb" "$APP/Contents/MacOS/orb"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for f in LiveKitWebRTC RustLiveKitFFI; do cp -R "$BIN/$f.framework" "$APP/Contents/Frameworks/"; done
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/orb"

ICONSET=$(mktemp -d)/orb.iconset
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/orb.icns"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
IDENTITY=${IDENTITY:--}
for f in "$APP"/Contents/Frameworks/*.framework; do codesign --force --sign "$IDENTITY" "$f"; done
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP (signed: ${IDENTITY/-/ad hoc})"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
