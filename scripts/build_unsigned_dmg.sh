#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Notice: scripts/build_unsigned_dmg.sh is deprecated. Use scripts/build_dmg.sh instead."
exec "$SCRIPT_DIR/build_dmg.sh" "$@"
