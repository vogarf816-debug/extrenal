#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
IPA="${1:-$ROOT/build/VESPER-Build-27-unsigned.ipa}"

if ! command -v unzip >/dev/null 2>&1; then
  echo "Error: unzip is required." >&2
  exit 127
fi

if [[ ! -f "$IPA" ]]; then
  echo "IPA not found; building it first: $IPA" >&2
  "$ROOT/build_unsigned.sh"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vesper-esign.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

unzip -q "$IPA" -d "$WORK_DIR/unpacked"

APP_COUNT="$(find "$WORK_DIR/unpacked/Payload" -maxdepth 1 -type d -name '*.app' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$APP_COUNT" != "1" ]]; then
  echo "Error: expected exactly one app bundle directly under Payload; found $APP_COUNT." >&2
  exit 1
fi

APP="$(find "$WORK_DIR/unpacked/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -e "$APP/embedded.mobileprovision" || -e "$APP/_CodeSignature" ]]; then
  echo "Error: the IPA contains an existing provisioning profile or code signature." >&2
  echo "Build with build_unsigned.sh so eSign can apply the selected certificate and profile." >&2
  exit 1
fi

if [[ ! -x "$APP/VESPER" ]]; then
  echo "Error: expected VESPER executable was not found in the app bundle." >&2
  exit 1
fi
EXECUTABLE_BYTES="$(wc -c < "$APP/VESPER" | tr -d ' ')"
if [[ "$EXECUTABLE_BYTES" -lt 690000000 ]]; then
  echo "Error: expected approximately 690 MB of VESPER executable padding; found $EXECUTABLE_BYTES bytes." >&2
  exit 1
fi

if [[ ! -f "$APP/Info.plist" ]]; then
  echo "Error: the app bundle is missing Info.plist." >&2
  exit 1
fi
if find "$APP" -type d -name '*.lproj' -print -quit | grep -q .; then
  echo "Error: localized .lproj folders should be embedded in the VESPER executable." >&2
  exit 1
fi
python3 "$ROOT/embed_app_resources.py" --verify "$APP"

echo "eSign-ready IPA verified: $IPA"
echo "App bundle: $APP"
echo "Executable size: $EXECUTABLE_BYTES bytes"
echo "The IPA is unsigned and contains no embedded provisioning profile."
