# Telegram Stars key shop

The standalone bot sells preloaded license keys for Telegram Stars. Prices and customer-facing messages are stored in the protected SQLite database and can be changed from the Telegram admin panel; no code edit is required:

| Key | Price |
|---|---:|
| 1 HOUR KEY | 30 Stars |
| 1 DAY KEY | 150 Stars |
| 7 DAY KEY | 250 Stars |
| 31 DAY KEY | 650 Stars |

The bot uses Telegram's native `XTR` invoices. Stock is encrypted in SQLite; the Fernet key is stored in a separate mode-`0600` file beside the database. The systemd unit keeps its database under `/var/lib/vesperdash-telegram-bot` and loads credentials from `/etc/vesperdash-telegram-bot.env`.

## Deploy on the VesperDash VPS

These commands assume the VesperDash app and virtual environment already exist at `/opt/vesperdash/app` and `/opt/vesperdash/venv`, and the `vesperdash` service account exists. Copy the bot and unit from the repository to the VPS using your normal authenticated deployment method; never put the bot token in Git, command-line arguments, or chat.

Create a bot with Telegram's official BotFather, then obtain your numeric Telegram user ID for the administrator. Create the protected environment file and enter the values interactively:

```bash
sudo install -o root -g root -m 0600 /dev/null /etc/vesperdash-telegram-bot.env
sudoedit /etc/vesperdash-telegram-bot.env
```

Enter exactly these two assignments (replace the example values in the editor):

```ini
TELEGRAM_BOT_TOKEN=your_bot_token_from_botfather
TELEGRAM_ADMIN_ID=your_numeric_telegram_user_id
```

Then install and start the service:

```bash
sudo install -o root -g root -m 0644 \
  /opt/vesperdash/app/telegram-stars-bot.service \
  /etc/systemd/system/vesperdash-telegram-bot.service
sudo systemctl daemon-reload
sudo systemctl enable --now vesperdash-telegram-bot.service
sudo systemctl status --no-pager vesperdash-telegram-bot.service
```

Check logs without printing the credentials:

```bash
sudo journalctl -u vesperdash-telegram-bot.service -n 100 --no-pager
```

## Admin workflow

Open the bot in Telegram using the account whose ID is configured in `TELEGRAM_ADMIN_ID`; the bot grants admin controls only to that ID. The admin panel can:

- add keys for any plan (paste one key per line), review available/reserved/sold stock, remove unsold keys, and view sales;
- open **Edit prices & plans** and change a plan's `stars`, `display`, `label`, or `enabled` flag. For example, send `stars=200` and `display=2 days`, one setting per line;
- open **Edit bot texts** and replace the home, help, invoice, out-of-stock, payment, refund, empty-orders, admin panel, and sale-notification messages. HTML is supported, and placeholders such as `{label}`, `{display}`, `{key}`, `{stars}`, `{buyer}`, `{user_id}`, and `{order_id}` remain available where applicable.

All changes apply immediately to new messages and invoices. Existing paid orders keep the price recorded at the time of purchase. Keys are encrypted at rest. Back up the database and its adjacent `.fernet` key together; losing the key makes encrypted stock unrecoverable. Keep both files access-restricted.

Users choose a plan, receive a native Stars invoice, and are delivered a key in a private chat only after Telegram confirms successful payment. A key is reserved only after valid pre-checkout, duplicate callbacks cannot deliver or charge twice, and failed delivery/refund paths are recorded for admin review. Telegram's Stars refunds and payment lifecycle are governed by Telegram; test with a private bot before advertising it.

## Updating and troubleshooting

After deploying updated code, restart and inspect the service:

```bash
sudo systemctl restart vesperdash-telegram-bot.service
sudo journalctl -u vesperdash-telegram-bot.service -f
```

If startup reports missing configuration, check that the environment file has exactly the two required variables, is owned by root, and has mode `0600`. Confirm the Telegram bot token is valid and that the host can reach `api.telegram.org` over HTTPS. Never paste the token into logs, GitHub issues, or chat; rotate it through BotFather if exposed.

Run the local unit tests from the repository root with:

```bash
python3 -m unittest vesperdash.test_telegram_stars_bot -v
```
