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
PROVISIONING_PROFILE_PATH="${MAC_APP_STORE_PROVISIONING_PROFILE_PATH:-${PROVISIONING_PROFILE_PATH:-}}"
VALIDATE_TESTFLIGHT="${VALIDATE_TESTFLIGHT:-1}"
UPLOAD_TESTFLIGHT="${UPLOAD_TESTFLIGHT:-0}"
ASC_API_KEY_ID="${ASC_API_KEY_ID:-${APPLE_ASC_KEY_ID:-}}"
ASC_API_ISSUER_ID="${ASC_API_ISSUER_ID:-${APPLE_ASC_ISSUER_ID:-}}"
ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-${APPLE_ASC_KEY_PATH:-}}"
ASC_API_KEY_SUBJECT="${ASC_API_KEY_SUBJECT:-${APPLE_ASC_KEY_SUBJECT:-}}"
ASC_USERNAME="${ASC_USERNAME:-${APPLE_ID_USERNAME:-}}"
ASC_PASSWORD="${ASC_PASSWORD:-${APPLE_ID_PASSWORD:-}}"
ASC_PROVIDER_PUBLIC_ID="${ASC_PROVIDER_PUBLIC_ID:-}"
TESTFLIGHT_ENTITLEMENTS_PATH=""

cleanup() {
  if [[ -n "$TESTFLIGHT_ENTITLEMENTS_PATH" ]]; then
    rm -f "$TESTFLIGHT_ENTITLEMENTS_PATH"
  fi
}
trap cleanup EXIT

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

bundle_identifier() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE_PATH/Contents/Info.plist"
}

signing_team_identifier() {
  codesign -dvvv "$APP_BUNDLE_PATH" 2>&1 | awk -F= '/TeamIdentifier=/{print $2; exit}'
}

profile_value() {
  local plist_path="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print $key_path" "$plist_path" 2>/dev/null || true
}

embedded_profile_application_identifier() {
  local plist_path="$1"
  local application_identifier
  application_identifier="$(profile_value "$plist_path" ":Entitlements:application-identifier")"
  if [[ -z "$application_identifier" ]]; then
    application_identifier="$(profile_value "$plist_path" ":Entitlements:com.apple.application-identifier")"
  fi
  printf '%s\n' "$application_identifier"
}

set_plist_string() {
  local plist_path="$1"
  local key_path="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set $key_path $value" "$plist_path" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add $key_path string $value" "$plist_path"
}

copy_first_profile_array_value() {
  local profile_plist="$1"
  local entitlements_plist="$2"
  local key="$3"
  local value

  value="$(profile_value "$profile_plist" ":Entitlements:$key:0")"
  if [[ -z "$value" ]]; then
    return 0
  fi

  /usr/libexec/PlistBuddy -c "Delete :$key" "$entitlements_plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key array" "$entitlements_plist"
  /usr/libexec/PlistBuddy -c "Add :$key:0 string $value" "$entitlements_plist"
}

create_testflight_entitlements() {
  local profile_plist
  local profile_team_id
  local application_identifier

  profile_plist="$(mktemp "${TMPDIR:-/tmp}/minutewave-profile.XXXXXX.plist")"
  if ! security cms -D -i "$PROVISIONING_PROFILE_PATH" > "$profile_plist"; then
    echo "Error: provisioning profile is not a valid Apple provisioning profile." >&2
    rm -f "$profile_plist"
    exit 1
  fi

  profile_team_id="$(profile_value "$profile_plist" ":TeamIdentifier:0")"
  application_identifier="$(embedded_profile_application_identifier "$profile_plist")"

  if [[ -z "$profile_team_id" || -z "$application_identifier" ]]; then
    echo "Error: provisioning profile is missing required app identifier entitlements." >&2
    rm -f "$profile_plist"
    exit 1
  fi

  TESTFLIGHT_ENTITLEMENTS_PATH="$(mktemp "${TMPDIR:-/tmp}/minutewave-testflight-entitlements.XXXXXX.plist")"
  cp "$ROOT_DIR/config/MinuteWave.entitlements" "$TESTFLIGHT_ENTITLEMENTS_PATH"
  set_plist_string "$TESTFLIGHT_ENTITLEMENTS_PATH" ":com.apple.application-identifier" "$application_identifier"
  set_plist_string "$TESTFLIGHT_ENTITLEMENTS_PATH" ":com.apple.developer.team-identifier" "$profile_team_id"
  copy_first_profile_array_value "$profile_plist" "$TESTFLIGHT_ENTITLEMENTS_PATH" "keychain-access-groups"

  rm -f "$profile_plist"
  echo "Prepared TestFlight entitlements for $application_identifier."
}

