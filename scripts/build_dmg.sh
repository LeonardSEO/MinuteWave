#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_NAME="MinuteWave"
APP_BUNDLE_PATH="$ROOT_DIR/.build/AppBundle/${APP_NAME}.app"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/${APP_NAME}-macOS.dmg"
DMG_VOLUME_NAME="${APP_NAME} Installer"
DMG_BACKGROUND_PATH="$ROOT_DIR/docs/assets/dmg-background.png"
FORCE_PLAIN_DMG="${FORCE_PLAIN_DMG:-0}"
if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
  FORCE_PLAIN_DMG=1
fi

mkdir -p "$DIST_DIR"

echo "Building app bundle..."
"$ROOT_DIR/scripts/build_dev_app_bundle.sh" "$CONFIGURATION"

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "App bundle not found: $APP_BUNDLE_PATH" >&2
  exit 1
fi

echo "Preparing staging folder..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE_PATH" "$STAGING_DIR/"

if [[ -f "$DMG_PATH" ]]; then
  rm -f "$DMG_PATH"
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing create-dmg with Homebrew..."
    brew install create-dmg
  fi
fi

if [[ "$FORCE_PLAIN_DMG" != "1" ]] && command -v create-dmg >/dev/null 2>&1; then
  echo "Creating styled DMG (create-dmg)..."
  CREATE_DMG_ARGS=(
    --volname "$DMG_VOLUME_NAME"
    --window-size 760 500
    --icon-size 128
    --icon "${APP_NAME}.app" 200 250
    --app-drop-link 560 250
    --hide-extension "${APP_NAME}.app"
    --hdiutil-quiet
  )

  if [[ -f "$DMG_BACKGROUND_PATH" ]]; then
    CREATE_DMG_ARGS+=(--background "$DMG_BACKGROUND_PATH")
  fi

  create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$STAGING_DIR"
else
  echo "Creating plain DMG with hdiutil..."
  if [[ ! -e "$STAGING_DIR/Applications" ]]; then
    ln -s /Applications "$STAGING_DIR/Applications"
  fi
  hdiutil create \
    -volname "$DMG_VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

echo ""
echo "Done."
echo "DMG: $DMG_PATH"
