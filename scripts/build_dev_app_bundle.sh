#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_NAME="MinuteWave"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
EXECUTABLE_PATH="$BUILD_DIR/$APP_NAME"
RESOURCE_BUNDLE_PATH="$BUILD_DIR/${APP_NAME}_AINoteTakerApp.resources"
APP_BUNDLE_PATH="$ROOT_DIR/.build/AppBundle/${APP_NAME}.app"
PLIST_TEMPLATE_PATH="$ROOT_DIR/Sources/AINoteTakerApp/Resources/AppInfo.plist"
ICON_SOURCE_PATH_CLEAN="$ROOT_DIR/icon-clean.png"
ICON_SOURCE_PATH_TRANSPARENT="$ROOT_DIR/icon-removebg-preview.png"
ICON_SOURCE_PATH_DEFAULT="$ROOT_DIR/icon.png"
if [[ -f "$ICON_SOURCE_PATH_CLEAN" ]]; then
  ICON_SOURCE_PATH="$ICON_SOURCE_PATH_CLEAN"
elif [[ -f "$ICON_SOURCE_PATH_TRANSPARENT" ]]; then
  ICON_SOURCE_PATH="$ICON_SOURCE_PATH_TRANSPARENT"
else
  ICON_SOURCE_PATH="$ICON_SOURCE_PATH_DEFAULT"
fi
ICONSET_DIR="$ROOT_DIR/.build/IconSet.iconset"
ICON_ICNS_PATH="$ROOT_DIR/.build/MinuteWave.icns"

if [[ ! -f "$PLIST_TEMPLATE_PATH" ]]; then
  echo "Info.plist template not found: $PLIST_TEMPLATE_PATH" >&2
  exit 1
fi

echo "Building executable ($CONFIGURATION)..."
swift build -c "$CONFIGURATION"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Executable not found after build: $EXECUTABLE_PATH" >&2
  exit 1
fi

echo "Creating app bundle at: $APP_BUNDLE_PATH"
rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$APP_BUNDLE_PATH/Contents/MacOS"
mkdir -p "$APP_BUNDLE_PATH/Contents/Resources"

cp "$EXECUTABLE_PATH" "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME"
cp "$PLIST_TEMPLATE_PATH" "$APP_BUNDLE_PATH/Contents/Info.plist"

if [[ -d "$RESOURCE_BUNDLE_PATH" ]]; then
  cp -R "$RESOURCE_BUNDLE_PATH" "$APP_BUNDLE_PATH/Contents/Resources/"
fi

if [[ -f "$ICON_SOURCE_PATH" ]]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16     "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE_PATH" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS_PATH"
  cp "$ICON_ICNS_PATH" "$APP_BUNDLE_PATH/Contents/Resources/MinuteWave.icns"
fi

chmod +x "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - "$APP_BUNDLE_PATH"

BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE_PATH/Contents/Info.plist" 2>/dev/null || true
)"

echo ""
echo "Done."
echo "App bundle: $APP_BUNDLE_PATH"
if [[ -n "$BUNDLE_ID" ]]; then
  echo "Bundle ID:  $BUNDLE_ID"
fi
echo ""
echo "Optional reset before retest:"
if [[ -n "$BUNDLE_ID" ]]; then
  echo "  tccutil reset Microphone $BUNDLE_ID"
  echo "  tccutil reset ScreenCapture $BUNDLE_ID"
else
  echo "  tccutil reset Microphone"
  echo "  tccutil reset ScreenCapture"
fi
echo ""
echo "Launch with:"
echo "  open \"$APP_BUNDLE_PATH\""
