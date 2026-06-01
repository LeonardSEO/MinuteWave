#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MinuteWave"
CONFIGURATION="${CONFIGURATION:-release}"
APP_BUNDLE_PATH="${APP_BUNDLE_PATH:-$ROOT_DIR/.build/AppBundle/${APP_NAME}.app}"
DIST_DIR="$ROOT_DIR/dist"
PKG_PATH="${PKG_PATH:-$DIST_DIR/${APP_NAME}-macOS-TestFlight.pkg}"
SIGNING_IDENTITY="${APPLE_DISTRIBUTION_SIGNING_IDENTITY:-${SIGNING_IDENTITY:-}}"
INSTALLER_SIGNING_IDENTITY="${APPLE_INSTALLER_SIGNING_IDENTITY:-}"
VALIDATE_TESTFLIGHT="${VALIDATE_TESTFLIGHT:-1}"
UPLOAD_TESTFLIGHT="${UPLOAD_TESTFLIGHT:-0}"
ASC_API_KEY_ID="${ASC_API_KEY_ID:-${APPLE_ASC_KEY_ID:-}}"
ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-${APPLE_ASC_ISSUER_ID:-}}"
ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-${APPLE_ASC_KEY_PATH:-}}"
ASC_API_KEY_SUBJECT="${ASC_API_KEY_SUBJECT:-${APPLE_ASC_KEY_SUBJECT:-}}"
ASC_USERNAME="${ASC_USERNAME:-${APPLE_ID_USERNAME:-}}"
ASC_PASSWORD="${ASC_PASSWORD:-${APPLE_ID_PASSWORD:-}}"
ASC_PROVIDER_PUBLIC_ID="${ASC_PROVIDER_PUBLIC_ID:-}"

require_value() {
  local value="$1"
  local label="$2"
  if [[ -z "$value" ]]; then
    echo "Error: $label is required." >&2
    exit 64
  fi
}

run_altool() {
  local output
  local status
  set +e
  output="$(xcrun altool "$@" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"
  if [[ $status -ne 0 ]]; then
    return "$status"
  fi
  if grep -Eq '(^|[[:space:]])ERROR:|AuthenticationFailure|Unable to authenticate|received status code 401|NOT_AUTHORIZED' <<< "$output"; then
    return 1
  fi
}

require_value "$SIGNING_IDENTITY" "APPLE_DISTRIBUTION_SIGNING_IDENTITY or SIGNING_IDENTITY"
require_value "$INSTALLER_SIGNING_IDENTITY" "APPLE_INSTALLER_SIGNING_IDENTITY"

if [[ "$SIGNING_IDENTITY" != Apple\ Distribution:* && "${ALLOW_NON_APPLE_DISTRIBUTION_SIGNING:-0}" != "1" ]]; then
  echo "Error: TestFlight builds must use an Apple Distribution signing identity." >&2
  echo "Current identity: $SIGNING_IDENTITY" >&2
  echo "Set ALLOW_NON_APPLE_DISTRIBUTION_SIGNING=1 only for local packaging experiments." >&2
  exit 64
fi

if [[ "$INSTALLER_SIGNING_IDENTITY" != 3rd\ Party\ Mac\ Developer\ Installer:* && "${ALLOW_NON_APP_STORE_INSTALLER_SIGNING:-0}" != "1" ]]; then
  echo "Error: TestFlight packages should use a 3rd Party Mac Developer Installer identity." >&2
  echo "Current identity: $INSTALLER_SIGNING_IDENTITY" >&2
  echo "Set ALLOW_NON_APP_STORE_INSTALLER_SIGNING=1 only for local packaging experiments." >&2
  exit 64
fi

mkdir -p "$DIST_DIR"

echo "Building Apple Distribution signed app bundle..."
SIGNING_IDENTITY="$SIGNING_IDENTITY" \
ENABLE_HARDENED_RUNTIME=1 \
"$ROOT_DIR/scripts/build_dev_app_bundle.sh" "$CONFIGURATION"

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "Error: app bundle not found: $APP_BUNDLE_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_BUNDLE_PATH"
codesign -dv --verbose=4 "$APP_BUNDLE_PATH" 2>&1 | grep -E 'Authority=|TeamIdentifier=|Signature='

rm -f "$PKG_PATH"
echo "Building signed TestFlight/App Store package..."
productbuild \
  --component "$APP_BUNDLE_PATH" /Applications \
  --sign "$INSTALLER_SIGNING_IDENTITY" \
  "$PKG_PATH"

pkgutil --check-signature "$PKG_PATH"

altool_auth_args=()
if [[ -n "$ASC_API_KEY_ID" && -n "$ASC_API_ISSUER_ID" ]]; then
  altool_auth_args=(--api-key "$ASC_API_KEY_ID" --api-issuer "$ASC_API_ISSUER_ID")
  if [[ -n "$ASC_API_KEY_PATH" ]]; then
    altool_auth_args+=(--p8-file-path "$ASC_API_KEY_PATH")
  fi
  if [[ -n "$ASC_API_KEY_SUBJECT" ]]; then
    altool_auth_args+=(--api-key-subject "$ASC_API_KEY_SUBJECT")
  fi
elif [[ -n "$ASC_USERNAME" && -n "$ASC_PASSWORD" ]]; then
  altool_auth_args=(-u "$ASC_USERNAME" -p "$ASC_PASSWORD")
else
  altool_auth_args=()
fi

if [[ -n "$ASC_PROVIDER_PUBLIC_ID" ]]; then
  altool_auth_args+=(--provider-public-id "$ASC_PROVIDER_PUBLIC_ID")
fi

if [[ "$VALIDATE_TESTFLIGHT" == "1" || "$UPLOAD_TESTFLIGHT" == "1" ]]; then
  if [[ "${#altool_auth_args[@]}" -eq 0 ]]; then
    echo "Error: App Store Connect credentials are required for validation/upload." >&2
    echo "Provide ASC_API_KEY_ID + ASC_API_ISSUER_ID (+ optional ASC_API_KEY_PATH) or ASC_USERNAME + ASC_PASSWORD." >&2
    exit 64
  fi
fi

if [[ "$VALIDATE_TESTFLIGHT" == "1" ]]; then
  echo "Validating package with App Store Connect..."
  run_altool --validate-app "$PKG_PATH" "${altool_auth_args[@]}" --output-format json
fi

if [[ "$UPLOAD_TESTFLIGHT" == "1" ]]; then
  echo "Uploading package to App Store Connect/TestFlight..."
  run_altool --upload-package "$PKG_PATH" "${altool_auth_args[@]}" --output-format json
else
  echo "UPLOAD_TESTFLIGHT is not 1; package was built but not uploaded."
fi

echo ""
echo "Done."
echo "Package: $PKG_PATH"
