#!/bin/sh
# Copies Drop's app icon from the Nidus Labs assets repo, where it's generated
# (`npm run build` there, then iconutil; see its README). Never edit
# Resources/AppIcon.icns by hand. Usage: scripts/sync-icon.sh [path to the assets repo]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ASSETS=${1:-"$ROOT/../assets"}
cp "$ASSETS/apps/drop/Drop.icns" "$ROOT/Resources/AppIcon.icns"
echo "Copied $ASSETS/apps/drop/Drop.icns to Resources/AppIcon.icns"
