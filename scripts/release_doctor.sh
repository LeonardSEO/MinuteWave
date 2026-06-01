#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MinuteWave"
APP_BUNDLE_PATH="${APP_BUNDLE_PATH:-$ROOT_DIR/.build/AppBundle/${APP_NAME}.app}"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/dist/${APP_NAME}-macOS.dmg}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/config/${APP_NAME}.entitlements}"
PRIVACY_MANIFEST_PATH="$ROOT_DIR/Sources/AINoteTakerApp/Resources/PrivacyInfo.xcprivacy"
STRICT_DISTRIBUTION="${STRICT_DISTRIBUTION:-0}"
INSTALLED_APP_PATH="${INSTALLED_APP_PATH:-/Applications/${APP_NAME}.app}"

failures=0
warnings=0

ok() {
  printf 'ok: %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'warn: %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'fail: %s\n' "$1"
}

require_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    ok "$label exists: $path"
  else
    fail "$label missing: $path"
  fi
}

require_dir() {
  local path="$1"
  local label="$2"
  if [[ -d "$path" ]]; then
    ok "$label exists: $path"
  else
    fail "$label missing: $path"
  fi
}

plist_lint() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    fail "$label missing: $path"
    return
  fi
  if plutil -lint "$path" >/dev/null; then
    ok "$label is valid plist"
  else
    fail "$label is not valid plist: $path"
  fi
}

has_entitlement() {
  local entitlements_xml="$1"
  local key="$2"
  printf '%s' "$entitlements_xml" | grep -q "<key>$key</key>"
}

is_notary_configured() {
  [[ -n "${APPLE_NOTARY_KEYCHAIN_PROFILE:-}" ]] && return 0
  [[ -n "${APPLE_NOTARY_APPLE_ID:-}" && -n "${APPLE_NOTARY_TEAM_ID:-}" && -n "${APPLE_NOTARY_PASSWORD:-}" ]] && return 0
  [[ -n "${APPLE_NOTARY_KEY_ID:-}" && -n "${APPLE_NOTARY_ISSUER_ID:-}" && -n "${APPLE_NOTARY_KEY_PATH:-}" ]] && return 0
  [[ -n "${APPLE_NOTARY_KEY_ID:-}" && -n "${APPLE_NOTARY_KEY_PATH:-}" && "${APPLE_NOTARY_KEY_SUBJECT:-}" == "user" ]] && return 0
  return 1
}

echo "MinuteWave release doctor"
echo "Root: $ROOT_DIR"
echo ""

plist_lint "$ENTITLEMENTS_PATH" "Release entitlements"
plist_lint "$PRIVACY_MANIFEST_PATH" "Privacy manifest"

localized_info_count="$(
  find "$ROOT_DIR/Sources/AINoteTakerApp/Resources" -mindepth 2 -maxdepth 2 -path '*/InfoPlist.strings' -print 2>/dev/null | wc -l | tr -d ' '
)"
if [[ "$localized_info_count" -gt 0 ]]; then
  ok "InfoPlist.strings localizations found: $localized_info_count"
else
  fail "InfoPlist.strings localizations missing"
fi

echo ""
echo "App bundle"
if [[ -d "$APP_BUNDLE_PATH" ]]; then
  require_file "$APP_BUNDLE_PATH/Contents/Info.plist" "App Info.plist"
  require_file "$APP_BUNDLE_PATH/Contents/Resources/PrivacyInfo.xcprivacy" "Bundled privacy manifest"
  require_dir "$APP_BUNDLE_PATH/Contents/Resources/en.lproj" "English InfoPlist resources"
  require_dir "$APP_BUNDLE_PATH/Contents/Resources/nl.lproj" "Dutch InfoPlist resources"

  app_binary="$APP_BUNDLE_PATH/Contents/MacOS/$APP_NAME"
  require_file "$app_binary" "App executable"

  if [[ -x "$app_binary" ]]; then
    if otool -L "$app_binary" | grep -q '@rpath/libsqlcipher\.dylib'; then
      ok "App binary links embedded SQLCipher by @rpath"
      require_file "$APP_BUNDLE_PATH/Contents/Frameworks/libsqlcipher.dylib" "Embedded SQLCipher runtime"
    else
      warn "App binary does not link libsqlcipher by @rpath"
    fi
  fi

  if [[ -d "$APP_BUNDLE_PATH/Contents/Frameworks" ]]; then
    non_portable_dylibs="$(
      find "$APP_BUNDLE_PATH/Contents/Frameworks" -type f -name "*.dylib" -print0 |
        xargs -0 otool -L 2>/dev/null |
        grep -E '^[[:space:]]+(/opt/homebrew|/usr/local/(Cellar|opt)|/Users/)' || true
    )"
    if [[ -z "$non_portable_dylibs" ]]; then
      ok "Embedded dylibs have no Homebrew/user-path load commands"
    else
      fail "Embedded dylibs contain non-portable load commands: $non_portable_dylibs"
    fi
  fi

  if codesign --verify --deep --strict "$APP_BUNDLE_PATH" >/dev/null 2>&1; then
    ok "App signature verifies"
  else
    fail "App signature verification failed"
  fi

  signing_details="$(codesign -dvvv "$APP_BUNDLE_PATH" 2>&1 || true)"
  if printf '%s' "$signing_details" | grep -q 'Signature=adhoc'; then
    warn "App is ad-hoc signed; fine for local testing, not distribution"
    [[ "$STRICT_DISTRIBUTION" == "1" ]] && fail "Distribution build must not be ad-hoc signed"
  else
    ok "App is signed with a certificate identity"
  fi

  if printf '%s' "$signing_details" | grep -q 'runtime'; then
    ok "Hardened runtime flag is present"
  else
    warn "Hardened runtime flag not present"
    [[ "$STRICT_DISTRIBUTION" == "1" ]] && fail "Distribution build requires hardened runtime"
  fi

  entitlements_xml="$(codesign -d --entitlements :- "$APP_BUNDLE_PATH" 2>/dev/null || true)"
  for entitlement_key in \
    com.apple.security.app-sandbox \
    com.apple.security.device.audio-input \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.network.client
  do
    if has_entitlement "$entitlements_xml" "$entitlement_key"; then
      ok "Entitlement present: $entitlement_key"
    else
      fail "Entitlement missing: $entitlement_key"
    fi
  done
