#!/bin/bash
# Builds "Rekordbox to Serato.app" into ./build
#   ./build-app.sh            build the app
#   ./build-app.sh --package  also create build/Rekordbox-to-Serato-<version>.zip and .dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.1.1"
BUILD_NUMBER="2"
APP_NAME="Rekordbox to Serato"
PACKAGE=false
[ "${1:-}" = "--package" ] && PACKAGE=true

# Full Xcode: universal binary (Apple Silicon + Intel). Command Line Tools only: native build.
if xcodebuild -version >/dev/null 2>&1; then
  ARCHS=(--arch arm64 --arch x86_64)
else
  ARCHS=()
  [ -d /Library/Developer/CommandLineTools ] && export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release --product RekordboxToSerato ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release --show-bin-path ${ARCHS[@]+"${ARCHS[@]}"})"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RekordboxToSerato" "$APP/Contents/MacOS/RekordboxToSerato"

# SwiftPM records the deployment target as the SDK version. macOS 26+ uses the recorded SDK
# version to decide whether an app gets Liquid Glass, so stamp the real SDK version while
# keeping macOS 14 as the minimum (runs on Sonoma/Sequoia).
SDK_VERSION="$(xcrun --show-sdk-version)"
xcrun vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/RekordboxToSerato.tmp" "$APP/Contents/MacOS/RekordboxToSerato"
mv "$APP/Contents/MacOS/RekordboxToSerato.tmp" "$APP/Contents/MacOS/RekordboxToSerato"

# App icon (regenerate artwork with: swift Icon/make-icon.swift)
#  • With Xcode: compile the Liquid Glass icon (Icon/AppIcon.icon) into Assets.car.
#    macOS 26+ shows it as Liquid Glass; actool also generates the flat icon older macOS uses.
#  • Without Xcode's actool: fall back to the classic icon as a plain .icns.
[ -d Icon/AppIcon.icon ] || swift Icon/make-icon.swift Icon
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool --output-format human-readable-text --errors --warnings \
    --output-partial-info-plist build/icon-partial.plist --app-icon AppIcon --include-all-app-icons \
    --target-device mac --minimum-deployment-target 14.0 --platform macosx \
    --compile "$APP/Contents/Resources" Icon/AppIcon.icon >/dev/null
  rm -f build/icon-partial.plist
else
  ICONSET="build/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  cp Icon/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>local.rekordbox-to-serato</string>
  <key>CFBundleExecutable</key><string>RekordboxToSerato</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHumanReadableCopyright</key><string>Licensed under the GNU GPL v3.0 or later</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"   # no Finder/quarantine metadata in the bundle (keeps the zip clean)
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/RekordboxToSerato"))"

if $PACKAGE; then
  BASE="build/Rekordbox-to-Serato-$VERSION"
  rm -f "$BASE.zip" "$BASE.dmg"
  ditto -c -k --norsrc --keepParent "$APP" "$BASE.zip"
  STAGE="build/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$BASE.dmg"
  rm -rf "$STAGE"
  echo "Packaged: $BASE.zip, $BASE.dmg"
fi
