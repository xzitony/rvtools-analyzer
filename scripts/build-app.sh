#!/bin/bash
# Builds the app bundle into ./build (no Xcode project needed — just the Swift toolchain).
#   scripts/build-app.sh            release build → "RVTools Analyzer.app"      the copy you use for real (see install-app.sh)
#   scripts/build-app.sh dev        release build → "RVTools Analyzer Dev.app"  for development
#   scripts/build-app.sh debug      debug build   → "RVTools Analyzer Dev.app"
# Dev builds have their own bundle id, so their settings, recent projects and saved assumptions are separate, and their
# own ~/Library/Application Support/RVTools Analyzer Dev/ folder, so they never load your real custom solutions.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Command Line Tools can lack the SwiftUI macro plugins (e.g. right after a macOS upgrade), which breaks @State and
# friends. When they're the active developer directory and Xcode is installed, build with Xcode's toolchain instead.
if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "▸ Using Xcode's toolchain (the Command Line Tools are selected)"
fi

MODE="${1:-release}"
case "$MODE" in
  release)
    CONFIG=release; NAME="RVTools Analyzer"; BUNDLE_ID="local.rvtools-analyzer"; SUPPORT="RVTools Analyzer"
    RANK=Owner; TYPES_KEY=UTExportedTypeDeclarations; VARIANT=release; ICON=build/AppIcon.icns; ICON_FLAGS="" ;;
  dev|debug)
    CONFIG=$([ "$MODE" = debug ] && echo debug || echo release); NAME="RVTools Analyzer Dev"; BUNDLE_ID="local.rvtools-analyzer.dev"
    SUPPORT="RVTools Analyzer Dev"; RANK=Alternate; TYPES_KEY=UTImportedTypeDeclarations; VARIANT=dev; ICON=build/AppIcon-dev.icns; ICON_FLAGS="--dev" ;;
  *)
    echo "usage: scripts/build-app.sh [release|dev|debug]"; exit 1 ;;
esac
APP="build/$NAME.app"
# Shown in About: the commit the build came from ("-dirty" = uncommitted changes), and when it was built.
BUILD="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --product RVToolsAnalyzer
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling $NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RVToolsAnalyzer" "$APP/Contents/MacOS/RVToolsAnalyzer"

SAMPLE="$(ls samples/RVTools_export_all_*.xlsx 2>/dev/null | head -1 || true)"
if [ -n "$SAMPLE" ]; then
  cp "$SAMPLE" "$APP/Contents/Resources/RVTools_sample.xlsx"
fi
# Monthly series for trend mode (scripts/generate_series.py)
if ls samples/series/RVTools_export_all_*.xlsx >/dev/null 2>&1; then
  mkdir -p "$APP/Contents/Resources/RVTools_sample_series"
  cp samples/series/RVTools_export_all_*.xlsx "$APP/Contents/Resources/RVTools_sample_series/"
fi

# Custom solution examples and the authoring guide (Solutions menu › Install Examples / Authoring Guide)
mkdir -p "$APP/Contents/Resources/Examples"
cp -R examples/solutions examples/price-lists "$APP/Contents/Resources/Examples/"
cp docs/SOLUTIONS.md "$APP/Contents/Resources/SOLUTIONS.md"

if [ ! -f "$ICON" ] || [ scripts/make_icon.swift -nt "$ICON" ]; then
  echo "▸ Rendering icon…"
  mkdir -p build
  swift scripts/make_icon.swift "$ICON" $ICON_FLAGS
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>RVToolsAnalyzer</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>RVTASupportFolder</key><string>$SUPPORT</string>
  <key>RVTABuildVariant</key><string>$VARIANT</string>
  <key>RVTABuild</key><string>$BUILD</string>
  <key>RVTABuildDate</key><string>$BUILD_DATE</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local RVTools analysis — data never leaves this Mac.</string>
  <key>$TYPES_KEY</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.rvtools-analyzer.project</string>
      <key>UTTypeDescription</key><string>RVTools Analyzer Project</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>rvaproj</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>local.rvtools-analyzer.solution</string>
      <key>UTTypeDescription</key><string>RVTools Analyzer Custom Solution</string>
      <key>UTTypeConformsTo</key><array><string>public.folder</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>rvasolution</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>local.rvtools-analyzer.prices</string>
      <key>UTTypeDescription</key><string>RVTools Analyzer Price List</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>rvaprices</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>RVTools Analyzer Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>$RANK</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key><array><string>local.rvtools-analyzer.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>RVTools Analyzer Custom Solution</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>$RANK</string>
      <key>LSItemContentTypes</key><array><string>local.rvtools-analyzer.solution</string><string>local.rvtools-analyzer.prices</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>RVTools Excel export</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>org.openxmlformats.spreadsheetml.sheet</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>RVTools CSV export</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.comma-separated-values-text</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - "$APP" >/dev/null

echo "✓ Built $APP ($BUILD)"
echo "  Open with:  open \"$APP\""
