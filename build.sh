#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Soyes.app/Contents/MacOS
cp App/Info.plist Soyes.app/Contents/Info.plist
swiftc -swift-version 5 -O -parse-as-library \
  -framework SwiftUI \
  -framework CoreAudio \
  -framework AppKit \
  -framework Foundation \
  Sources/*.swift \
  -o Soyes.app/Contents/MacOS/Soyes
codesign --force --sign - Soyes.app
rm -rf SonosPipe.app
echo "Built Soyes.app"
