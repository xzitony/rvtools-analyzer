#!/bin/bash
# Builds the release app, checks your installed custom solutions against it, and installs it as
# /Applications/RVTools Analyzer.app — the copy you use for real. Use scripts/build-app.sh dev while developing.
#   scripts/install-app.sh            stops if a custom solution fails the check
#   scripts/install-app.sh --force    installs anyway
set -euo pipefail
cd "$(dirname "$0")/.."

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

scripts/build-app.sh release
echo "▸ Checking custom solutions…"
if ! scripts/check-solutions.sh; then
  if [ $FORCE -eq 0 ]; then
    echo "✗ A custom solution fails with this build — not installing. Fix it, or run scripts/install-app.sh --force."
    exit 1
  fi
fi

DEST="/Applications/RVTools Analyzer.app"
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then
  echo "✗ RVTools Analyzer is running — quit it first (saved projects autosave)."
  exit 1
fi
rm -rf "$DEST"
ditto "build/RVTools Analyzer.app" "$DEST"
echo "✓ Installed $DEST ($(git describe --tags --always --dirty 2>/dev/null || echo "unversioned"))"