else
  warn "App bundle not found; run ./scripts/build_dev_app_bundle.sh release first"
fi

echo ""
echo "Installed app"
if [[ -d "$INSTALLED_APP_PATH" ]]; then
  if codesign --verify --deep --strict "$INSTALLED_APP_PATH" >/dev/null 2>&1; then
    ok "Installed app signature verifies: $INSTALLED_APP_PATH"
  else
    fail "Installed app signature verification failed: $INSTALLED_APP_PATH"
  fi

  installed_details="$(codesign -dvvv "$INSTALLED_APP_PATH" 2>&1 || true)"
  installed_team="$(
    printf '%s' "$installed_details" | awk -F= '/TeamIdentifier=/{print $2; exit}'
  )"
  built_team=""
  if [[ -d "$APP_BUNDLE_PATH" ]]; then
    built_team="$(
      codesign -dvvv "$APP_BUNDLE_PATH" 2>&1 | awk -F= '/TeamIdentifier=/{print $2; exit}' || true
    )"
  fi

  if printf '%s' "$installed_details" | grep -q 'Signature=adhoc'; then
    warn "Installed app is ad-hoc signed; this can cause stale TCC Screen Recording grants"
    [[ "$STRICT_DISTRIBUTION" == "1" ]] && fail "Installed app must not be ad-hoc signed"
  elif [[ -n "$installed_team" && "$installed_team" != "not set" ]]; then
    ok "Installed app TeamIdentifier: $installed_team"
  else
    warn "Installed app TeamIdentifier is missing"
  fi

  if [[ -n "$built_team" && -n "$installed_team" && "$built_team" != "$installed_team" ]]; then
    warn "Installed app TeamIdentifier differs from built app: installed=$installed_team built=$built_team"
  fi
else
  warn "Installed app not found at $INSTALLED_APP_PATH; use ./scripts/install_app_bundle.sh for stable TCC testing"
fi

echo ""
echo "DMG"
if [[ -f "$DMG_PATH" ]]; then
  if hdiutil verify "$DMG_PATH" >/dev/null; then
    ok "DMG checksum verifies"
  else
    fail "DMG verification failed"
  fi

  if xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
    ok "DMG has a stapled notarization ticket"
  else
    warn "DMG is not stapled/notarized"
    [[ "$STRICT_DISTRIBUTION" == "1" ]] && fail "Distribution DMG must be notarized and stapled"
  fi
else
  warn "DMG not found; run ./scripts/build_dmg.sh release first"
fi

echo ""
echo "Notary configuration"
if is_notary_configured; then
  ok "Notary credentials are configured in the environment"
else
  warn "Notary credentials are not configured in the environment"
  [[ "$STRICT_DISTRIBUTION" == "1" ]] && fail "Distribution release requires notary credentials"
fi

if [[ "${SIGNING_IDENTITY:--}" == "-" ]]; then
  warn "SIGNING_IDENTITY is ad-hoc"
  [[ "$STRICT_DISTRIBUTION" == "1" ]] && fail "Distribution release requires Developer ID or App Store signing identity"
else
  ok "SIGNING_IDENTITY is set: ${SIGNING_IDENTITY}"
  if [[ "${NOTARIZE_DMG:-0}" == "1" && "$SIGNING_IDENTITY" != Developer\ ID\ Application:* && "${ALLOW_NON_DEVELOPER_ID_NOTARIZATION:-0}" != "1" ]]; then
    fail "Notarized direct-download DMGs require a Developer ID Application signing identity"
  fi
fi

echo ""
printf 'Summary: %s failure(s), %s warning(s)\n' "$failures" "$warnings"
if [[ "$failures" -gt 0 ]]; then
  exit 1
fi
