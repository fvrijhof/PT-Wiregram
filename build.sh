#!/bin/zsh
# Builds "PT Wiregram.app" (no Xcode needed, only Command Line Tools).
set -euo pipefail
cd "${0:A:h}"

swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0
BIN=".build/Wiregram-universal"
lipo -create -output "$BIN" \
  .build/arm64-apple-macosx/release/Wiregram \
  .build/x86_64-apple-macosx/release/Wiregram

APP="PT Wiregram.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wiregram"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PT Wiregram</string>
  <key>CFBundleDisplayName</key><string>PT Wiregram</string>
  <key>CFBundleIdentifier</key><string>nl.wiregram.protools</string>
  <key>CFBundleExecutable</key><string>Wiregram</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with a fixed designated requirement (the bundle identifier), so macOS keeps
# the Accessibility permission across rebuilds instead of tying it to this build's hash.
codesign --force --deep --sign - --identifier nl.wiregram.protools \
  -r='designated => identifier "nl.wiregram.protools"' "$APP"
echo "Built $(pwd)/$APP"
