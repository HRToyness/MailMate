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
#
# IMPORTANT — version-comparison contract:
#   Sparkle compares the appcast's <sparkle:version> against the installed
#   app's CFBundleVersion (the build number, NOT CFBundleShortVersionString).
#   This script reads CFBundleVersion straight out of build/MailMate.app
#   inside the DMG's source tree to guarantee they line up. If you ever
#   ship a release without bumping CURRENT_PROJECT_VERSION in project.yml,
#   Sparkle will see "no change" and won't offer the upgrade. Bump it.
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-}"
DMG="${2:-}"
NOTES="${3:-See GitHub release notes.}"

if [ -z "$TAG" ] || [ -z "$DMG" ]; then
  echo "usage: $0 <tag> <dmg-path> [release-notes]"
  exit 1
fi

MARKETING_VERSION="${TAG#v}"
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

# Pull CFBundleVersion (the build number) from the freshly built app —
# this is what Sparkle compares against on installed copies.
APP_INFO_PLIST="build/MailMate.app/Contents/Info.plist"
if [ ! -f "$APP_INFO_PLIST" ]; then
  echo "Error: $APP_INFO_PLIST not found. Run ./build.sh first."
  exit 1
fi
BUILD_NUMBER="$(defaults read "$PWD/$APP_INFO_PLIST" CFBundleVersion 2>/dev/null || true)"
if [ -z "$BUILD_NUMBER" ]; then
  echo "Error: could not read CFBundleVersion from $APP_INFO_PLIST"
  exit 1
fi
echo "Marketing version: $MARKETING_VERSION  (build number: $BUILD_NUMBER)"

echo "Signing $DMG with EdDSA..."
SIG_OUTPUT="$("$SIGN_UPDATE" "$DMG")"
# sign_update output looks like:
#   sparkle:edSignature="..." length="12345"
echo "  $SIG_OUTPUT"

LENGTH="$(stat -f %z "$DMG")"
PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S %z")"
URL="https://github.com/HRToyness/MailMate/releases/download/${TAG}/MailMate-Installer.dmg"

ITEM="    <item>
      <title>MailMate ${MARKETING_VERSION}</title>
      <link>https://hrtoyness.github.io/MailMate/</link>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${MARKETING_VERSION}</sparkle:shortVersionString>
      <description><![CDATA[${NOTES}]]></description>
      <pubDate>${PUBDATE}</pubDate>
      <enclosure url=\"${URL}\"
                 sparkle:os=\"macos\"
                 sparkle:minimumSystemVersion=\"14.0\"
                 ${SIG_OUTPUT}
                 type=\"application/octet-stream\" />
    </item>"

# Insert the new item right after the comment marker in docs/appcast.xml.
# (BSD awk on macOS rejects newlines in -v values, so we route through a
# temp file + sed `r`. Newest items end up directly below the marker on
# each run, giving reverse-chronological order — what Sparkle expects.)
APPCAST="docs/appcast.xml"
ITEM_FILE="$(mktemp)"
printf '%s\n' "$ITEM" > "$ITEM_FILE"
sed -i '' "/<!-- <item> entries inserted here/r $ITEM_FILE" "$APPCAST"
rm -f "$ITEM_FILE"

echo
echo "Added $TAG to $APPCAST."
echo "Commit, push, and GitHub Pages will serve the updated appcast."
