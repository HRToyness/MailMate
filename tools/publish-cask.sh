#!/usr/bin/env bash
# Generates a Homebrew cask ruby file for the latest GitHub release.
# Output: build/mailmate.rb
#
# Usage:
#   ./tools/publish-cask.sh                # uses the latest GitHub release
#   ./tools/publish-cask.sh v0.5.0         # pin to a specific tag
#
# Prerequisites:
#   - gh CLI authenticated (gh auth status)
#   - A DMG already uploaded to the target release
#
# Once generated, copy build/mailmate.rb into your tap repo:
#   git clone git@github.com:HRToyness/homebrew-tap.git
#   cp build/mailmate.rb homebrew-tap/Casks/
#   cd homebrew-tap && git add Casks/mailmate.rb && git commit -m "update mailmate" && git push
#
# Users then install with:
#   brew tap HRToyness/tap
#   brew install --cask mailmate
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-}"
if [ -z "$TAG" ]; then
  TAG="$(gh release view --json tagName --jq .tagName)"
  echo "Using latest release: $TAG"
fi
VERSION="${TAG#v}"

# Fetch DMG to compute SHA-256. Keep a copy in build/ for inspection.
mkdir -p build
DMG="build/MailMate-Installer-${VERSION}.dmg"
URL="https://github.com/HRToyness/MailMate/releases/download/${TAG}/MailMate-Installer.dmg"

echo "Downloading $URL..."
curl -sL -o "$DMG" "$URL"

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "SHA-256: $SHA"

OUT="build/mailmate.rb"
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@SHA256@/$SHA/g" \
  tools/mailmate.rb.template > "$OUT"

echo
echo "Wrote $OUT"
echo
echo "Next steps:"
echo "  1. cp $OUT <your-tap-repo>/Casks/mailmate.rb"
echo "  2. Commit + push the tap repo."
echo "  3. Users install with: brew tap HRToyness/tap && brew install --cask mailmate"
