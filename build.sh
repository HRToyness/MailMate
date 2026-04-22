#!/usr/bin/env bash
# Build MailMate.app without Xcode (Command Line Tools only).
# Produces a universal (arm64 + x86_64) binary so the .app runs on any Mac.
# Output: build/MailMate.app
set -euo pipefail

cd "$(dirname "$0")"

APP="build/MailMate.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
TMP="build/tmp"

SOURCES=(
  MailMate/MailMateApp.swift
  MailMate/AppDelegate.swift
  MailMate/Log.swift
  MailMate/DesignSystem.swift
  MailMate/StatusController.swift
  MailMate/ReplyDrafter.swift
  MailMate/MailBridge.swift
  MailMate/ReplyProvider.swift
  MailMate/AnthropicClient.swift
  MailMate/OpenAIClient.swift
  MailMate/RulesLoader.swift
  MailMate/RulesEditor.swift
  MailMate/KeychainHelper.swift
  MailMate/LoginItem.swift
  MailMate/WelcomeView.swift
  MailMate/SettingsView.swift
  MailMate/VariantPanel.swift
  MailMate/AudioRecorder.swift
  MailMate/WhisperClient.swift
  MailMate/DictationPanel.swift
  MailMate/SummaryPanel.swift
  MailMate/TaskCapture.swift
  MailMate/CalendarContext.swift
  MailMate/TriagePanel.swift
  MailMate/RulesProposalPanel.swift
)

rm -rf "$APP" "$TMP"
mkdir -p "$BIN_DIR" "$RES_DIR" "$TMP"

build_arch() {
  local arch="$1"
  local out="$2"
  swiftc \
    -sdk "$SDK" \
    -target "${arch}-apple-macos14.0" \
    -O \
    -parse-as-library \
    -o "$out" \
    "${SOURCES[@]}"
}

echo "Building arm64…"
build_arch arm64 "$TMP/MailMate-arm64"

echo "Building x86_64…"
build_arch x86_64 "$TMP/MailMate-x86_64"

echo "Merging with lipo…"
lipo -create "$TMP/MailMate-arm64" "$TMP/MailMate-x86_64" -output "$BIN_DIR/MailMate"
lipo -info "$BIN_DIR/MailMate"

rm -rf "$TMP"

# Info.plist: expand $(...) placeholders for standalone (non-Xcode) build.
sed \
  -e 's|\$(DEVELOPMENT_LANGUAGE)|en|g' \
  -e 's|\$(EXECUTABLE_NAME)|MailMate|g' \
  -e 's|\$(PRODUCT_BUNDLE_IDENTIFIER)|com.toynessit.MailMate|g' \
  -e 's|\$(PRODUCT_NAME)|MailMate|g' \
  -e 's|\$(PRODUCT_BUNDLE_PACKAGE_TYPE)|APPL|g' \
  -e 's|\$(MARKETING_VERSION)|0.1.0|g' \
  -e 's|\$(CURRENT_PROJECT_VERSION)|1|g' \
  -e 's|\$(MACOSX_DEPLOYMENT_TARGET)|14.0|g' \
  MailMate/Info.plist > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Copy app icon into the bundle's Resources.
if [ -f MailMate/AppIcon.icns ]; then
  cp MailMate/AppIcon.icns "$RES_DIR/AppIcon.icns"
else
  echo "Warning: MailMate/AppIcon.icns not found; build without icon. Run ./tools/build-icon.sh to generate it."
fi

# Copy localization bundles.
for lproj in MailMate/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$RES_DIR/"
done

codesign --force --sign - \
  --entitlements MailMate/MailMate.entitlements \
  --identifier com.toynessit.MailMate \
  "$APP"

codesign --verify --verbose=2 "$APP"

# Refresh the Services registry so "MailMate/Draft AI reply" and
# "MailMate/Dictate AI reply" appear in System Settings → Keyboard → Services.
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true

echo
echo "Built $APP"
echo "Launch:  open $APP"
