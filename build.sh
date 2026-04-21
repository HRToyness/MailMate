#!/usr/bin/env bash
# Build MailMate.app without Xcode (Command Line Tools only).
# Output: build/MailMate.app
set -euo pipefail

cd "$(dirname "$0")"

APP="build/MailMate.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -O \
  -parse-as-library \
  -o "$BIN_DIR/MailMate" \
  MailMate/MailMateApp.swift \
  MailMate/AppDelegate.swift \
  MailMate/Log.swift \
  MailMate/StatusController.swift \
  MailMate/ReplyDrafter.swift \
  MailMate/MailBridge.swift \
  MailMate/ReplyProvider.swift \
  MailMate/AnthropicClient.swift \
  MailMate/OpenAIClient.swift \
  MailMate/RulesLoader.swift \
  MailMate/KeychainHelper.swift \
  MailMate/SettingsView.swift \
  MailMate/VariantPanel.swift \
  MailMate/AudioRecorder.swift \
  MailMate/WhisperClient.swift \
  MailMate/DictationPanel.swift

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

codesign --force --sign - \
  --entitlements MailMate/MailMate.entitlements \
  --identifier com.toynessit.MailMate \
  "$APP"

codesign --verify --verbose=2 "$APP"

# Refresh the Services registry so "MailMate/Draft AI reply" appears in
# System Settings → Keyboard → Keyboard Shortcuts → Services.
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true

echo
echo "Built $APP"
echo "Launch:  open $APP"
