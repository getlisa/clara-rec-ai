#!/bin/bash
# Increments the build number and regenerates the Xcode project.
#
# App Store Connect rejects an upload whose build number it has already seen, so this must
# be run before every upload. The marketing version (0.1.0) only changes for releases.
#
#   ./bump-build.sh          -> 1, 2, 3, ...
#   ./bump-build.sh 0.2.0    -> also sets the marketing version

set -euo pipefail
cd "$(dirname "$0")"

current=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | grep -oE '[0-9]+' | head -1)
next=$((current + 1))
sed -i '' -E "s/(CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\1\"${next}\"/" project.yml

if [ $# -ge 1 ]; then
    sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]+\"/\1\"$1\"/" project.yml
fi

marketing=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | sed -E 's/.*"(.*)".*/\1/')

xcodegen generate >/dev/null
echo "version ${marketing}, build ${current} -> ${next}"
