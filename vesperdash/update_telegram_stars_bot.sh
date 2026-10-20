#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${VESPERDASH_APP_DIR:-/opt/vesperdash/app}"
SERVICE="${VESPERDASH_STARS_SERVICE:-vesperdash-telegram-bot.service}"
TMP_DIR="$(mktemp -d /tmp/vesper-stars-update.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$(id -u)" -ne 0 ]]; then
  echo 'Run this installer with sudo.' >&2
  exit 2
fi

install -d -m 0755 "$APP_DIR/vesperdash"
cd "$APP_DIR"

curl -fsSL 'https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/telegram_stars_bot.py' -o "$TMP_DIR/telegram_stars_bot.py"
curl -fsSL 'https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/telegram-stars-bot.service' -o "$TMP_DIR/telegram-stars-bot.service"
python3 -m py_compile "$TMP_DIR/telegram_stars_bot.py"

STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$APP_DIR/vesperdash/telegram_stars_bot.py" ]]; then
  cp -a "$APP_DIR/vesperdash/telegram_stars_bot.py" "$APP_DIR/vesperdash/telegram_stars_bot.py.bak.$STAMP"
fi
install -o root -g root -m 0644 "$TMP_DIR/telegram_stars_bot.py" "$APP_DIR/vesperdash/telegram_stars_bot.py"
install -o root -g root -m 0644 "$TMP_DIR/telegram-stars-bot.service" "/etc/systemd/system/$SERVICE"
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"
sleep 2
systemctl --no-pager --full status "$SERVICE" || true
printf '\nUpdated Stars bot successfully. Database and .fernet key were preserved.\n'
