#!/usr/bin/env bash
# Build SC680Config Release (Apple Silicon) and produce a distributable .dmg (+ .zip).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/SC680Config.xcodeproj"
SCHEME="SC680Config"
BUILD_ROOT="$ROOT/build"
DERIVED="$BUILD_ROOT/DerivedData"
APP_PATH="$DERIVED/Build/Products/Release/SC680Config.app"
PLIST="$ROOT/SC680Config/Info.plist"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: run this script on macOS (Xcode required)." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode from the App Store." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
ARTIFACT_BASE="SC680Config-${VERSION}-build${BUILD}-macOS-arm64"

# Ad-hoc sign by default (no Apple Developer account). Override for notarized builds:
#   export CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

echo "==> Building ${SCHEME} ${VERSION} (${BUILD}) for arm64…"
rm -rf "$DERIVED"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  CODE_SIGNING_ALLOWED=YES \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app at $APP_PATH" >&2
  exit 1
fi

echo "==> Staging disk image…"
STAGING="$BUILD_ROOT/dmg-staging"
DMG_OUT="$BUILD_ROOT/${ARTIFACT_BASE}.dmg"
ZIP_OUT="$BUILD_ROOT/${ARTIFACT_BASE}.zip"

rm -rf "$STAGING" "$DMG_OUT"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/SC680Config.app"
ln -sf /Applications "$STAGING/Applications"

echo "==> Creating ${DMG_OUT}…"
hdiutil create \
  -volname "AULA SC680" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_OUT" >/dev/null

rm -rf "$STAGING"

echo "==> Creating ${ZIP_OUT}…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_OUT"

echo ""
echo "Done."
echo "  DMG: $DMG_OUT"
echo "  ZIP: $ZIP_OUT"
echo ""
echo "Install: open the DMG, drag SC680Config to Applications."
echo "First launch (ad-hoc sign): Control-click the app → Open, or:"
echo "  xattr -cr /Applications/SC680Config.app"
