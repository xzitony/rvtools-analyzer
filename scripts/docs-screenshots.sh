#!/bin/bash
# Regenerates the screenshots in docs/images (used by README.md and docs/SOLUTIONS.md) from the synthetic sample data
# and the example solutions. It uses the Dev build with its markings hidden and a throwaway support folder, so no
# installed solutions, price lists or settings appear. The priced pages need cached Azure and AWS prices
# (rvtools-cli --prices azure / aws, or Download Prices in the app).
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh dev
swift build -c release --product rvtools-cli >/dev/null
CLI="$(swift build -c release --show-bin-path)/rvtools-cli"
APP="$PWD/build/RVTools Analyzer Dev.app"
SUPPORT="RVTools Analyzer Docs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$HOME/Library/Application Support/$SUPPORT"' EXIT
ENV=(--env RVTA_SNAPSHOT_QUIT=1 --env RVTA_HIDE_DEV_BADGE=1 --env "RVTA_SUPPORT_FOLDER=$SUPPORT")

echo "▸ Capturing dashboards and solutions…"
open -W -n --env "RVTA_SNAPSHOT_DIR=$TMP/main" "${ENV[@]}" --env "RVTOOLS_SOLUTIONS_PATH=$PWD/examples/solutions" \
  -a "$APP" "$PWD/$(ls samples/RVTools_export_all_*.xlsx | head -1)"

# Trend mode is opened from a saved trend project: an open-document event always brings up the window to capture.
echo "▸ Capturing trend mode…"
"$CLI" --trend samples/series/RVTools_export_all_*.xlsx --save-project "$TMP/Sample trend.rvaproj" >/dev/null
open -W -n --env "RVTA_SNAPSHOT_DIR=$TMP/trend" "${ENV[@]}" -a "$APP" "$TMP/Sample trend.rvaproj"

echo "▸ Writing docs/images…"
mkdir -p docs/images
while read -r src dst; do
  sips -Z 1600 "$TMP/$src" --out "docs/images/$dst" >/dev/null
done <<'LIST'
main/01-overview.png overview.png
main/02-issues.png issues.png
main/03-compute-clusters.png compute.png
main/05-vms.png virtual-machines.png
main/06-storage.png storage.png
main/22-backup-results.png backup-sizing.png
main/31-azure-results.png azure-migration.png
main/36-cloud-compare-assumptions.png custom-solution-assumptions.png
main/37-cloud-compare-results.png custom-solution-results.png
trend/30-trend-summary.png trend-summary.png
trend/31-trend-changes.png trend-changes.png
LIST
echo "✓ Updated docs/images"
