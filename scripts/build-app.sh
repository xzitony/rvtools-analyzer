#!/bin/bash
# Builds "RVTools Analyzer.app" into ./build (no Xcode project needed — just the Swift toolchain).
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/RVTools Analyzer.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --product RVToolsAnalyzer
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling bundle…"
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

if [ ! -f build/AppIcon.icns ] || [ scripts/make_icon.swift -nt build/AppIcon.icns ]; then
  echo "▸ Rendering icon…"
  swift scripts/make_icon.swift build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>RVToolsAnalyzer</string>
  <key>CFBundleIdentifier</key><string>local.rvtools-analyzer</string>
  <key>CFBundleName</key><string>RVTools Analyzer</string>
  <key>CFBundleDisplayName</key><string>RVTools Analyzer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local RVTools analysis — data never leaves this Mac.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.rvtools-analyzer.project</string>
      <key>UTTypeDescription</key><string>RVTools Analyzer Project</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>rvaproj</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>RVTools Analyzer Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key><array><string>local.rvtools-analyzer.project</string></array>
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

echo "✓ Built $APP"
echo "  Open with:  open \"$APP\"   (or drag it to /Applications)"
