#!/bin/sh
# Generates the Xcode project and builds the Mac app into App/build. Usage: scripts/build-mac.sh [Debug|Release]
set -e
cd "$(dirname "$0")/../App"
../scripts/generate-project.sh --quiet
xcodebuild -project Grimoire.xcodeproj -scheme Grimoire -configuration "${1:-Debug}" -destination 'platform=macOS' \
  -derivedDataPath build.noindex CODE_SIGNING_ALLOWED=YES build 2>&1 | grep -E "error:|warning: unre|BUILD|\*\* " | head -40
echo "app: $(pwd)/build.noindex/Build/Products/${1:-Debug}/Grimoire.app"