validate_embedded_provisioning_profile() {
  local embedded_profile="$APP_BUNDLE_PATH/Contents/embedded.provisionprofile"
  local profile_plist
  local signed_entitlements_plist
  local app_bundle_id
  local app_team_id
  local profile_team_id
  local application_identifier
  local signed_application_identifier
  local signed_team_identifier

  if [[ ! -f "$embedded_profile" ]]; then
    echo "Error: TestFlight app is missing $embedded_profile." >&2
    echo "macOS TestFlight main bundles must contain Contents/embedded.provisionprofile." >&2
    exit 1
  fi

  profile_plist="$(mktemp "${TMPDIR:-/tmp}/minutewave-profile.XXXXXX.plist")"
  if ! security cms -D -i "$embedded_profile" > "$profile_plist"; then
    echo "Error: embedded provisioning profile is not a valid Apple provisioning profile." >&2
    rm -f "$profile_plist"
    exit 1
  fi

  app_bundle_id="$(bundle_identifier)"
  app_team_id="$(signing_team_identifier)"
  profile_team_id="$(profile_value "$profile_plist" ":TeamIdentifier:0")"
  application_identifier="$(embedded_profile_application_identifier "$profile_plist")"
  signed_entitlements_plist="$(mktemp "${TMPDIR:-/tmp}/minutewave-signed-entitlements.XXXXXX.plist")"
  if ! codesign -d --entitlements :- "$APP_BUNDLE_PATH" > "$signed_entitlements_plist" 2>/dev/null; then
    echo "Error: could not read signed entitlements from app bundle." >&2
    rm -f "$profile_plist" "$signed_entitlements_plist"
    exit 1
  fi
  signed_application_identifier="$(profile_value "$signed_entitlements_plist" ":com.apple.application-identifier")"
  signed_team_identifier="$(profile_value "$signed_entitlements_plist" ":com.apple.developer.team-identifier")"

  if [[ -z "$profile_team_id" ]]; then
    echo "Error: provisioning profile is missing TeamIdentifier." >&2
    rm -f "$profile_plist" "$signed_entitlements_plist"
    exit 1
  fi

  if [[ -z "$application_identifier" ]]; then
    echo "Error: provisioning profile is missing an application identifier entitlement." >&2
    rm -f "$profile_plist" "$signed_entitlements_plist"
    exit 1
  fi

  if [[ -n "$app_team_id" && "$app_team_id" != "$profile_team_id" ]]; then
    echo "Error: provisioning profile team ($profile_team_id) does not match signing team ($app_team_id)." >&2
    rm -f "$profile_plist" "$signed_entitlements_plist"
    exit 1
  fi

  if [[ "$application_identifier" != "$profile_team_id.$app_bundle_id" ]]; then
    echo "Error: provisioning profile application identifier ($application_identifier) does not match $profile_team_id.$app_bundle_id." >&2
    rm -f "$profile_plist" "$signed_entitlements_plist"
    exit 1
  fi

  if [[ "$signed_application_identifier" != "$application_identifier" ]]; then
    echo "Error: signed app application identifier ($signed_application_identifier) does not match provisioning profile ($application_identifier)." >&2
    rm -f "$profile_plist" "$signed_entitlements_plist"
    exit 1
  fi

  if [[ "$signed_team_identifier" != "$profile_team_id" ]]; then
    echo "Error: signed app team identifier ($signed_team_identifier) does not match provisioning profile team ($profile_team_id)." >&2
    rm -f "$profile_plist" "$signed_entitlements_plist"
    exit 1
  fi

  rm -f "$profile_plist" "$signed_entitlements_plist"
  echo "Embedded provisioning profile validated for $application_identifier."
}

require_value "$SIGNING_IDENTITY" "APPLE_DISTRIBUTION_SIGNING_IDENTITY or SIGNING_IDENTITY"
require_value "$INSTALLER_SIGNING_IDENTITY" "APPLE_INSTALLER_SIGNING_IDENTITY"
require_value "$PROVISIONING_PROFILE_PATH" "MAC_APP_STORE_PROVISIONING_PROFILE_PATH or PROVISIONING_PROFILE_PATH"

if [[ ! -f "$PROVISIONING_PROFILE_PATH" ]]; then
  echo "Error: provisioning profile not found: $PROVISIONING_PROFILE_PATH" >&2
  exit 64
fi

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
create_testflight_entitlements

echo "Building Apple Distribution signed app bundle..."
SIGNING_IDENTITY="$SIGNING_IDENTITY" \
ENABLE_HARDENED_RUNTIME=1 \
PROVISIONING_PROFILE_PATH="$PROVISIONING_PROFILE_PATH" \
ENTITLEMENTS_PATH="$TESTFLIGHT_ENTITLEMENTS_PATH" \
"$ROOT_DIR/scripts/build_dev_app_bundle.sh" "$CONFIGURATION"

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "Error: app bundle not found: $APP_BUNDLE_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_BUNDLE_PATH"
codesign -dv --verbose=4 "$APP_BUNDLE_PATH" 2>&1 | grep -E 'Authority=|TeamIdentifier=|Signature='
validate_embedded_provisioning_profile

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
