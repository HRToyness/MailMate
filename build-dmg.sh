#!/usr/bin/env bash
# Package MailMate.app into a distributable .dmg with:
# - Applications symlink (drag-to-install target)
# - Setup.command script that strips the quarantine attribute and launches
# - README with first-run instructions
# Requires build.sh to have been run first.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/MailMate.app"
if [ ! -d "$APP" ]; then
  echo "Error: $APP not found. Run ./build.sh first."
  exit 1
fi

STAGING="build/dmg-staging"
DMG_NAME="MailMate-Installer"
DMG_PATH="build/${DMG_NAME}.dmg"
VOLUME_NAME="MailMate"

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/Setup.command" <<'EOF'
#!/usr/bin/env bash
# One-time setup: remove macOS quarantine flag from MailMate so it can
# launch without Gatekeeper warnings, then open the app.
set -euo pipefail

APP="/Applications/MailMate.app"

if [ ! -d "$APP" ]; then
  echo "MailMate.app is not in /Applications."
  echo
  echo "Drag MailMate.app into the Applications folder first, then run this script again."
  echo
  read -n 1 -s -r -p "Press any key to close..."
  exit 1
fi

echo "Removing quarantine flag on $APP"
xattr -rd com.apple.quarantine "$APP" 2>/dev/null || true

echo "Launching MailMate"
open "$APP"

echo
echo "Done. You can close this window."
sleep 2
EOF
chmod +x "$STAGING/Setup.command"

cat > "$STAGING/README.txt" <<'EOF'
MailMate - first-run setup
==========================

1. Drag MailMate.app into the "Applications" folder.

2. Double-click "Setup.command".
   (If macOS blocks it, right-click -> Open -> Open.)

   This strips the quarantine flag and launches MailMate once.

3. Look for the envelope icon in your menu bar. Click it ->
   Settings... -> paste your Anthropic and/or OpenAI API key.

4. On first use, macOS will ask for permissions:
   - Automation (to read Mail and open reply windows)
   - Accessibility (to paste the reply - System Settings ->
     Privacy & Security -> Accessibility -> enable MailMate)
   - Microphone (only when using Dictate a reply)

5. Optional: bind keyboard shortcuts in System Settings ->
   Keyboard -> Keyboard Shortcuts -> Services ->
   MailMate/Draft AI reply  and  MailMate/Dictate AI reply

Source: https://github.com/HRToyness/MailMate
EOF

echo "Creating $DMG_PATH ..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING"

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
