#!/bin/sh
# Rebuilds the Mac app, quits the running Grimoire, installs the new build into ~/Applications and relaunches it.
# Edits are saved a moment after typing and on quit, so nothing is lost. Usage: scripts/reload-mac.sh [Debug|Release]
set -e
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
scripts/build-mac.sh "$CONFIG" | tee /tmp/grimoire-build.log
grep -q "BUILD SUCCEEDED" /tmp/grimoire-build.log || { echo "build failed; the running app was left alone"; exit 1; }
osascript -e 'tell application "Grimoire" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Grimoire >/dev/null || break; sleep 1; done
pgrep -x Grimoire >/dev/null && { echo "Grimoire would not quit; not replacing it"; exit 1; }
rm -rf ~/Applications/Grimoire.app.new
ditto "App/build.noindex/Build/Products/$CONFIG/Grimoire.app" ~/Applications/Grimoire.app.new
rm -rf ~/Applications/Grimoire.app && mv ~/Applications/Grimoire.app.new ~/Applications/Grimoire.app
open ~/Applications/Grimoire.app
echo "reloaded ~/Applications/Grimoire.app"
