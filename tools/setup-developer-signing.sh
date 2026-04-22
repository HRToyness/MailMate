#!/usr/bin/env bash
# One-time setup for Developer ID signing + notarization.
# Prerequisites (do these first via Xcode or developer.apple.com):
#   1. Enrolled in the Apple Developer Program.
#   2. A "Developer ID Application" certificate installed in your login
#      keychain. The easiest path is Xcode > Settings > Accounts > your
#      Apple ID > Manage Certificates > + > Developer ID Application.
#   3. An app-specific password for your Apple ID, created at
#      https://account.apple.com > Sign-In and Security > App-Specific
#      Passwords > +. Label it "MailMate notary" or similar.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "MailMate — Developer signing setup"
echo "==================================="
echo

# 1. Verify a Developer ID Application identity is in the keychain.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')"

if [ -z "$IDENTITY" ]; then
  echo "❌  No 'Developer ID Application' certificate found in your keychain."
  echo
  echo "Install one via Xcode:"
  echo "   Xcode > Settings > Accounts > (your Apple ID) > Manage Certificates"
  echo "   + > Developer ID Application"
  echo
  echo "Or via https://developer.apple.com/account/resources/certificates."
  echo
  echo "Then re-run this script."
  exit 1
fi

echo "✓  Found Developer ID certificate:"
echo "   $IDENTITY"

# Extract Team ID from the cert CN (last 10 chars in parens).
TEAM_ID="$(echo "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))/\1/p')"
echo "   Team ID: ${TEAM_ID:-unknown}"
echo

# 2. Check if notary credentials are already stored.
PROFILE="${MAILMATE_NOTARY_PROFILE:-mailmate-notary}"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "✓  Notary credentials already stored under profile: $PROFILE"
  echo "   (Delete with: security delete-generic-password -s \"com.apple.gke.notary.tool\" -a \"$PROFILE\")"
  echo
else
  echo "Storing notary credentials under profile: $PROFILE"
  echo
  echo "You'll need:"
  echo "  - Your Apple ID email (the one with the Developer Program)"
  echo "  - Your Team ID (${TEAM_ID:-shown above})"
  echo "  - An app-specific password from https://account.apple.com"
  echo
  echo "Running: xcrun notarytool store-credentials"
  echo
  xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "" \
    --team-id "${TEAM_ID:-}" \
    || {
      echo
      echo "notarytool didn't complete. You can re-run this script, or run directly:"
      echo "  xcrun notarytool store-credentials \"$PROFILE\""
      exit 1
    }
  echo
  echo "✓  Notary credentials stored."
fi

echo
echo "All set. Build + notarize with:"
echo "   ./build.sh && ./build-dmg.sh"
echo
echo "build.sh auto-detects the Developer ID cert; build-dmg.sh auto-detects"
echo "the notary profile. No env vars needed."
