#!/bin/sh
# Builds dist/AGENTGATE Studio.app: the SwiftUI app with llama.cpp bundled inside.
# Unsigned for distribution (ad-hoc signature only, so it runs on Apple Silicon).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
./scripts/fetch_runtime.sh
swift build -c release --product AgentGateStudio
BIN=$(swift build -c release --show-bin-path)
APP="$ROOT/dist/AGENTGATE Studio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"
cp "$BIN/AgentGateStudio" "$APP/Contents/MacOS/AgentGateStudio"
cp -R "$BIN/AgentGateStudio_AgentGateCore.bundle" "$APP/Contents/Resources/"
cp -R "$ROOT/dist/runtime/llama" "$APP/Contents/Resources/runtime/llama"
VERSION=$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AGENTGATE Studio</string>
  <key>CFBundleDisplayName</key><string>AGENTGATE Studio</string>
  <key>CFBundleIdentifier</key><string>com.agentgate.studio</string>
  <key>CFBundleExecutable</key><string>AgentGateStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
