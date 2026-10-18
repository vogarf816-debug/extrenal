#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/VESPER-Build-26.xcarchive"
IPA="$BUILD_DIR/VESPER-Build-26-unsigned.ipa"
echo "Building repository revision: $(git -C "$ROOT" rev-parse --short HEAD)"

if [[ -z "${M3SB_PACKAGE_TOKEN:-}" || -z "${M3SB_HMAC_SECRET:-}" ]]; then
  echo 'M3SB_PACKAGE_TOKEN and M3SB_HMAC_SECRET must be configured as build secrets.' >&2
  exit 2
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
command -v xcodebuild >/dev/null || { echo 'xcodebuild is required on macOS' >&2; exit 127; }
python3 "$ROOT/generate_embedded_localizations.py"

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

APP="$ARCHIVE/Products/Applications/VESPER.app"
test -d "$APP"
# Remote patches must never be embedded in the signed app. Remove packages
# from every possible Xcode resource layout, not only from the app root.
find "$APP" -type f -name '*.3105' -print -delete
if find "$APP" -type f -name '*.3105' -print -quit | grep -q .; then
  echo "Error: a local .3105 patch remains inside the app bundle." >&2
  exit 1
fi
echo "Verified no bundled local patch resources; patches are loaded only from VesperDash online."

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable VESPER" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP/Info.plist" || true
python3 - "$APP/Info.plist" <<'PY'
import base64
import os
import plistlib
import sys

path = sys.argv[1]
values = {
    "M3SB_PACKAGE_TOKEN_OBFUSCATED": os.environ["M3SB_PACKAGE_TOKEN"],
    "M3SB_HMAC_SECRET_OBFUSCATED": os.environ["M3SB_HMAC_SECRET"],
}
with open(path, "rb") as stream:
    info = plistlib.load(stream)
info.pop("M3SB_PACKAGE_TOKEN", None)
info.pop("M3SB_HMAC_SECRET", None)
for key, value in values.items():
    raw = value.encode("utf-8")
    obfuscated = bytes(byte ^ 0x5A for byte in raw)
    info[key] = base64.b64encode(obfuscated).decode("ascii")
with open(path, "wb") as stream:
    plistlib.dump(info, stream, fmt=plistlib.FMT_XML, sort_keys=False)
print("Embedded obfuscated M3SB configuration in the app bundle.")
PY

test -f "$APP/VESPER"
PAD_MB="${VESPER_EXECUTABLE_PADDING_MB:-690}"
[[ "$PAD_MB" =~ ^[0-9]+$ ]] || { echo 'VESPER_EXECUTABLE_PADDING_MB must be a non-negative integer' >&2; exit 2; }
(( PAD_MB == 690 )) || { echo 'VESPER_EXECUTABLE_PADDING_MB must be exactly 690 MB for this build.' >&2; exit 2; }
python3 - "$APP/VESPER" "$PAD_MB" <<'PY'
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
python3 "$ROOT/embed_app_resources.py" "$APP"
python3 "$ROOT/embed_app_resources.py" --strip-audio "$APP"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
(
  cd "$BUILD_DIR"
  /usr/bin/zip -9qry "$IPA" Payload
  rm -rf Payload
)
ls -lh "$IPA"
echo "$IPA"
