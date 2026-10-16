#!/usr/bin/env bash
set -Eeuo pipefail

REPO="vogarf816-debug/extrenal"
REF="${VESPERDASH_DEPLOY_REF:-main}"
[[ "$(id -u)" -eq 0 ]] || { echo "شغّل الأمر بصلاحية root عبر sudo." >&2; exit 1; }
[[ "$REF" =~ ^([A-Za-z0-9._/-]+|[0-9a-fA-F]{40})$ ]] || { echo "مرجع Git غير صالح." >&2; exit 1; }
[[ -r /dev/tty && -w /dev/tty ]] || { echo "خاص تشغيل الأمر من Terminal تفاعلي." >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE="$TMP_DIR/source.tar.gz"
if [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
  SOURCE_URL="https://github.com/$REPO/archive/$REF.tar.gz"
else
  SOURCE_URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
fi
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 120 -o "$ARCHIVE" "$SOURCE_URL"
mkdir -p "$TMP_DIR/source"
tar -xzf "$ARCHIVE" --strip-components=1 --no-same-owner --no-same-permissions -C "$TMP_DIR/source"
SOURCE_ROOT="$TMP_DIR/source"
[[ -f "$SOURCE_ROOT/vesperdash/apply_env_patch.py" && -f "$SOURCE_ROOT/vesperdash/deploy_update.sh" ]] || {
  echo "نسخة المستودع ما فيهاش ملفات النشر المطلوبة." >&2
  exit 1
}

read -r -p 'واش دوّرت M3SB token و HMAC secret؟ كتب ROTATED: ' answer </dev/tty
[[ "$answer" == "ROTATED" ]] || { echo "وقفنا: خاص تدوير أسرار M3SB أولاً."; exit 1; }
read -r -p 'واش عاودت شفّرت ورفعت جميع ملفات .3105 بكلمات المرور الجديدة؟ كتب READY: ' answer </dev/tty
[[ "$answer" == "READY" ]] || { echo "وقفنا: خاص إعادة تشفير ورفع الحزم أولاً."; exit 1; }
read -r -p 'باش نحدّث السيرفر، كتب DEPLOY: ' answer </dev/tty
[[ "$answer" == "DEPLOY" ]] || { echo "تلغى النشر بلا تغيير الإعدادات."; exit 0; }

# Secrets are collected with terminal echo disabled and piped directly to the root-only atomic updater.
python3 - "$SOURCE_ROOT/vesperdash" <<'PY' | python3 "$SOURCE_ROOT/vesperdash/apply_env_patch.py"
import getpass
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from apply_env_patch import validate

def secret(label):
    return getpass.getpass(label)

payload = {
    "VESPERDASH_M3SB_API_BASE_URL": "https://api.m3sbapi.shop",
    "VESPERDASH_M3SB_PACKAGE_TOKEN": secret("M3SB package token الجديد (الإدخال مخفي): "),
    "VESPERDASH_M3SB_HMAC_SECRET": secret("M3SB HMAC secret الجديد (الإدخال مخفي): "),
    "VESPERDASH_PACKAGE_PASSWORDS": secret("لائحة JSON ديال كلمات مرور .3105 الجديدة، الإدخال مخفي (مثال: [\"…\"]): "),
}
validate(payload)
json.dump(payload, sys.stdout)
PY

VESPERDASH_NONINTERACTIVE=1 \
VESPERDASH_M3SB_ROTATED_ACK=ROTATED \
VESPERDASH_PACKAGES_REENCRYPTED_ACK=READY \
VESPERDASH_DEPLOY_CONFIRM=YES \
VESPERDASH_DEPLOY_REF="$REF" \
bash "$SOURCE_ROOT/vesperdash/deploy_update.sh"
