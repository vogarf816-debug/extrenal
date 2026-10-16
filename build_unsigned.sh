#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/HYperRegedit-original-identity.xcarchive"
IPA="$BUILD_DIR/HYper-Regedit-Key-Enabled-unsigned.ipa"
echo "Building repository revision: $(git -C "$ROOT" rev-parse --short HEAD)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
command -v xcodebuild >/dev/null || { echo 'xcodebuild is required on macOS' >&2; exit 127; }

xcodebuild \
  -project "$ROOT/ThreeOneOSFive.xcodeproj" \
  -scheme JVZTXNX \
  -configuration Release \
  -sdk iphoneos \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  M3SB_PACKAGE_TOKEN="${M3SB_PACKAGE_TOKEN:?M3SB_PACKAGE_TOKEN is required}" \
  M3SB_HMAC_SECRET="${M3SB_HMAC_SECRET:?M3SB_HMAC_SECRET is required}" \
  archive

APP="$ARCHIVE/Products/Applications/3105.app"
test -d "$APP"
# Remote patches must never be embedded in the signed app. Remove packages
# from every possible Xcode resource layout, not only from the app root.
find "$APP" -type f -name '*.3105' -print -delete
if find "$APP" -type f -name '*.3105' -print -quit | grep -q .; then
  echo "Error: a local .3105 patch remains inside the app bundle." >&2
  exit 1
fi
echo "Verified no bundled local patch resources; patches are loaded only from VesperDash online."

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable 3105" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP/Info.plist" || true
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -qry "$IPA" Payload
  rm -rf Payload
)
echo "$IPA"
