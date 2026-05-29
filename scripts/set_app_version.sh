#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_PATH="${PLIST_PATH:-$ROOT_DIR/Sources/AINoteTakerApp/Resources/AppInfo.plist}"
VERSION="${1:-${APP_VERSION:-}}"
BUILD_NUMBER="${2:-${APP_BUILD_NUMBER:-}}"

usage() {
  echo "Usage: $0 <version> [build-number]" >&2
  echo "Example: $0 0.1.17 18" >&2
}

if [[ -z "$VERSION" ]]; then
  usage
  exit 64
fi

VERSION="${VERSION#v}"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}([.-][A-Za-z0-9]+)?$ ]]; then
  echo "Error: invalid app version '$VERSION'." >&2
  echo "Use a numeric version such as 0.1.17 or 1.0.0." >&2
  exit 64
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  existing_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_PATH" 2>/dev/null || true)"
  if [[ "$existing_build" =~ ^[0-9]+$ ]]; then
    BUILD_NUMBER="$((existing_build + 1))"
  else
    BUILD_NUMBER="1"
  fi
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ || "$BUILD_NUMBER" == "0" ]]; then
  echo "Error: invalid build number '$BUILD_NUMBER'." >&2
  echo "Use a positive integer." >&2
  exit 64
fi

if [[ ! -f "$PLIST_PATH" ]]; then
  echo "Error: Info.plist not found: $PLIST_PATH" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"

echo "Set app version: $VERSION ($BUILD_NUMBER)"
echo "Plist: $PLIST_PATH"
