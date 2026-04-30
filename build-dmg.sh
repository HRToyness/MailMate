#!/usr/bin/env bash
# Package MailMate.app into a distributable .dmg with a polished install
# window: branded background, positioned MailMate.app + Applications icons,
# hidden toolbar/sidebar. Requires build.sh to have been run first.
#
# The previous Setup.command + README workaround for unsigned apps is gone:
# now that the app is Developer-ID-signed and notarized, no quarantine
# stripping is needed.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/MailMate.app"
if [ ! -d "$APP" ]; then
  echo "Error: $APP not found. Run ./build.sh first."
  exit 1
fi

BG_SRC="MailMate/dmg-background.png"
if [ ! -f "$BG_SRC" ]; then
  echo "Generating DMG background..."
  swift tools/generate-dmg-background.swift "$BG_SRC"
fi

STAGING="build/dmg-staging"
RW_DMG="build/MailMate-Installer-rw.dmg"
DMG_NAME="MailMate-Installer"
DMG_PATH="build/${DMG_NAME}.dmg"
VOLUME_NAME="MailMate"
MOUNT_POINT="/Volumes/$VOLUME_NAME"

rm -rf "$STAGING" "$DMG_PATH" "$RW_DMG"
mkdir -p "$STAGING/.background"

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$BG_SRC" "$STAGING/.background/background.png"

# Build a writable DMG so we can apply Finder window properties via
# AppleScript before flattening to a compressed read-only image.
echo "Creating writable DMG..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDRW \
  "$RW_DMG" >/dev/null

rm -rf "$STAGING"

# Defensive: unmount any pre-existing volume of the same name.
if [ -d "$MOUNT_POINT" ]; then
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
fi

echo "Mounting writable DMG to apply window layout..."
hdiutil attach "$RW_DMG" -readwrite -noautoopen >/dev/null

# Give Finder a beat to register the new volume before scripting it.
sleep 1

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 200, 740, 580}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.png"
        set position of item "MailMate.app" of container window to {135, 170}
        set position of item "Applications" of container window to {405, 170}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

# Force layout to disk before unmounting.
sync
hdiutil detach "$MOUNT_POINT" >/dev/null

echo "Compressing to read-only DMG..."
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"

# If we have a Developer ID cert, sign the DMG itself (required for
# notarization of the whole thing). Fall back to no-op otherwise.
SIGNING_IDENTITY="${MAILMATE_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi

NOTARY_PROFILE="${MAILMATE_NOTARY_PROFILE:-mailmate-notary}"

if [ -n "$SIGNING_IDENTITY" ]; then
  echo "Signing DMG with Developer ID..."
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

  # Notarize + staple, only if the user has stored credentials via
  # `xcrun notarytool store-credentials $MAILMATE_NOTARY_PROFILE`.
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Submitting to Apple notary service (profile: $NOTARY_PROFILE)..."
    echo "(This typically takes 1-5 minutes.)"
    if xcrun notarytool submit "$DMG_PATH" \
         --keychain-profile "$NOTARY_PROFILE" \
         --wait; then
      echo "Stapling notarization ticket..."
      xcrun stapler staple "$DMG_PATH"
      xcrun stapler validate "$DMG_PATH"
    else
      echo "Notarization failed. DMG is signed but not notarized."
      echo "Check the log with:  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    fi
  else
    echo "No notary credentials found. Skipping notarization."
    echo "Run ./tools/setup-developer-signing.sh to store them."
  fi
else
  echo "No Developer ID found. DMG is unsigned (Gatekeeper will still block)."
fi

echo
echo "Built $DMG_PATH"
ls -lh "$DMG_PATH"
