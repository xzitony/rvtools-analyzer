#!/bin/bash
# Runs custom solution packs against the sample exports with the current code, so a change to the app that breaks a
# solution is caught before you install the new build. Checks your installed solutions unless you name folders or packs:
#   scripts/check-solutions.sh                     ~/Library/Application Support/RVTools Analyzer/Solutions
#   scripts/check-solutions.sh <folder|pack> ...
# Exits non-zero if any pack fails to load or run.
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product rvtools-cli >/dev/null || { echo "rvtools-cli failed to build"; exit 1; }
CLI="$(swift build -c release --show-bin-path)/rvtools-cli"

if [ $# -gt 0 ]; then DIRS=("$@"); else DIRS=("$HOME/Library/Application Support/RVTools Analyzer/Solutions"); fi
PACKS=()
for d in "${DIRS[@]}"; do
  if [ -f "$d/manifest.json" ]; then
    PACKS+=("$d")
  else
    for p in "$d"/*/; do [ -f "${p}manifest.json" ] && PACKS+=("${p%/}"); done
  fi
done
if [ ${#PACKS[@]} -eq 0 ]; then
  echo "No solution packs found in: ${DIRS[*]}"
  exit 0
fi

EXPORTS=(samples/RVTools_export_all_*.xlsx)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0
for pack in "${PACKS[@]}"; do
  for export in "${EXPORTS[@]}"; do
    "$CLI" --validate-solution "$pack" "$export" >"$TMP/out" 2>"$TMP/err"
    code=$?
    if [ $code -eq 0 ]; then
      echo "✓ $(basename "$pack") — $(grep -m1 '^\*\*' "$TMP/out" | tr -d '*')"
    else
      FAILED=1
      echo "✗ $(basename "$pack") (exit $code, $(basename "$export"))"
      grep -E '^✗|^  !|^\| Blocker' "$TMP/out" | sed 's/^/    /'
      grep -v '^──' "$TMP/err" | head -15 | sed 's/^/    /'
    fi
  done
done
exit $FAILED
