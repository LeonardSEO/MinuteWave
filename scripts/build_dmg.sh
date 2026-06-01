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
NOTARIZE_DMG="${NOTARIZE_DMG:-0}"
APPLE_NOTARY_KEYCHAIN_PROFILE="${APPLE_NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_NOTARY_APPLE_ID="${APPLE_NOTARY_APPLE_ID:-}"
APPLE_NOTARY_TEAM_ID="${APPLE_NOTARY_TEAM_ID:-}"
APPLE_NOTARY_PASSWORD="${APPLE_NOTARY_PASSWORD:-}"
APPLE_NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
APPLE_NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"
APPLE_NOTARY_KEY_PATH="${APPLE_NOTARY_KEY_PATH:-}"
APPLE_NOTARY_KEY_SUBJECT="${APPLE_NOTARY_KEY_SUBJECT:-}"

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

  if ! create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$STAGING_DIR"; then
    echo "Warning: styled DMG generation failed, falling back to plain DMG."
    FORCE_PLAIN_DMG=1
  fi
fi

if [[ "$FORCE_PLAIN_DMG" == "1" ]]; then
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
else
  echo "Styled DMG generated."
fi

notarize_and_staple_dmg() {
  if [[ "$NOTARIZE_DMG" != "1" ]]; then
    return 0
  fi

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "Error: xcrun is required for notarization." >&2
    exit 1
  fi

  if [[ "${SIGNING_IDENTITY:--}" == "-" ]]; then
    echo "Error: notarization requires a Developer ID signed app; SIGNING_IDENTITY is ad-hoc." >&2
    exit 1
  fi

  if [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* && "${ALLOW_NON_DEVELOPER_ID_NOTARIZATION:-0}" != "1" ]]; then
    echo "Error: direct-download notarization requires a Developer ID Application identity." >&2
    echo "Current identity: $SIGNING_IDENTITY" >&2
    echo "Set ALLOW_NON_DEVELOPER_ID_NOTARIZATION=1 only for explicit experiments." >&2
    exit 1
  fi

  local notary_args=()
  if [[ -n "$APPLE_NOTARY_KEYCHAIN_PROFILE" ]]; then
    notary_args=(--keychain-profile "$APPLE_NOTARY_KEYCHAIN_PROFILE")
  elif [[ -n "$APPLE_NOTARY_APPLE_ID" && -n "$APPLE_NOTARY_TEAM_ID" && -n "$APPLE_NOTARY_PASSWORD" ]]; then
    notary_args=(--apple-id "$APPLE_NOTARY_APPLE_ID" --team-id "$APPLE_NOTARY_TEAM_ID" --password "$APPLE_NOTARY_PASSWORD")
  elif [[ -n "$APPLE_NOTARY_KEY_ID" && -n "$APPLE_NOTARY_KEY_PATH" ]]; then
    notary_args=(--key "$APPLE_NOTARY_KEY_PATH" --key-id "$APPLE_NOTARY_KEY_ID")
    if [[ -n "$APPLE_NOTARY_ISSUER_ID" && "$APPLE_NOTARY_KEY_SUBJECT" != "user" ]]; then
      notary_args+=(--issuer "$APPLE_NOTARY_ISSUER_ID")
    fi
  else
    echo "Error: NOTARIZE_DMG=1 requires notary credentials." >&2
    echo "Provide APPLE_NOTARY_KEYCHAIN_PROFILE, Apple ID credentials, or App Store Connect API key credentials." >&2
    exit 1
  fi

  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" "${notary_args[@]}" --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
}

notarize_and_staple_dmg

echo ""
echo "Done."
echo "DMG: $DMG_PATH"
