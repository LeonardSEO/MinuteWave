#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_PATH="$ROOT_DIR/Sources/AINoteTakerApp/Resources/AppInfo.plist"
DEFAULT_BUNDLE_ID="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST_PATH" 2>/dev/null || true
)"
BUNDLE_ID="${1:-$DEFAULT_BUNDLE_ID}"

if [[ -z "$BUNDLE_ID" ]]; then
  echo "No bundle identifier found. Pass one explicitly: $0 com.example.app" >&2
  exit 1
fi

echo "Resetting TCC permissions for: $BUNDLE_ID"
tccutil reset Microphone "$BUNDLE_ID"
tccutil reset ScreenCapture "$BUNDLE_ID"
defaults delete "$BUNDLE_ID" "permissions.screenCapture.requested" >/dev/null 2>&1 || true
defaults delete "$BUNDLE_ID" "permissions.screenCapture.confirmed" >/dev/null 2>&1 || true
echo "Done."
