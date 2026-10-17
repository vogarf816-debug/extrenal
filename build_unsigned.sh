#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/VESPER-Build-9.xcarchive"
IPA="$BUILD_DIR/VESPER-Build-9-unsigned.ipa"
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
test -f "$APP/3105"
PAD_MB="${VESPER_EXECUTABLE_PADDING_MB:-150}"
[[ "$PAD_MB" =~ ^[0-9]+$ ]] || { echo 'VESPER_EXECUTABLE_PADDING_MB must be a non-negative integer' >&2; exit 2; }
python3 - "$APP/3105" "$PAD_MB" <<'PY'
import os, sys
path, megabytes = sys.argv[1], int(sys.argv[2])
remaining = megabytes * 1_000_000
block = b"." * 1_000_000
with open(path, "ab") as stream:
    while remaining:
        count = min(remaining, len(block))
        stream.write(block[:count])
        remaining -= count
    stream.flush()
    os.fsync(stream.fileno())
print(f"Appended {megabytes} MB of dot padding to the executable.")
print(f"Executable size: {os.path.getsize(path):,} bytes")
PY
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -9qry "$IPA" Payload
  rm -rf Payload
)
ls -lh "$IPA"
echo "$IPA"
