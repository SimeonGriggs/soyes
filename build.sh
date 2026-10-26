#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Soyes.app/Contents/MacOS Soyes.app/Contents/Resources
cp App/Info.plist Soyes.app/Contents/Info.plist
icon_dir=$(mktemp -d)
xcrun actool \
  --compile "$icon_dir" \
  --app-icon soyes-icon \
  --output-partial-info-plist "$icon_dir/partial.plist" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --standalone-icon-behavior all \
  soyes-icon.icon >/dev/null
cp "$icon_dir/Assets.car" "$icon_dir/soyes-icon.icns" Soyes.app/Contents/Resources/
rm -rf "$icon_dir"
swiftc -swift-version 5 -O -parse-as-library \
  -framework SwiftUI \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework AppKit \
  -framework Foundation \
  Sources/*.swift \
  -o Soyes.app/Contents/MacOS/Soyes
codesign --force --sign - Soyes.app
rm -rf SonosPipe.app
echo "Built Soyes.app"
