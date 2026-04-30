#!/usr/bin/env bash
# Adds a new release entry to docs/appcast.xml, EdDSA-signed with the key
# stored in the login keychain by Sparkle's generate_keys tool.
#
# Prerequisites:
#   1. vendor/Sparkle.framework unpacked (from the Sparkle release tarball).
#   2. The Sparkle tarball also ships with `bin/generate_keys`, `bin/sign_update`,
#      and `bin/generate_appcast`. Expected location: vendor/Sparkle-bin/bin/
#      (unpack the "bin" folder from the tarball there).
#   3. A key pair created once:  ./vendor/Sparkle-bin/bin/generate_keys
#      — this stores the private key in your login keychain and prints the
#      public key. Paste that public key into Info.plist's SUPublicEDKey.
#
# Usage:
#   ./tools/sparkle-publish.sh v0.6.0 "path/to/MailMate-Installer.dmg" \
#     "First notarized release with auto-updater."
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-}"
DMG="${2:-}"
NOTES="${3:-See GitHub release notes.}"

if [ -z "$TAG" ] || [ -z "$DMG" ]; then
  echo "usage: $0 <tag> <dmg-path> [release-notes]"
  exit 1
fi

VERSION="${TAG#v}"
SIGN_UPDATE="./vendor/Sparkle-bin/bin/sign_update"

if [ ! -x "$SIGN_UPDATE" ]; then
  echo "Error: $SIGN_UPDATE not found or not executable."
  echo "Unpack the Sparkle release's 'bin' folder into vendor/Sparkle-bin/."
  exit 1
fi
if [ ! -f "$DMG" ]; then
  echo "Error: DMG not found at $DMG"
  exit 1
fi

echo "Signing $DMG with EdDSA..."
SIG_OUTPUT="$("$SIGN_UPDATE" "$DMG")"
# sign_update output looks like:
#   sparkle:edSignature="..." length="12345"
echo "  $SIG_OUTPUT"

LENGTH="$(stat -f %z "$DMG")"
PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S %z")"
URL="https://github.com/HRToyness/MailMate/releases/download/${TAG}/MailMate-Installer.dmg"

ITEM="    <item>
      <title>MailMate ${VERSION}</title>
      <link>https://hrtoyness.github.io/MailMate/</link>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <description><![CDATA[${NOTES}]]></description>
      <pubDate>${PUBDATE}</pubDate>
      <enclosure url=\"${URL}\"
                 sparkle:os=\"macos\"
                 sparkle:minimumSystemVersion=\"14.0\"
                 ${SIG_OUTPUT}
                 type=\"application/octet-stream\" />
    </item>"

# Insert the new item right after the comment marker in docs/appcast.xml.
APPCAST="docs/appcast.xml"
TMP="$(mktemp)"
awk -v item="$ITEM" '
  /<!-- <item> entries inserted here/ {
    print item
    print $0
    next
  }
  { print }
' "$APPCAST" > "$TMP"
mv "$TMP" "$APPCAST"

echo
echo "Added $TAG to $APPCAST."
echo "Commit, push, and GitHub Pages will serve the updated appcast."
