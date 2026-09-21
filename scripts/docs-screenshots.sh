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
# RVTA_SUPPORT_FOLDER also gives the run its own preferences domain (AppDefaults in App.swift); remove it afterwards.
trap 'rm -rf "$TMP" "$HOME/Library/Application Support/$SUPPORT"; defaults delete "local.rvtools-analyzer.isolated.${SUPPORT//[^A-Za-z0-9]/}" 2>/dev/null || true' EXIT
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
# Captures are numbered in page order, and the numbers shift when a solution is added, so they're matched by name.
while read -r src dst; do
  file=$(ls "$TMP"/$src 2>/dev/null | head -1)
  [ -n "$file" ] || { echo "✗ No capture matches $src" >&2; exit 1; }
  sips -Z 1600 "$file" --out "docs/images/$dst" >/dev/null
done <<'LIST'
main/*-overview.png overview.png
main/*-issues.png issues.png
main/*-compute-clusters.png compute.png
main/*-vms.png virtual-machines.png
main/*-storage.png storage.png
main/*-backup-results.png backup-sizing.png
main/*-vcfsizing-results.png vcf-sizing.png
main/*-azure-results.png azure-migration.png
main/*-cloud-compare-assumptions.png custom-solution-assumptions.png
main/*-cloud-compare-results.png custom-solution-results.png
main/*-map-host.png relationship-map.png
trend/*-trend-summary.png trend-summary.png
trend/*-trend-changes.png trend-changes.png
LIST
echo "✓ Updated docs/images"
