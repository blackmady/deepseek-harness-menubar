#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/DeepSeekHarnessMenuBar.app"
BIN="$APP/Contents/MacOS/DeepSeekHarnessMenuBar"
VERSION="${DSH_VERSION:-1.0.0}"

command -v magick >/dev/null 2>&1 || {
  echo "Missing dependency: ImageMagick (magick)" >&2
  exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
magick -background none "$ROOT/Resources/app-icon.svg" -resize 1024x1024 -depth 8 -define png:color-type=6 "$APP/Contents/Resources/AppIcon.png"
magick -background none "$ROOT/Resources/menu-icon.svg" -resize 38x38 -depth 8 -define png:color-type=6 "$APP/Contents/Resources/MenuIcon.png"

xcrun clang "$ROOT/Sources/main.m" \
  -fobjc-arc \
  -framework Cocoa \
  -O \
  -o "$BIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>DeepSeek Harness 控制器</string>
  <key>CFBundleExecutable</key><string>DeepSeekHarnessMenuBar</string>
  <key>CFBundleIdentifier</key><string>com.blackmady.deepseek-harness-menubar</string>
  <key>CFBundleIconFile</key><string>AppIcon.png</string>
  <key>CFBundleName</key><string>DeepSeek Harness Menu Bar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"
