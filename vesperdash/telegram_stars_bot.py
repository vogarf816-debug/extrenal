#!/usr/bin/env python3
"""Private Telegram Stars key shop. Standard-library polling + encrypted SQLite stock."""
from __future__ import annotations

import json
import logging
import os
import secrets
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken

from telegram_files_bot import PAYLOAD_PREFIX as FILES_PAYLOAD_PREFIX, TelegramFilesBot

PLANS = {
    "h1": {"label": "1 HOUR KEY", "display": "1 hour", "stars": 30},
    "d1": {"label": "1 DAY KEY", "display": "1 day", "stars": 150},
    "d7": {"label": "7 DAY KEY", "display": "7 days", "stars": 250},
    "d31": {"label": "31 DAY KEY", "display": "31 days", "stars": 650},
}
ORDER_TTL = 30 * 60
RESERVATION_TTL = 15 * 60
MAX_KEYS_PER_MESSAGE = 200
DEFAULT_TEXTS = {
    "welcome": "<b>Welcome to VESPER Store</b>\n\nPress Open Store to continue.",
    "home": "<b>VESPER KEY SHOP</b>\nChoose a plan and pay with Telegram Stars. Your key will be delivered here after payment.",
    "help": "ℹ️ Use /start to view plans and prices. After successful payment, your key will be sent here. Contact the administrator for support.",
    "invoice_title": "🔐 {label} — VESPER",
    "invoice_description": "🛡️ VESPER license key valid for {display}. Pay with Telegram Stars.",
    "unavailable": "⚠️ <b>{display}</b> keys are currently unavailable. Please try again later.",
    "payment_success": "✅ <b>Payment successful.</b>\n\n<b>{label}</b>\n🔑 Your key:\n<code>{key}</code>\n\n🔒 Keep this key private. Do not share it with anyone.",
    "payment_pending": "⚠️ Your payment was received, but we could not deliver the key yet. Send /start to retry.",
    "refund": "We could not complete your order, so your Stars payment has been refunded automatically.",
    "private_key": "🔒 Keep this key private. Do not share it with anyone.",
    "orders_empty": "🧾 You do not have any purchases yet. Choose a plan to get started.",
    "admin_title": "🛠️ <b>VESPER Admin Panel</b>\n🔒 License keys are encrypted in the local database.",
    "sale_notice": "💰 <b>New VESPER sale</b>\n\n📦 Plan: <b>{label}</b>\n⭐ Paid: <b>{stars} Stars</b>\n👤 Buyer: {buyer} (<code>{user_id}</code>)\n🧾 Order: <code>{order_id}</code>",
}


class BotError(RuntimeError):
    pass


