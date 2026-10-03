#!/bin/bash
#
# Builds a double-clickable Inbox+.app you can drag into /Applications.
#
#   Scripts/build-app.sh            # ad-hoc signed, for this Mac only
#   Scripts/build-app.sh --install  # ...and copy it into /Applications
#
# This is the local-install path. It does NOT notarize, so the result runs on this Mac and would be
# refused by Gatekeeper on anyone else's. Distributing to other people needs an Apple Developer ID
# and Scripts/package-release.sh.
#
# Set INBOXPLUS_SIGNING_IDENTITY to sign with a real or self-signed certificate instead of ad-hoc.
# Worth doing: macOS ties Full Disk Access and Automation grants to a code identity, and an ad-hoc
# signature's identity changes on every build, so every rebuild asks for permission again. A stable
# certificate is what stops that.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="Inbox+"
EXECUTABLE_NAME="InboxPlus"
BUNDLE_ID="com.inboxplus.app"
BUILD_DIR="$REPO_ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

cd "$REPO_ROOT"

VERSION="$(grep -o 'current = "[^"]*"' Sources/InboxPlusCore/InboxPlusVersion.swift | cut -d'"' -f2)"
[ -n "$VERSION" ] || { echo "error: could not read the version" >&2; exit 1; }

echo "==> Building Inbox+ $VERSION (release)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Generating the app icon"
swift Scripts/make-icon.swift docs/assets/inboxplus-logo.png Resources/AppIcon.icns >/dev/null

echo "==> Assembling the bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$EXECUTABLE_NAME" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
# Shipped alongside so the app can supervise its local runtime without a checkout.
cp "$BIN_DIR/InboxPlusRuntimeCLI" "$APP_DIR/Contents/MacOS/InboxPlusRuntimeCLI"
echo "==> Bundling the self-contained messaging runtime"
"$REPO_ROOT/Scripts/prepare-bundled-runtime.sh" "$APP_DIR/Contents/Resources/Runtime"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles the executable loads through `Bundle.module` — which traps when the
# bundle is absent, so a missing copy here is a crash on launch, not a missing image.
cp -R "$BIN_DIR/InboxPlus_InboxPlusUI.bundle" "$APP_DIR/Contents/Resources/InboxPlus_InboxPlusUI.bundle"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key>
  <string>AGPL-3.0-or-later</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Inbox+ sends your iMessage replies by asking Messages to send them. It is never used for anything else.</string>
</dict>
</plist>
PLIST

# The bundle is a directory, and Finder caches icons aggressively; touching it makes the new icon
# appear without a relaunch of Finder.
touch "$APP_DIR"

echo "==> Signing"
if [ -n "${INBOXPLUS_SIGNING_IDENTITY:-}" ]; then
  IDENTITY="$INBOXPLUS_SIGNING_IDENTITY"
  echo "    using $IDENTITY"
else
  IDENTITY="-"
  echo "    ad-hoc (permission grants will reset on every rebuild)"
fi

# Inner binaries before the outer bundle: signing outside-in invalidates the outer signature.
"$REPO_ROOT/Scripts/sign-bundled-runtime.sh" "$APP_DIR/Contents/Resources/Runtime" "$IDENTITY"
codesign --force --sign "$IDENTITY" "$APP_DIR/Contents/MacOS/InboxPlusRuntimeCLI"
codesign --force --sign "$IDENTITY" \
  --entitlements "$REPO_ROOT/Scripts/inboxplus.entitlements" \
  "$APP_DIR"
codesign --verify --strict "$APP_DIR"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
  APP_DIR="/Applications/$APP_NAME.app"
fi

echo
echo "Built $APP_DIR"
echo
echo "Open Inbox+. First launch prepares your inbox automatically."
echo
echo "For iMessage, add this exact path to Full Disk Access, then reopen Inbox+:"
echo "  $APP_DIR"
