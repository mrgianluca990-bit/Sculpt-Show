#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/build-user-guide.py
swift test
swift build -c release --arch arm64 --arch x86_64 --product SculptShow
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
mkdir -p "dist/Sculpt Show.app/Contents/MacOS" "dist/Sculpt Show.app/Contents/Resources"
cp "$BIN_DIR/SculptShow" "dist/Sculpt Show.app/Contents/MacOS/SculptShow"
cp Scripts/Info.plist "dist/Sculpt Show.app/Contents/Info.plist"
test -s "Scripts/SculptShow.icns" || { echo "Missing macOS icon: Scripts/SculptShow.icns" >&2; exit 1; }
cp "Scripts/SculptShow.icns" "dist/Sculpt Show.app/Contents/Resources/SculptShow.icns"
test -s "dist/Sculpt Show.app/Contents/Resources/SculptShow.icns"
cp docs/SCULPT_SHOW_GUIDA_UTENTE_IT.html docs/SCULPT_SHOW_GUIDA_UTENTE_IT.md "dist/Sculpt Show.app/Contents/Resources/"
test -s "dist/Sculpt Show.app/Contents/Resources/SCULPT_SHOW_GUIDA_UTENTE_IT.html"
chmod +x "dist/Sculpt Show.app/Contents/MacOS/SculptShow"
codesign --force --deep --sign - "dist/Sculpt Show.app"
ditto -c -k --keepParent "dist/Sculpt Show.app" "dist/Sculpt-Show-macOS.zip"
echo "Built: dist/Sculpt-Show-macOS.zip"
