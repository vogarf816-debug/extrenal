# VESPER Reseller Bot — separate deployment

This is a **new, independent Telegram bot**. It does not reuse the existing Stars shop bot's token, admin configuration, database, keys, or service. The reseller bot has its own `RESELLER_BOT_TOKEN`, `RESELLER_ADMIN_ID`, SQLite database, encryption key, and systemd unit.

## What it does

- Invite-only reseller accounts are approved by the administrator using the reseller's numeric Telegram ID.
- When the administrator adds credit to a new reseller ID, the bot generates a login username and one-time password. The bot shows the credentials only in the administrator's private chat. Share them privately with the intended reseller.
- A login works only from the Telegram account whose ID the administrator approved. Passwords are stored as salted PBKDF2 hashes, not plaintext. Five failed attempts trigger a 15-minute lock; successful sessions expire after 30 days. Resetting credentials revokes the old session.
- Reseller prices and the credit balance are shown only after the approved account logs in. Non-approved users see the invite-only message, not reseller prices.
- The administrator adds keys to this bot's separate stock by plan. Keys are Fernet-encrypted in this bot's database. On purchase, the bot atomically deducts credit, marks one key sold, delivers it privately, and notifies the administrator without including the key.
- Failed deliveries remain pending and are retried after the bot restarts and periodically while it runs.

## Reseller plans

- 1 day key: 0.99 credits
- 7 day key: 2.50 credits
- 31 day key: 5.00 credits

The amounts are internal credit units. The administrator grants them manually; the bot has no automatic credit top-up or external payment integration.

## Suggested public bot description

> VESPER Reseller Access is an invite-only portal for approved resellers. Contact the administrator with your Telegram ID to request access. Approved accounts receive private login credentials and can access their credit balance and key plans after signing in.

The public description intentionally does not disclose reseller prices.

## New credentials

Create a **new bot** with `@BotFather` and keep its bot token private. Do not paste the token into source code, GitHub, or a chat. On the VPS, create a separate root-only environment file:

```bash
sudo install -o root -g root -m 0600 /dev/null /etc/vesperdash-reseller-bot.env
sudo nano /etc/vesperdash-reseller-bot.env
```

Add these two lines in the editor, replacing the placeholders locally on the VPS:

```text
RESELLER_BOT_TOKEN=PASTE_THE_NEW_BOTFATHER_TOKEN_HERE
RESELLER_ADMIN_ID=YOUR_NUMERIC_TELEGRAM_ID
```

Save the file and confirm it is protected:

```bash
sudo chown root:root /etc/vesperdash-reseller-bot.env
sudo chmod 0600 /etc/vesperdash-reseller-bot.env
```

Use the numeric ID of the Telegram account that will operate this new bot. It may be the same person as the other bot's admin, but it is configured independently.

## Install and start

The existing VesperDash virtual environment already includes `cryptography` in `requirements.txt`. After copying `vesper_reseller_bot.py` and `vesper-reseller-bot.service` into `/opt/vesperdash/app/`, install and start the new unit:

```bash
sudo install -m 0644 /opt/vesperdash/app/vesper-reseller-bot.service /etc/systemd/system/vesper-reseller-bot.service
sudo systemctl daemon-reload
sudo systemctl enable --now vesper-reseller-bot
sudo systemctl status vesper-reseller-bot --no-pager
```

The database and Fernet key are created automatically in `/var/lib/vesperdash-reseller-bot/` with restrictive permissions. Back up both the SQLite database and its `.fernet` key together; without the key, encrypted stock cannot be decrypted.

## Admin workflow

1. Open `/admin` in the new bot and choose **Add key stock** to load one or more keys for a plan (one key per line).
2. Choose **Manage resellers → Approve reseller / add credit** and send `TELEGRAM_ID CREDIT_AMOUNT`, for example `123456789 10.00`.
3. For a new ID, copy the generated username and one-time password from the admin bot chat and share them privately with that reseller. A later credit grant does not reveal the password again.
4. To replace credentials, use **Reset reseller login** and enter the approved Telegram ID. The old session is revoked.
5. Use **Revoke reseller access** to disable an account and log out all sessions; remaining credits and purchase history are retained. Adding credit again re-enables the ID and generates a new password, invalidating the old one.
6. The reseller opens the bot, signs in in a private chat with `/login USERNAME PASSWORD`, and then uses `/reseller` to view plans, balance, and purchase history.

The bot tries to delete login messages and stock-upload messages after processing. Resellers should still avoid reusing these passwords elsewhere. If a user cannot receive bot messages, they must open the new bot and press Start before the administrator can deliver their key.