class StarsKeyBot:
    def __init__(self, token: str, admin_id: int, db_path: str):
        self.token = token
        self.admin_id = int(admin_id)
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.cipher = self._load_or_create_cipher()
        self.api_root = f"https://api.telegram.org/bot{token}/"
        self.pending_admin: dict[int, str] = {}
        self._initialize()
        files_db = os.environ.get(
            "TELEGRAM_FILES_DB",
            str(self.db_path.with_name(self.db_path.stem + "-files.sqlite3")),
        )
        self.files = TelegramFilesBot(token, self.admin_id, files_db)
        self.files.send = self._send_files

    @staticmethod
    def _prefix_files_keyboard(keyboard):
        if not keyboard:
            return keyboard
        return {
            **keyboard,
            "inline_keyboard": [
                [
                    {**button, "callback_data": "file|" + str(button["callback_data"])}
                    if "callback_data" in button else button
                    for button in row
                ]
                for row in keyboard.get("inline_keyboard", [])
            ],
        }

    def _send_files(self, chat_id, text, keyboard=None):
        payload = {
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
        }
        if keyboard:
            payload["reply_markup"] = self._prefix_files_keyboard(keyboard)
        return self.files.api("sendMessage", payload)

    def _load_or_create_cipher(self):
        key_path = self.db_path.with_name(self.db_path.name + ".fernet")
        try:
            descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            key = key_path.read_bytes().strip()
        else:
            key = Fernet.generate_key()
            with os.fdopen(descriptor, "wb") as key_file:
                key_file.write(key + b"\n")
                key_file.flush()
                os.fsync(key_file.fileno())
        os.chmod(key_path, 0o600)
        return Fernet(key)

    @contextmanager
    def db(self):
        conn = sqlite3.connect(self.db_path, timeout=15, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=15000")
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        try:
            os.chmod(self.db_path, 0o600)
            for suffix in ("-wal", "-shm"):
                if Path(str(self.db_path) + suffix).exists():
                    os.chmod(str(self.db_path) + suffix, 0o600)
        except OSError:
            pass

    def _initialize(self):
        with self.db() as conn:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS keys (
                    id INTEGER PRIMARY KEY,
                    plan TEXT NOT NULL,
                    encrypted_value BLOB NOT NULL,
                    status TEXT NOT NULL DEFAULT 'available'
                        CHECK(status IN ('available','reserved','sold')),
                    reserved_order TEXT,
                    created_at INTEGER NOT NULL,
                    sold_at INTEGER
                );
                CREATE TABLE IF NOT EXISTS orders (
                    id TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    username TEXT NOT NULL DEFAULT '',
                    plan TEXT NOT NULL,
                    stars INTEGER NOT NULL,
                    status TEXT NOT NULL DEFAULT 'invoice_created',
                    key_id INTEGER,
                    created_at INTEGER NOT NULL,
                    reservation_expires_at INTEGER,
                    paid_at INTEGER,
                    delivered_at INTEGER,
                    charge_id TEXT UNIQUE,
                    admin_notified_at INTEGER,
                    FOREIGN KEY(key_id) REFERENCES keys(id)
                );
                CREATE TABLE IF NOT EXISTS bot_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS shop_plans (
                    code TEXT PRIMARY KEY,
                    label TEXT NOT NULL,
                    display TEXT NOT NULL,
                    stars INTEGER NOT NULL CHECK(stars > 0),
                    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1))
                );
                CREATE INDEX IF NOT EXISTS idx_keys_stock ON keys(plan,status,id);
                CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id,created_at DESC);
            """)
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(orders)")}
            if "admin_notified_at" not in columns:
                conn.execute("ALTER TABLE orders ADD COLUMN admin_notified_at INTEGER")
                conn.execute("UPDATE orders SET admin_notified_at=paid_at WHERE paid_at IS NOT NULL")

            for code, plan in PLANS.items():
                conn.execute(
                    "INSERT OR IGNORE INTO shop_plans(code,label,display,stars,enabled) VALUES(?,?,?,?,1)",
                    (code, plan["label"], plan["display"], plan["stars"]),
                )
            for key, value in DEFAULT_TEXTS.items():
                conn.execute("INSERT OR IGNORE INTO bot_state(key,value) VALUES(?,?)", (f"text:{key}", value))

    def plans(self, include_disabled=False):
        with self.db() as conn:
            rows = conn.execute("SELECT code,label,display,stars,enabled FROM shop_plans ORDER BY rowid").fetchall()
        result = {
            row["code"]: {
                "label": row["label"],
                "display": row["display"],
                "stars": row["stars"],
                "enabled": bool(row["enabled"]),
            }
            for row in rows
        }
        return result if include_disabled else {code: plan for code, plan in result.items() if plan["enabled"]}

    def _text(self, setting_key, **values):
        with self.db() as conn:
            row = conn.execute("SELECT value FROM bot_state WHERE key=?", (f"text:{setting_key}",)).fetchone()
        template = row["value"] if row else DEFAULT_TEXTS.get(setting_key, setting_key)
        for name, value in values.items():
            template = template.replace("{" + name + "}", str(value))
        return template

    def _set_text(self, key, value):
        if key not in DEFAULT_TEXTS:
            raise ValueError("Unknown text key")
        if not value.strip() or len(value) > 3500:
            raise ValueError("Text must be between 1 and 3500 characters.")
        with self.db() as conn:
            conn.execute(
                "INSERT INTO bot_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (f"text:{key}", value.strip()),
            )

    def _update_plan(self, code, changes):
        if code not in self.plans(include_disabled=True):
            raise ValueError("Unknown plan")
        allowed = {"label", "display", "stars", "enabled"}
        if not set(changes) <= allowed:
            raise ValueError("Allowed fields: label, display, stars, enabled")
        if "stars" in changes and (not str(changes["stars"]).isdigit() or int(changes["stars"]) <= 0):
            raise ValueError("Stars must be a positive whole number.")
        if "enabled" in changes and str(changes["enabled"]) not in {"0", "1"}:
            raise ValueError("enabled must be 0 or 1.")
        assignments = []
        values = []
        for field, value in changes.items():
            assignments.append(f"{field}=?")
            values.append(int(value) if field in {"stars", "enabled"} else str(value).strip())
        values.append(code)
        with self.db() as conn:
            conn.execute(f"UPDATE shop_plans SET {','.join(assignments)} WHERE code=?", values)

    def api(self, method: str, payload: dict | None = None):
        data = json.dumps(payload or {}, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            self.api_root + method,
            data=data,
            headers={"Content-Type": "application/json", "User-Agent": "VesperStarsShop/1.0"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                result = json.loads(response.read(2_000_000))
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            # Never log exception text: Telegram API URLs contain the bot token.
            raise BotError(f"Telegram API request failed ({type(exc).__name__})") from None
        if not isinstance(result, dict) or not result.get("ok"):
            description = result.get("description", "request rejected") if isinstance(result, dict) else "invalid response"
            raise BotError(str(description)[:200])
        return result.get("result")

    def send(self, chat_id: int, text: str, keyboard=None, **kwargs):
        payload = {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
        if keyboard is not None:
            payload["reply_markup"] = keyboard
        payload.update(kwargs)
        return self.api("sendMessage", payload)

    @staticmethod
    def inline(rows):
        return {"inline_keyboard": rows}

    def platform_menu(self):
        return self.inline([
            [{"text": "iOS", "callback_data": "platform:ios"}],
            [{"text": "Android", "callback_data": "platform:android"}],
            [{"text": "Back", "callback_data": "welcome"}],
        ])

    def welcome_menu(self):
        return self.inline([
            [{"text": "Open Store", "callback_data": "open_store"}],
        ])

    def user_menu(self, user_id: int):
        rows = [
            [{"text": "Vesper Keys", "callback_data": "ios:keys"}],
            [{"text": "Digital Files", "callback_data": "ios:files"}],
        ]
        rows.append([{"text": "My purchases", "callback_data": "my_orders"}])
        if user_id == self.admin_id:
            rows.append([{"text": "Admin panel", "callback_data": "admin"}])
        return self.inline(rows)

    def keys_menu(self, user_id: int):
        rows = []
        for code, plan in self.plans().items():
            rows.append([{"text": f"⏱️ {plan['display']} — ⭐ {plan['stars']} Stars", "callback_data": f"buy:{code}"}])
        rows.append([{"text": "Back to iOS", "callback_data": "platform:ios"}])
        return self.inline(rows)

    def admin_menu(self):
        return self.inline([
            [{"text": "Add Vesper keys", "callback_data": "admin_add"}],
            [{"text": "Add digital product", "callback_data": "files:add"}],
            [{"text": "💰 Edit prices & plans", "callback_data": "admin_plans"}],
            [{"text": "✍️ Edit bot texts", "callback_data": "admin_texts"}],
            [{"text": "📦 View stock", "callback_data": "admin_stock"}],
            [{"text": "🗑️ Remove unsold key", "callback_data": "admin_remove"}],
            [{"text": "📊 Sales report", "callback_data": "admin_sales"}],
            [{"text": "📁 Manage digital files", "callback_data": "files:admin"}],
            [{"text": "↩️ Main menu", "callback_data": "home"}],
        ])

    def admin_plans_menu(self):
        rows = []
        for code, plan in self.plans(include_disabled=True).items():
            state = "ON" if plan["enabled"] else "OFF"
            rows.append([{"text": f"{plan['display']} — {plan['stars']} Stars [{state}]", "callback_data": f"admin_plan:{code}"}])
        rows.append([{"text": "↩️ Admin panel", "callback_data": "admin"}])
        return self.inline(rows)

    def admin_texts_menu(self):
        labels = {
            "home": "Home message", "help": "Help message", "invoice_title": "Invoice title",
            "invoice_description": "Invoice description", "unavailable": "Out-of-stock message",
            "payment_success": "Payment success message", "payment_pending": "Delivery pending message",
            "refund": "Refund message", "orders_empty": "Empty orders message",
            "admin_title": "Admin panel title", "sale_notice": "Admin sale notification",
        }
        rows = [[{"text": label, "callback_data": f"admin_text:{key}"}] for key, label in labels.items()]
        rows.append([{"text": "↩️ Admin panel", "callback_data": "admin"}])
        return self.inline(rows)

    def _expire_old_orders(self, conn):
        now = int(time.time())
        conn.execute(
            "UPDATE keys SET status='available', reserved_order=NULL "
            "WHERE status='reserved' AND reserved_order IN "
            "(SELECT id FROM orders WHERE status='reserved' AND reservation_expires_at < ?)", (now,)
        )
        conn.execute(
            "UPDATE orders SET status='expired', key_id=NULL "
            "WHERE status IN ('invoice_created','reserved') AND created_at < ?", (now - ORDER_TTL,)
        )
        conn.execute(
            "UPDATE orders SET status='expired', key_id=NULL "
            "WHERE status='reserved' AND reservation_expires_at < ?", (now,)
        )

    def stock_count(self, plan: str) -> int:
        with self.db() as conn:
            self._expire_old_orders(conn)
            return conn.execute("SELECT count(*) FROM keys WHERE plan=? AND status='available'", (plan,)).fetchone()[0]

    def start_order(self, user, plan_code):
        plan = self.plans().get(plan_code)
        if not plan:
            return
        now = int(time.time())
        order_id = uuid.uuid4().hex
        payload = f"vesper:{order_id}"
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            self._expire_old_orders(conn)
            available = conn.execute("SELECT 1 FROM keys WHERE plan=? AND status='available' LIMIT 1", (plan_code,)).fetchone()
            if not available:
                return self.send(user["id"], self._text("unavailable", display=plan["display"].title()), self.user_menu(user["id"]))
            conn.execute(
                "INSERT INTO orders(id,user_id,username,plan,stars,status,created_at) VALUES(?,?,?,?,?,'invoice_created',?)",
                (order_id, user["id"], (user.get("username") or "")[:64], plan_code, plan["stars"], now),
            )
        try:
            return self.api("sendInvoice", {
                "chat_id": user["id"],
                "title": self._text("invoice_title", label=plan["label"], display=plan["display"]),
                "description": self._text("invoice_description", label=plan["label"], display=plan["display"]),
                "payload": payload,
                "provider_token": "",
                "currency": "XTR",
                "prices": [{"label": plan["label"], "amount": plan["stars"]}],
                "start_parameter": f"key-{plan_code}",
            })
        except BotError:
            with self.db() as conn:
                conn.execute("UPDATE orders SET status='invoice_failed' WHERE id=? AND status='invoice_created'", (order_id,))
            raise

    def _reserve_for_checkout(self, query):
        payload = str(query.get("invoice_payload", ""))
        order_id = payload.removeprefix("vesper:")
        user_id = int(query.get("from", {}).get("id", 0))
        now = int(time.time())
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            self._expire_old_orders(conn)
            order = conn.execute("SELECT * FROM orders WHERE id=?", (order_id,)).fetchone()
            if not order or order["user_id"] != user_id or order["status"] not in ("invoice_created", "reserved"):
                return False, "This invoice is invalid or has expired. Please start a new purchase."
            plan = self.plans(include_disabled=True).get(order["plan"])
            if query.get("currency") != "XTR" or int(query.get("total_amount", -1)) != order["stars"]:
                return False, "The payment amount does not match the price. The payment was not accepted."
            if order["status"] == "reserved" and order["key_id"]:
                conn.execute("UPDATE orders SET reservation_expires_at=? WHERE id=?", (now + RESERVATION_TTL, order_id))
                return True, ""
            key = conn.execute("SELECT id FROM keys WHERE plan=? AND status='available' ORDER BY id LIMIT 1", (order["plan"],)).fetchone()
            if not key:
                return False, "This key is out of stock. The payment was not accepted."
            changed = conn.execute("UPDATE keys SET status='reserved',reserved_order=? WHERE id=? AND status='available'", (order_id, key["id"])).rowcount
            if changed != 1:
                return False, "This key is no longer available. The payment was not accepted."
            conn.execute("UPDATE orders SET status='reserved',key_id=?,reservation_expires_at=? WHERE id=?", (key["id"], now + RESERVATION_TTL, order_id))
            return True, ""

    def handle_pre_checkout(self, query):
        ok, error = self._reserve_for_checkout(query)
        self.api("answerPreCheckoutQuery", {
            "pre_checkout_query_id": query["id"], "ok": ok,
            **({"error_message": error} if not ok else {}),
        })

    def _paid_order(self, message):
        payment = message["successful_payment"]
        payload = str(payment.get("invoice_payload", ""))
        order_id = payload.removeprefix("vesper:")
        user_id = int(message.get("from", {}).get("id", 0))
        charge_id = str(payment.get("telegram_payment_charge_id", ""))
        plan = None
        key_value = None
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            order = conn.execute("SELECT * FROM orders WHERE id=?", (order_id,)).fetchone()
            if not order or order["user_id"] != user_id:
                return None, "unmatched"
            plan = self.plans(include_disabled=True).get(order["plan"])
            if payment.get("currency") != "XTR" or int(payment.get("total_amount", -1)) != order["stars"]:
                return order_id, "invalid_amount"
            if order["status"] == "paid_delivery_pending":
                if order["charge_id"] != charge_id:
                    return order_id, "duplicate_charge"
                row = conn.execute("SELECT encrypted_value FROM keys WHERE id=? AND status='sold'", (order["key_id"],)).fetchone()
                if not row:
                    return order_id, "key_missing"
                try:
                    key_value = self.cipher.decrypt(row["encrypted_value"]).decode("utf-8")
                except (InvalidToken, UnicodeDecodeError):
                    return order_id, "key_missing"
                return (order_id, key_value), "deliver"
            if order["status"] == "delivered":
                return order_id, "duplicate" if order["charge_id"] == charge_id else "duplicate_charge"
            if order["status"] != "reserved" or not order["key_id"]:
                return order_id, "unreserved"
            try:
                row = conn.execute("SELECT encrypted_value FROM keys WHERE id=? AND status='reserved' AND reserved_order=?", (order["key_id"], order_id)).fetchone()
                if not row:
                    return order_id, "key_missing"
                try:
                    key_value = self.cipher.decrypt(row["encrypted_value"]).decode("utf-8")
                except (InvalidToken, UnicodeDecodeError):
                    return order_id, "key_missing"
                changed = conn.execute("UPDATE keys SET status='sold',sold_at=?,reserved_order=NULL WHERE id=? AND status='reserved' AND reserved_order=?", (int(time.time()), order["key_id"], order_id)).rowcount
                if changed != 1:
                    return order_id, "key_missing"
                conn.execute("UPDATE orders SET status='paid_delivery_pending',paid_at=?,charge_id=? WHERE id=?", (int(time.time()), charge_id, order_id))
            except sqlite3.IntegrityError:
                conn.rollback()
                return order_id, "duplicate_charge"
        return (order_id, key_value), "deliver"

    def _deliver_paid(self, order_id: str, key_value: str, chat_id: int):
        plan = self.plans(include_disabled=True)[self._order_plan(order_id)]
        safe_key = html_escape(key_value)
        text = self._text("payment_success", label=plan["label"], display=plan["display"], key=safe_key)
        self.send(chat_id, text)
        with self.db() as conn:
            conn.execute("UPDATE orders SET status='delivered',delivered_at=? WHERE id=? AND status='paid_delivery_pending'", (int(time.time()), order_id))

    def _order_plan(self, order_id):
        with self.db() as conn:
            row = conn.execute("SELECT plan FROM orders WHERE id=?", (order_id,)).fetchone()
        return row["plan"] if row else "d1"

    def handle_successful_payment(self, message):
        result, status = self._paid_order(message)
        user_id = int(message.get("from", {}).get("id", 0))
        payment = message["successful_payment"]
        if status == "deliver":
            order_id, key_value = result
            self._notify_sale(order_id)
            try:
                self._deliver_paid(order_id, key_value, user_id)
            except BotError:
                self.send(user_id, self._text("payment_pending"))
                self.notify_admin(f"⚠️ A paid order could not be delivered: <code>{html_escape(order_id)}</code>. It will be retried when the buyer sends /start.")
        elif status in ("invalid_amount", "unreserved", "key_missing", "unmatched", "duplicate_charge"):
            self._refund_payment(user_id, payment, result, status)
        elif status == "duplicate":
            # The same Telegram update may be redelivered. Do not deliver twice here.
            return

    def _refund_payment(self, user_id, payment, order_id, reason):
        charge_id = str(payment.get("telegram_payment_charge_id", ""))
        if not charge_id:
            self.notify_admin(f"Unmatched payment; unable to identify a refund transaction. Reason: {html_escape(reason)}")
            return
        try:
            self.api("refundStarPayment", {"user_id": user_id, "telegram_payment_charge_id": charge_id})
            if isinstance(order_id, str):
                with self.db() as conn:
                    conn.execute("UPDATE orders SET status='refunded' WHERE id=? AND status!='delivered'", (order_id,))
            self.send(user_id, self._text("refund"))
            self.notify_admin(f"An incomplete payment was refunded automatically. Reason: {html_escape(reason)}")
        except BotError:
            self.notify_admin(f"Automatic Stars refund failed. Reason: {html_escape(reason)}. Review the payment in Telegram.")

    def notify_admin(self, text):
        try:
            self.send(self.admin_id, text)
            return True
        except BotError:
            logging.warning("Could not notify configured administrator")
            return False

    def _notify_sale(self, order_id: str):
        with self.db() as conn:
            order = conn.execute(
                "SELECT user_id,username,plan,stars,admin_notified_at FROM orders WHERE id=? AND paid_at IS NOT NULL",
                (order_id,),
            ).fetchone()
        if not order or order["admin_notified_at"] is not None:
            return
        plan = self.plans(include_disabled=True).get(order["plan"])
        if not plan:
            return
        username = order["username"]
        buyer = f"@{html_escape(username)}" if username else "No username"
        text = self._text("sale_notice", label=plan["label"], stars=order["stars"], buyer=buyer, user_id=order["user_id"], order_id=html_escape(order_id))
        if self.notify_admin(text):
            with self.db() as conn:
                conn.execute(
                    "UPDATE orders SET admin_notified_at=? WHERE id=? AND admin_notified_at IS NULL",
                    (int(time.time()), order_id),
                )

    def retry_pending_admin_notifications(self):
        with self.db() as conn:
            rows = conn.execute(
                "SELECT id FROM orders WHERE paid_at IS NOT NULL AND admin_notified_at IS NULL ORDER BY paid_at LIMIT 100"
            ).fetchall()
        for row in rows:
            self._notify_sale(row["id"])

    def retry_pending_delivery(self, user_id):
        with self.db() as conn:
            rows = conn.execute("SELECT id,key_id FROM orders WHERE user_id=? AND status='paid_delivery_pending' ORDER BY paid_at", (user_id,)).fetchall()
            items = []
            for row in rows:
                key = conn.execute("SELECT encrypted_value FROM keys WHERE id=?", (row["key_id"],)).fetchone()
                if key:
                    items.append((row["id"], self.cipher.decrypt(key["encrypted_value"]).decode("utf-8")))
        for order_id, value in items:
            self._deliver_paid(order_id, value, user_id)

    def my_orders(self, user_id):
        with self.db() as conn:
            rows = conn.execute("SELECT plan,stars,status,created_at FROM orders WHERE user_id=? ORDER BY created_at DESC LIMIT 10", (user_id,)).fetchall()
        if not rows:
            return self.send(user_id, self._text("orders_empty"), self.user_menu(user_id))
        lines = ["🧾 <b>Your recent purchases</b>"]
        for row in rows:
            status = {"delivered": "Delivered", "paid_delivery_pending": "Paid — delivery pending", "refunded": "Refunded", "invoice_created": "Awaiting payment", "reserved": "Awaiting payment", "expired": "Expired"}.get(row["status"], row["status"])
            plan = self.plans(include_disabled=True).get(row["plan"], {"label": row["plan"]})
            lines.append(f"{plan['label']} — {row['stars']} Stars — {status}")
        return self.send(user_id, "\n".join(lines), self.user_menu(user_id))

    def _add_keys(self, text, plan_code):
        if plan_code not in self.plans(include_disabled=True):
            raise ValueError("unknown plan")
        candidates = []
        seen = set()
        repeated_in_message = 0
        for line in text.splitlines():
            value = line.strip()
            if not value:
                continue
            if len(value) > 512:
                raise ValueError("Each key must be 512 characters or fewer.")
            if value in seen:
                repeated_in_message += 1
                continue
            seen.add(value)
            candidates.append(value)
        if not candidates:
            return 0, 0
        if len(candidates) > MAX_KEYS_PER_MESSAGE:
            raise ValueError(f"You can add at most {MAX_KEYS_PER_MESSAGE} keys per message.")
        added = 0
        now = int(time.time())
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            known = set()
            for row in conn.execute("SELECT encrypted_value FROM keys"):
                try:
                    known.add(self.cipher.decrypt(row["encrypted_value"]).decode("utf-8"))
                except (InvalidToken, UnicodeDecodeError):
                    continue
            for value in candidates:
                if value in known:
                    continue
                conn.execute("INSERT INTO keys(plan,encrypted_value,status,created_at) VALUES(?,?,'available',?)", (plan_code, self.cipher.encrypt(value.encode()), now))
                known.add(value)
                added += 1
        return added, repeated_in_message + len(candidates) - added

    def _stock_text(self):
        with self.db() as conn:
            self._expire_old_orders(conn)
            rows = conn.execute("SELECT plan,status,count(*) AS n FROM keys GROUP BY plan,status").fetchall()
        counts = {(row["plan"], row["status"]): row["n"] for row in rows}
        lines = ["📦 <b>Current stock</b>"]
        for code, plan in self.plans(include_disabled=True).items():
            available = counts.get((code, "available"), 0)
            reserved = counts.get((code, "reserved"), 0)
            sold = counts.get((code, "sold"), 0)
            lines.append(f"{plan['label']} — {plan['stars']} Stars\nAvailable: <b>{available}</b> | Reserved: {reserved} | Sold: {sold}")
        return "\n\n".join(lines)

    def _sales_text(self):
        with self.db() as conn:
            rows = conn.execute("SELECT status,count(*) AS n,coalesce(sum(stars),0) AS stars FROM orders GROUP BY status").fetchall()
            paid = conn.execute("SELECT count(*),coalesce(sum(stars),0) FROM orders WHERE status IN ('delivered','paid_delivery_pending')").fetchone()
        status_names = {"delivered": "Delivered", "paid_delivery_pending": "Paid — delivery pending", "refunded": "Refunded", "invoice_created": "Open invoices", "reserved": "Payment in progress", "expired": "Expired", "invoice_failed": "Invoice failed"}
        lines = ["📊 <b>Sales report</b>", f"✅ Completed sales: <b>{paid[0]}</b>", f"⭐ Stars collected: <b>{paid[1]} Stars</b>"]
        for row in rows:
            lines.append(f"{status_names.get(row['status'], row['status'])}: {row['n']} ({row['stars']} Stars)")
        return "\n".join(lines)

    def _remove_stock_keyboard(self):
        rows = []
        with self.db() as conn:
            for code, plan in self.plans(include_disabled=True).items():
                row = conn.execute("SELECT count(*) FROM keys WHERE plan=? AND status='available'", (code,)).fetchone()
                if row[0]:
                    rows.append([{"text": f"Remove one {plan['display']} key ({row[0]} available)", "callback_data": f"admin_del:{code}"}])
        rows.append([{"text": "Back to admin", "callback_data": "admin"}])
        return self.inline(rows)

    def _remove_one(self, plan_code):
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT id FROM keys WHERE plan=? AND status='available' ORDER BY id LIMIT 1", (plan_code,)).fetchone()
            if not row:
                return False
            conn.execute("DELETE FROM keys WHERE id=? AND status='available'", (row["id"],))
            return True

    def handle_callback(self, callback):
        data = str(callback.get("data", ""))
        user = callback.get("from", {})
        user_id = int(user.get("id", 0))
        chat_id = callback.get("message", {}).get("chat", {}).get("id", user_id)
        if data == "files:home":
            return self.files.handle_callback({**callback, "data": "home"})
        if data == "files:admin":
            return self.files.handle_callback({**callback, "data": "admin"})
        if data.startswith("file|"):
            return self.files.handle_callback({**callback, "data": data[5:]})
        try:
            self.api("answerCallbackQuery", {"callback_query_id": callback["id"]})
        except BotError:
            pass
        if data in ("home", "welcome"):
            return self.send(chat_id, self._text("welcome"), self.welcome_menu())
        if data == "open_store":
            return self.send(chat_id, "<b>Open Store</b>\nChoose a platform:", self.platform_menu())
        if data == "platform:ios":
            return self.send(chat_id, "<b>iOS Store</b>\nChoose a category:", self.user_menu(user_id))
        if data == "platform:android":
            return self.send(chat_id, "<b>Android</b>\n\nComing soon.", self.welcome_menu())
        if data == "ios:keys":
            return self.send(chat_id, self._text("home") + "\n\n<b>Vesper Keys</b>", self.keys_menu(user_id))
        if data == "ios:files":
            return self.files.handle_callback({**callback, "data": "home"})
        if data == "files:add":
            if user_id != self.admin_id:
                return
            return self.files.handle_callback({**callback, "data": "admin_add"})
        if data == "my_orders":
            self.retry_pending_delivery(user_id)
            return self.my_orders(user_id)
        if data.startswith("buy:"):
            if chat_id != user_id:
                return
            return self.start_order(user, data.split(":", 1)[1])
        if data == "admin":
            if user_id != self.admin_id:
                return
            return self.send(chat_id, self._text("admin_title"), self.admin_menu())
        if user_id != self.admin_id or chat_id != user_id:
            return
        if data == "admin_plans":
            return self.send(chat_id, "💰 <b>Plans and prices</b>\nSelect a plan to edit. Changes apply immediately to new invoices.", self.admin_plans_menu())
        if data.startswith("admin_plan:"):
            code = data.split(":", 1)[1]
            plan = self.plans(include_disabled=True).get(code)
            if not plan:
                return
            self.pending_admin[user_id] = f"plan:{code}"
            return self.send(chat_id, f"✏️ Edit <b>{plan['label']}</b>. Send one or more lines:\n<code>stars=150</code>\n<code>display=1 day</code>\n<code>label=1 DAY KEY</code>\n<code>enabled=1</code>\nSend /cancel to stop.")
        if data == "admin_texts":
            return self.send(chat_id, "✍️ <b>Bot texts</b>\nChoose a message, then send the replacement text. Supported placeholders are shown in the current text.", self.admin_texts_menu())
        if data.startswith("admin_text:"):
            key = data.split(":", 1)[1]
            if key not in DEFAULT_TEXTS:
                return
            self.pending_admin[user_id] = f"text:{key}"
            return self.send(chat_id, f"Send the new text for <b>{key}</b>. HTML is allowed. Send /cancel to stop.\n\nCurrent:\n<code>{html_escape(self._text(key))}</code>")
        if data == "admin_add":
            rows = [[{"text": f"{plan['label']} — {plan['stars']} Stars", "callback_data": f"admin_add_plan:{code}"}] for code, plan in self.plans(include_disabled=True).items()]
            rows.append([{"text": "Cancel", "callback_data": "admin"}])
            return self.send(chat_id, "Choose the key plan to add to stock:", self.inline(rows))
        if data.startswith("admin_add_plan:"):
            code = data.split(":", 1)[1]
            plans = self.plans(include_disabled=True)
            if code not in plans:
                return
            self.pending_admin[user_id] = code
            return self.send(chat_id, f"🔑 Send <b>{plans[code]['label']}</b> keys, one per line.\nThe bot will try to delete your message after saving the keys. Send /cancel to stop.")
        if data == "admin_stock":
            return self.send(chat_id, self._stock_text(), self.admin_menu())
        if data == "admin_sales":
            return self.send(chat_id, self._sales_text(), self.admin_menu())
        if data == "admin_remove":
            return self.send(chat_id, "Choose a plan. The oldest unsold key will be removed:", self._remove_stock_keyboard())
        if data.startswith("admin_del:"):
            code = data.split(":", 1)[1]
            if code not in self.plans(include_disabled=True):
                return
            removed = self._remove_one(code)
            return self.send(chat_id, "One unsold key was removed from stock." if removed else "There are no unsold keys in this plan.", self._remove_stock_keyboard())

    def handle_message(self, message):
        chat = message.get("chat", {})
        user = message.get("from", {})
        chat_id = int(chat.get("id", 0))
        user_id = int(user.get("id", 0))
        if chat.get("type") != "private":
            return
        text = str(message.get("text", ""))
        payment = message.get("successful_payment")
        if payment:
            if str(payment.get("invoice_payload", "")).startswith(FILES_PAYLOAD_PREFIX):
                return self.files.handle_successful_payment(message)
            return self.handle_successful_payment(message)
        command = text.split(maxsplit=1)[0].split("@", 1)[0] if text.startswith("/") else ""
        if command in ("/files", "/documents"):
            return self.files.handle_message({**message, "text": "/start"})
        if command == "/filesadmin":
            return self.files.handle_message({**message, "text": "/admin"})
        if command == "/cancel" and user_id == self.admin_id and self.files.pending_admin:
            return self.files.handle_message(message)
        if user_id == self.admin_id and self.files.pending_admin and (
            message.get("document") or (text and not text.startswith("/"))
        ):
            return self.files.handle_message(message)
        if text.startswith("/cancel"):
            if user_id == self.admin_id:
                self.pending_admin.pop(user_id, None)
                return self.send(chat_id, "✖️ Operation cancelled.", self.admin_menu())
            return
        if user_id == self.admin_id and user_id in self.pending_admin and not text.startswith("/"):
            action = self.pending_admin.pop(user_id)
            if action.startswith("text:"):
                key = action.split(":", 1)[1]
                try:
                    self._set_text(key, text)
                except ValueError as exc:
                    self.pending_admin[user_id] = action
                    return self.send(chat_id, f"⚠️ {html_escape(str(exc))}\nSend a corrected text or /cancel.")
                return self.send(chat_id, "✅ Text updated. It is active immediately.", self.admin_texts_menu())
            if action.startswith("plan:"):
                code = action.split(":", 1)[1]
                try:
                    changes = {}
                    for line in text.splitlines():
                        if "=" not in line:
                            raise ValueError("Use field=value, one per line.")
                        field, value = line.split("=", 1)
                        changes[field.strip().lower()] = value.strip()
                    self._update_plan(code, changes)
                except ValueError as exc:
                    self.pending_admin[user_id] = action
                    return self.send(chat_id, f"⚠️ {html_escape(str(exc))}\nSend corrected fields or /cancel.")
                return self.send(chat_id, "✅ Plan updated. New price and text are active immediately.", self.admin_plans_menu())
            plan_code = action
            try:
                added, duplicate = self._add_keys(text, plan_code)
            except ValueError as exc:
                self.pending_admin[user_id] = plan_code
                try:
                    self.api("deleteMessage", {"chat_id": chat_id, "message_id": message["message_id"]})
                except BotError:
                    pass
                return self.send(chat_id, f"⚠️ The key list was rejected: {html_escape(str(exc))}\nSend a smaller list or use /cancel.")
            try:
                self.api("deleteMessage", {"chat_id": chat_id, "message_id": message["message_id"]})
            except BotError:
                pass
            return self.send(chat_id, f"✅ Added <b>{added}</b> keys to stock.\n↪️ Duplicate keys skipped: {duplicate}.", self.admin_menu())
        if text.startswith("/start"):
            try:
                self.retry_pending_delivery(user_id)
            except BotError:
                pass
            return self.send(chat_id, self._text("welcome"), self.welcome_menu())
        if text.startswith("/shop"):
            return self.send(chat_id, "<b>Open Store</b>\nChoose a platform:", self.platform_menu())
        if text.startswith("/admin"):
            if user_id != self.admin_id:
                return self.send(chat_id, "⛔ This command is for the administrator only.")
            return self.send(chat_id, self._text("admin_title"), self.admin_menu())
        if text.startswith("/help"):
            return self.send(chat_id, self._text("help"), self.user_menu(user_id))

    def process_update(self, update):
        if "pre_checkout_query" in update:
            query = update["pre_checkout_query"]
            if str(query.get("invoice_payload", "")).startswith(FILES_PAYLOAD_PREFIX):
                return self.files.handle_pre_checkout(query)
            return self.handle_pre_checkout(query)
        if "callback_query" in update:
            return self.handle_callback(update["callback_query"])
        if "message" in update:
            return self.handle_message(update["message"])

    def run(self):
        try:
            self.api("setMyCommands", {"commands": [
                {"command": "start", "description": "Open the key shop"},
                {"command": "shop", "description": "View plans and prices"},
                {"command": "help", "description": "Get help"},
                {"command": "admin", "description": "Open the admin panel"},
                {"command": "files", "description": "Open the digital files shop"},
                {"command": "documents", "description": "Browse digital documents"},
                {"command": "filesadmin", "description": "Open the files admin panel"},
            ]})
        except BotError as exc:
            logging.error("Could not initialize Telegram commands (%s)", exc)
        offset = 0
        with self.db() as conn:
            row = conn.execute("SELECT value FROM bot_state WHERE key='update_offset'").fetchone()
            if row:
                offset = int(row[0])
        logging.info("Telegram Stars shop polling started")
        self.retry_pending_admin_notifications()
        last_admin_retry = time.monotonic()
        while True:
            try:
                if time.monotonic() - last_admin_retry >= 60:
                    self.retry_pending_admin_notifications()
                    last_admin_retry = time.monotonic()
                updates = self.api("getUpdates", {"offset": offset, "timeout": 30, "allowed_updates": ["message", "callback_query", "pre_checkout_query"]}) or []
                for update in updates:
                    try:
                        self.process_update(update)
                    except BotError as exc:
                        logging.warning("Telegram update handling failed (%s)", exc)
                    except Exception as exc:
                        logging.exception("Unexpected error handling Telegram update (%s)", type(exc).__name__)
                    offset = max(offset, int(update["update_id"]) + 1)
                    with self.db() as conn:
                        conn.execute("INSERT INTO bot_state(key,value) VALUES('update_offset',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(offset),))
            except BotError as exc:
                logging.warning("Telegram polling failed (%s); retrying shortly", exc)
                time.sleep(3)
            except KeyboardInterrupt:
                logging.info("Telegram Stars shop stopped")
                return


def html_escape(value: str) -> str:
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    admin_id = os.environ.get("TELEGRAM_ADMIN_ID", "")
    if not token or not admin_id:
        logging.error("Set TELEGRAM_BOT_TOKEN and TELEGRAM_ADMIN_ID in the protected service environment.")
        return 2
    try:
        bot = StarsKeyBot(token, int(admin_id), os.environ.get("TELEGRAM_STARS_DB", "/opt/vesperdash/data/telegram-stars.sqlite3"))
    except ValueError as exc:
        logging.error("Invalid bot configuration: %s", exc)
        return 2
    bot.run()
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    sys.exit(main())
