#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_NAME="MinuteWave"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
EXECUTABLE_PATH="$BUILD_DIR/$APP_NAME"
RESOURCE_BUNDLE_PATH_LEGACY="$BUILD_DIR/${APP_NAME}_AINoteTakerApp.resources"
RESOURCE_BUNDLE_PATH_BUNDLE="$BUILD_DIR/${APP_NAME}_AINoteTakerApp.bundle"
APP_BUNDLE_PATH="$ROOT_DIR/.build/AppBundle/${APP_NAME}.app"
FRAMEWORKS_DIR="$APP_BUNDLE_PATH/Contents/Frameworks"
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
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
ENABLE_HARDENED_RUNTIME="${ENABLE_HARDENED_RUNTIME:-0}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

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
mkdir -p "$FRAMEWORKS_DIR"

cp "$EXECUTABLE_PATH" "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME"
cp "$PLIST_TEMPLATE_PATH" "$APP_BUNDLE_PATH/Contents/Info.plist"

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE_PATH/Contents/Info.plist" \
    || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE_PATH/Contents/Info.plist"
fi

copy_resource_bundle() {
  local bundle_path=""
  if [[ -d "$RESOURCE_BUNDLE_PATH_BUNDLE" ]]; then
    bundle_path="$RESOURCE_BUNDLE_PATH_BUNDLE"
  elif [[ -d "$RESOURCE_BUNDLE_PATH_LEGACY" ]]; then
    bundle_path="$RESOURCE_BUNDLE_PATH_LEGACY"
  else
    bundle_path="$(find "$BUILD_DIR" -maxdepth 1 -type d -name '*_AINoteTakerApp.bundle' | head -n 1)"
  fi

  if [[ -n "$bundle_path" && -d "$bundle_path" ]]; then
    cp -R "$bundle_path" "$APP_BUNDLE_PATH/Contents/Resources/"
  else
    echo "Warning: app resource bundle not found in $BUILD_DIR"
  fi
}

copy_resource_bundle

embed_sqlcipher_runtime() {
  local linked_sqlcipher
  linked_sqlcipher="$(otool -L "$EXECUTABLE_PATH" | awk '/libsqlcipher\.dylib/{print $1; exit}')"

  if [[ -z "$linked_sqlcipher" ]]; then
    return 0
  fi

  if [[ ! -f "$linked_sqlcipher" ]]; then
    if command -v brew >/dev/null 2>&1; then
      local brew_sqlcipher
      brew_sqlcipher="$(brew --prefix sqlcipher 2>/dev/null || true)"
      if [[ -n "$brew_sqlcipher" && -f "$brew_sqlcipher/lib/libsqlcipher.dylib" ]]; then
        linked_sqlcipher="$brew_sqlcipher/lib/libsqlcipher.dylib"
      fi
    fi
  fi

  if [[ ! -f "$linked_sqlcipher" ]]; then
    echo "Warning: sqlcipher runtime library not found at $linked_sqlcipher"
    return 0
  fi

  local embedded_sqlcipher="$FRAMEWORKS_DIR/libsqlcipher.dylib"
  cp "$linked_sqlcipher" "$embedded_sqlcipher"

  local linked_libcrypto
  linked_libcrypto="$(otool -L "$linked_sqlcipher" | awk '/libcrypto\.3\.dylib/{print $1; exit}')"
  if [[ -n "$linked_libcrypto" && -f "$linked_libcrypto" ]]; then
    local embedded_libcrypto="$FRAMEWORKS_DIR/libcrypto.3.dylib"
    cp "$linked_libcrypto" "$embedded_libcrypto"
    install_name_tool -id "@rpath/libcrypto.3.dylib" "$embedded_libcrypto" || true
    install_name_tool -change "$linked_libcrypto" "@rpath/libcrypto.3.dylib" "$embedded_sqlcipher" || true
  fi

  install_name_tool -id "@rpath/libsqlcipher.dylib" "$embedded_sqlcipher" || true
  install_name_tool -change "$linked_sqlcipher" "@rpath/libsqlcipher.dylib" "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME" || true

  if ! otool -l "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME"
  fi
}

embed_sparkle_runtime() {
  local linked_sparkle
  linked_sparkle="$(otool -L "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME" | awk '/Sparkle\.framework/{print $1; exit}')"

  if [[ -z "$linked_sparkle" ]]; then
    return 0
  fi

  local sparkle_framework
  sparkle_framework="$(find "$ROOT_DIR/.build" -type d -name Sparkle.framework | head -n 1)"
  if [[ -z "$sparkle_framework" ]]; then
    echo "Warning: Sparkle.framework was linked but not found in .build output."
    return 0
  fi

  local embedded_sparkle="$FRAMEWORKS_DIR/Sparkle.framework"
  rm -rf "$embedded_sparkle"
  cp -R "$sparkle_framework" "$embedded_sparkle"

  install_name_tool \
    -change "$linked_sparkle" "@rpath/Sparkle.framework/Versions/B/Sparkle" \
    "$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME" || true
}

embed_sqlcipher_runtime
embed_sparkle_runtime

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

CODESIGN_ARGS=(--force --deep --sign "$SIGNING_IDENTITY")
if [[ "$ENABLE_HARDENED_RUNTIME" == "1" ]]; then
  CODESIGN_ARGS+=(--options runtime)
fi
if [[ -n "$ENTITLEMENTS_PATH" && -f "$ENTITLEMENTS_PATH" ]]; then
  CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
fi
codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE_PATH"

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
