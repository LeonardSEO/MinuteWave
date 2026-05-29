#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MinuteWave"
APP_BUNDLE_PATH="${APP_BUNDLE_PATH:-$ROOT_DIR/.build/AppBundle/${APP_NAME}.app}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/${APP_NAME}.app}"
ALLOW_ADHOC_INSTALL="${ALLOW_ADHOC_INSTALL:-0}"
RESET_TCC="${RESET_TCC:-0}"

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "App bundle not found: $APP_BUNDLE_PATH" >&2
  echo "Build it first, for example:" >&2
  echo "  SIGNING_IDENTITY=\"Apple Development: Your Name (TEAMID)\" ENABLE_HARDENED_RUNTIME=1 ./scripts/build_dev_app_bundle.sh release" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$APP_BUNDLE_PATH" >/dev/null 2>&1; then
  echo "App bundle signature does not verify: $APP_BUNDLE_PATH" >&2
  exit 1
fi

signing_details="$(codesign -dvvv "$APP_BUNDLE_PATH" 2>&1 || true)"
if printf '%s' "$signing_details" | grep -q 'Signature=adhoc'; then
  if [[ "$ALLOW_ADHOC_INSTALL" != "1" ]]; then
    echo "Refusing to install an ad-hoc signed app into /Applications." >&2
    echo "Ad-hoc installs can create stale TCC Screen Recording grants that look enabled in System Settings but do not match the active app identity." >&2
    echo "Set ALLOW_ADHOC_INSTALL=1 only for throwaway local debugging." >&2
    exit 1
  fi
fi

team_identifier="$(
  printf '%s' "$signing_details" | awk -F= '/TeamIdentifier=/{print $2; exit}'
)"
bundle_id="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE_PATH/Contents/Info.plist" 2>/dev/null || true
)"

if [[ -z "$team_identifier" || "$team_identifier" == "not set" ]]; then
  if [[ "$ALLOW_ADHOC_INSTALL" != "1" ]]; then
    echo "Refusing to install app without a certificate TeamIdentifier." >&2
    exit 1
  fi
fi

osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true

if [[ -d "$INSTALL_PATH" ]]; then
  backup_path="${INSTALL_PATH}.backup-$(date +%Y%m%d%H%M%S)"
  mv "$INSTALL_PATH" "$backup_path"
  echo "Backed up existing app to: $backup_path"
fi

ditto "$APP_BUNDLE_PATH" "$INSTALL_PATH"
codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"

echo ""
echo "Installed: $INSTALL_PATH"
if [[ -n "$bundle_id" ]]; then
  echo "Bundle ID: $bundle_id"
fi
if [[ -n "$team_identifier" ]]; then
  echo "Team ID:   $team_identifier"
fi
echo ""

if [[ "$RESET_TCC" == "1" && -n "$bundle_id" ]]; then
  tccutil reset Microphone "$bundle_id" || true
  tccutil reset ScreenCapture "$bundle_id" || true
  echo "Reset Microphone and ScreenCapture TCC records for: $bundle_id"
  echo ""
fi

echo "Launch with:"
echo "  open \"$INSTALL_PATH\""
