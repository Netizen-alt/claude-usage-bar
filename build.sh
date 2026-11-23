#!/bin/bash
# Builds "Claude Usage.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"
APP="Claude Usage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal binary: Apple Silicon + Intel
TMP=$(mktemp -d)
swiftc -O -parse-as-library -target arm64-apple-macos14 Sources/main.swift -o "$TMP/arm64"
swiftc -O -parse-as-library -target x86_64-apple-macos14 Sources/main.swift -o "$TMP/x86_64"
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/ClaudeUsage"
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>local.claude-usage-bar</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" >/dev/null
echo "Built: $(pwd)/$APP"
