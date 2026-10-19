#!/usr/bin/env python3
"""Standalone VESPER reseller bot with invite-only accounts and credit-based stock delivery."""
from __future__ import annotations

import hashlib
import json
import logging
import os
import secrets
import sqlite3
import sys
import time
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken

RESELLER_PLANS = {
    "d1": {"label": "1 DAY KEY", "display": "1 day", "credits": 99},
    "d7": {"label": "7 DAY KEY", "display": "7 days", "credits": 250},
    "d31": {"label": "31 DAY KEY", "display": "31 days", "credits": 500},
}
SESSION_TTL = 30 * 24 * 60 * 60
LOGIN_LOCK_SECONDS = 15 * 60
MAX_LOGIN_ATTEMPTS = 5
PBKDF2_ITERATIONS = 310_000
MAX_KEYS_PER_MESSAGE = 200


class BotError(RuntimeError):
    pass


def html_escape(value: str) -> str:
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def format_credits(amount: int) -> str:
    amount = int(amount)
    return f"{amount // 100}.{amount % 100:02d} credits"


def parse_credits(value: str) -> int:
    raw = str(value).strip().casefold()
    if raw.endswith("credits"):
        raw = raw[:-7].strip()
    try:
        amount = Decimal(raw)
    except InvalidOperation:
        raise ValueError("Enter a numeric credit amount, such as 10.00.") from None
    scaled = amount * 100
    if not amount.is_finite() or amount <= 0 or scaled != scaled.to_integral_value():
        raise ValueError("Credit must be positive and use no more than two decimal places.")
    cents = int(scaled)
    if cents > 9_000_000_000_000_000:
        raise ValueError("Credit amount is too large.")
    return cents


def parse_credit_grant(text: str):
    parts = str(text).strip().split()
    if len(parts) != 2 or not parts[0].isdigit():
        raise ValueError("Send exactly: TELEGRAM_ID CREDIT_AMOUNT (example: 123456789 10.00).")
    user_id = int(parts[0])
    if user_id <= 0:
        raise ValueError("Telegram ID must be positive.")
    return user_id, parse_credits(parts[1])


class VesperResellerBot:
    def __init__(self, token: str, admin_id: int, db_path: str):
        self.token = token
        self.admin_id = int(admin_id)
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.cipher = self._load_or_create_cipher()
        self.api_root = f"https://api.telegram.org/bot{token}/"
        self.pending_admin: dict[int, str] = {}
        self._initialize()

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
                        CHECK(status IN ('available','sold')),
                    created_at INTEGER NOT NULL,
                    sold_at INTEGER
                );
                CREATE TABLE IF NOT EXISTS resellers (
                    user_id INTEGER PRIMARY KEY,
                    telegram_username TEXT NOT NULL DEFAULT '',
                    login_username TEXT NOT NULL UNIQUE,
                    password_salt BLOB NOT NULL,
                    password_hash BLOB NOT NULL,
                    failed_attempts INTEGER NOT NULL DEFAULT 0,
                    locked_until INTEGER,
                    balance_credits INTEGER NOT NULL DEFAULT 0 CHECK(balance_credits >= 0),
                    active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS reseller_sessions (
                    user_id INTEGER PRIMARY KEY,
                    expires_at INTEGER NOT NULL,
                    FOREIGN KEY(user_id) REFERENCES resellers(user_id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS reseller_ledger (
                    id INTEGER PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    amount_credits INTEGER NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('admin_credit','key_purchase')),
                    source_id TEXT NOT NULL UNIQUE,
                    admin_id INTEGER,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY(user_id) REFERENCES resellers(user_id)
                );
                CREATE TABLE IF NOT EXISTS reseller_sales (
                    id TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    username TEXT NOT NULL DEFAULT '',
                    plan TEXT NOT NULL,
                    credits INTEGER NOT NULL,
                    key_id INTEGER NOT NULL,
                    status TEXT NOT NULL DEFAULT 'delivery_pending'
                        CHECK(status IN ('delivery_pending','delivered')),
                    callback_id TEXT UNIQUE,
                    created_at INTEGER NOT NULL,
                    delivered_at INTEGER,
                    admin_notified_at INTEGER,
                    FOREIGN KEY(user_id) REFERENCES resellers(user_id),
                    FOREIGN KEY(key_id) REFERENCES keys(id)
                );
                CREATE TABLE IF NOT EXISTS bot_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_reseller_stock ON keys(plan,status,id);
                CREATE INDEX IF NOT EXISTS idx_reseller_sales_pending ON reseller_sales(status,created_at);
                CREATE INDEX IF NOT EXISTS idx_reseller_ledger_user ON reseller_ledger(user_id,created_at DESC);
            """)

    def api(self, method: str, payload: dict | None = None):
        data = json.dumps(payload or {}, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            self.api_root + method,
            data=data,
            headers={"Content-Type": "application/json", "User-Agent": "VesperResellerBot/1.0"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                result = json.loads(response.read(2_000_000))
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            # Telegram API URLs contain the bot token; never log exception text.
            raise BotError(f"Telegram API request failed ({type(exc).__name__})") from None
        if not isinstance(result, dict) or not result.get("ok"):
            description = result.get("description", "request rejected") if isinstance(result, dict) else "invalid response"
            raise BotError(str(description)[:200])
        return result.get("result")

    def send(self, chat_id: int, text: str, keyboard=None):
        payload = {"chat_id": int(chat_id), "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
        if keyboard is not None:
            payload["reply_markup"] = keyboard
        return self.api("sendMessage", payload)

    @staticmethod
    def inline(rows):
        return {"inline_keyboard": rows}

    def admin_menu(self):
        return self.inline([
            [{"text": "➕ Add key stock", "callback_data": "admin_add_stock"}],
            [{"text": "📦 View stock", "callback_data": "admin_stock"}],
            [{"text": "👥 Manage resellers", "callback_data": "admin_resellers"}],
            [{"text": "📊 Reseller sales", "callback_data": "admin_sales"}],
            [{"text": "🗑️ Remove unsold key", "callback_data": "admin_remove"}],
        ])

    def reseller_menu(self):
        rows = [
            [{"text": f"🔑 {plan['display']} — {format_credits(plan['credits'])}", "callback_data": f"reseller_buy:{code}"}]
            for code, plan in RESELLER_PLANS.items()
        ]
        rows.extend([
            [{"text": "💳 My credit balance", "callback_data": "reseller_balance"}],
            [{"text": "📜 Purchase history", "callback_data": "reseller_history"}],
            [{"text": "↩️ Reseller home", "callback_data": "reseller_landing"}],
            [{"text": "🚪 Log out", "callback_data": "reseller_logout"}],
        ])
        return self.inline(rows)

    def reseller_landing_menu(self):
        return self.inline([[{"text": "🧑‍💼 Open Reseller Portal", "callback_data": "reseller_home"}]])

    def admin_reseller_menu(self):
        return self.inline([
            [{"text": "➕ Approve reseller / add credit", "callback_data": "admin_credit_reseller"}],
            [{"text": "📋 Reseller accounts", "callback_data": "admin_list_resellers"}],
            [{"text": "🔄 Reset reseller login", "callback_data": "admin_reset_reseller"}],
            [{"text": "⛔ Revoke reseller access", "callback_data": "admin_disable_reseller"}],
            [{"text": "↩️ Admin panel", "callback_data": "admin_home"}],
        ])

    def _hash_password(self, password: str, salt: bytes) -> bytes:
        return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ITERATIONS)

    @staticmethod
    def _new_credentials():
        return f"vesper_{secrets.token_hex(4)}", secrets.token_urlsafe(12)

    def is_reseller(self, user_id: int) -> bool:
        with self.db() as conn:
            row = conn.execute("SELECT active FROM resellers WHERE user_id=?", (int(user_id),)).fetchone()
        return bool(row and row["active"])

    def is_authenticated(self, user_id: int) -> bool:
        with self.db() as conn:
            row = conn.execute(
                "SELECT r.active,s.expires_at FROM resellers r JOIN reseller_sessions s ON s.user_id=r.user_id WHERE r.user_id=?",
                (int(user_id),),
            ).fetchone()
        return bool(row and row["active"] and row["expires_at"] > int(time.time()))

    def logout(self, user_id: int):
        with self.db() as conn:
            conn.execute("DELETE FROM reseller_sessions WHERE user_id=?", (int(user_id),))

    def reseller_balance(self, user_id: int):
        with self.db() as conn:
            row = conn.execute("SELECT balance_credits FROM resellers WHERE user_id=? AND active=1", (int(user_id),)).fetchone()
        return row["balance_credits"] if row else None

    def reseller_intro(self, user_id: int):
        if not self.is_authenticated(user_id):
            return self.send(user_id, "🔐 This is an invite-only reseller portal. Sign in with the credentials issued by the administrator to view reseller plans and your credit balance.")
        balance = self.reseller_balance(user_id) or 0
        text = (
            "🧑‍💼 <b>VESPER RESELLER PROGRAM</b>\n"
            "Buy license keys using credits added by the administrator to your approved Telegram account. "
            "The bot delivers each key privately after purchase. Your reseller login is linked to your approved Telegram ID.\n\n"
            f"💳 Credit balance: <b>{format_credits(balance)}</b>\n\n"
            "📋 <b>Reseller plans</b>\n"
            "1 day — 0.99 credits\n7 days — 2.50 credits\n31 days — 5.00 credits"
        )
        return self.send(user_id, text, self.reseller_menu())

    def _delete_message(self, chat_id: int, message_id: int):
        try:
            self.api("deleteMessage", {"chat_id": chat_id, "message_id": message_id})
        except BotError:
            pass

    def _add_keys(self, text: str, plan_code: str):
        if plan_code not in RESELLER_PLANS:
            raise ValueError("Unknown reseller plan.")
        candidates, seen = [], set()
        duplicate_count = 0
        for line in str(text).splitlines():
            value = line.strip()
            if not value:
                continue
            if len(value) > 512:
                raise ValueError("Each key must be 512 characters or fewer.")
            if value in seen:
                duplicate_count += 1
                continue
            seen.add(value)
            candidates.append(value)
        if not candidates:
            return 0, 0
        if len(candidates) > MAX_KEYS_PER_MESSAGE:
            raise ValueError(f"You can add at most {MAX_KEYS_PER_MESSAGE} keys per message.")
        added, now = 0, int(time.time())
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
                conn.execute(
                    "INSERT INTO keys(plan,encrypted_value,status,created_at) VALUES(?,?,'available',?)",
                    (plan_code, self.cipher.encrypt(value.encode("utf-8")), now),
                )
                known.add(value)
                added += 1
        return added, duplicate_count + len(candidates) - added

    def _stock_text(self):
        with self.db() as conn:
            rows = conn.execute("SELECT plan,status,count(*) AS total FROM keys GROUP BY plan,status").fetchall()
        counts = {(row["plan"], row["status"]): row["total"] for row in rows}
        lines = ["📦 <b>Reseller key stock</b>"]
        for code, plan in RESELLER_PLANS.items():
            available = counts.get((code, "available"), 0)
            sold = counts.get((code, "sold"), 0)
            lines.append(f"{plan['label']} — Available: <b>{available}</b> | Sold: {sold}")
        return "\n\n".join(lines)

    def _reseller_list_text(self):
        with self.db() as conn:
            rows = conn.execute(
                "SELECT user_id,telegram_username,login_username,balance_credits,active FROM resellers ORDER BY created_at DESC LIMIT 50"
            ).fetchall()
        if not rows:
            return "📋 No reseller accounts have been added yet."
        lines = ["👥 <b>Reseller accounts</b>"]
        for row in rows:
            telegram_name = f"@{html_escape(row['telegram_username'])}" if row["telegram_username"] else "no Telegram username"
            state = "active" if row["active"] else "disabled"
            lines.append(
                f"ID <code>{row['user_id']}</code> — {telegram_name}\n"
                f"Login: <code>{html_escape(row['login_username'])}</code> — {format_credits(row['balance_credits'])} — {state}"
            )
        return "\n\n".join(lines)

    def _sales_text(self):
        with self.db() as conn:
            totals = conn.execute(
                "SELECT count(*),coalesce(sum(credits),0) FROM reseller_sales WHERE status IN ('delivered','delivery_pending')"
            ).fetchone()
            rows = conn.execute(
                "SELECT s.id,s.user_id,s.plan,s.credits,s.status,s.created_at,r.telegram_username "
                "FROM reseller_sales s JOIN resellers r ON r.user_id=s.user_id ORDER BY s.created_at DESC LIMIT 20"
            ).fetchall()
        lines = [
            "📊 <b>Reseller sales</b>",
            f"Completed or pending keys: <b>{totals[0]}</b>",
            f"Credits used: <b>{format_credits(totals[1])}</b>",
        ]
        for row in rows:
            plan = RESELLER_PLANS[row["plan"]]
            buyer = f"@{html_escape(row['telegram_username'])}" if row["telegram_username"] else f"ID {row['user_id']}"
            lines.append(f"{plan['label']} — {format_credits(row['credits'])} — {buyer} — {html_escape(row['status'])}")
        return "\n".join(lines)

    def _remove_stock_keyboard(self):
        rows = []
        with self.db() as conn:
            for code, plan in RESELLER_PLANS.items():
                count = conn.execute("SELECT count(*) FROM keys WHERE plan=? AND status='available'", (code,)).fetchone()[0]
                if count:
                    rows.append([{"text": f"Remove {plan['display']} key ({count} available)", "callback_data": f"admin_remove:{code}"}])
        rows.append([{"text": "↩️ Back to admin", "callback_data": "admin_home"}])
        return self.inline(rows)

    def grant_credit(self, user_id: int, credit_amount: int, admin_id: int, source_id: str):
        if int(user_id) <= 0 or int(credit_amount) <= 0:
            raise ValueError("Telegram ID and credit amount must be positive.")
        now = int(time.time())
        credentials = None
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            if conn.execute("SELECT 1 FROM reseller_ledger WHERE source_id=?", (source_id,)).fetchone():
                row = conn.execute("SELECT balance_credits FROM resellers WHERE user_id=?", (int(user_id),)).fetchone()
                return (row["balance_credits"] if row else 0), None, True
            row = conn.execute("SELECT * FROM resellers WHERE user_id=?", (int(user_id),)).fetchone()
            if not row:
                login_username, password = self._new_credentials()
                salt = secrets.token_bytes(16)
                conn.execute(
                    "INSERT INTO resellers(user_id,login_username,password_salt,password_hash,balance_credits,active,created_at,updated_at) VALUES(?,?,?,?,0,1,?,?)",
                    (int(user_id), login_username, salt, self._hash_password(password, salt), now, now),
                )
                credentials = (login_username, password)
            elif not row["active"]:
                password = secrets.token_urlsafe(12)
                salt = secrets.token_bytes(16)
                conn.execute(
                    "UPDATE resellers SET active=1,password_salt=?,password_hash=?,failed_attempts=0,locked_until=NULL,updated_at=? WHERE user_id=?",
                    (salt, self._hash_password(password, salt), now, int(user_id)),
                )
                conn.execute("DELETE FROM reseller_sessions WHERE user_id=?", (int(user_id),))
                credentials = (row["login_username"], password)
            else:
                conn.execute("UPDATE resellers SET updated_at=? WHERE user_id=?", (now, int(user_id)))
            conn.execute(
                "UPDATE resellers SET balance_credits=balance_credits+?,updated_at=? WHERE user_id=?",
                (int(credit_amount), now, int(user_id)),
            )
            conn.execute(
                "INSERT INTO reseller_ledger(user_id,amount_credits,kind,source_id,admin_id,created_at) VALUES(?,?,'admin_credit',?,?,?)",
                (int(user_id), int(credit_amount), source_id, int(admin_id), now),
            )
            balance = conn.execute("SELECT balance_credits FROM resellers WHERE user_id=?", (int(user_id),)).fetchone()[0]
        return balance, credentials, False

    def reset_reseller_login(self, user_id: int):
        now = int(time.time())
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT login_username FROM resellers WHERE user_id=? AND active=1", (int(user_id),)).fetchone()
            if not row:
                return None
            password = secrets.token_urlsafe(12)
            salt = secrets.token_bytes(16)
            conn.execute(
                "UPDATE resellers SET password_salt=?,password_hash=?,failed_attempts=0,locked_until=NULL,updated_at=? WHERE user_id=?",
                (salt, self._hash_password(password, salt), now, int(user_id)),
            )
            conn.execute("DELETE FROM reseller_sessions WHERE user_id=?", (int(user_id),))
        return row["login_username"], password

    def disable_reseller(self, user_id: int) -> bool:
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            changed = conn.execute(
                "UPDATE resellers SET active=0,updated_at=? WHERE user_id=? AND active=1",
                (int(time.time()), int(user_id)),
            ).rowcount
            conn.execute("DELETE FROM reseller_sessions WHERE user_id=?", (int(user_id),))
        return changed == 1

    def authenticate(self, user_id: int, login_username: str, password: str, telegram_username: str = ""):
        now = int(time.time())
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM resellers WHERE user_id=? AND active=1", (int(user_id),)).fetchone()
            if not row or (row["locked_until"] and row["locked_until"] > now):
                return False
            candidate = self._hash_password(password, bytes(row["password_salt"]))
            username_ok = secrets.compare_digest(
                str(login_username).casefold().encode("utf-8"),
                str(row["login_username"]).casefold().encode("utf-8"),
            )
            password_ok = secrets.compare_digest(candidate, bytes(row["password_hash"]))
            if not username_ok or not password_ok:
                failures = row["failed_attempts"] + 1
                locked_until = now + LOGIN_LOCK_SECONDS if failures >= MAX_LOGIN_ATTEMPTS else None
                conn.execute(
                    "UPDATE resellers SET failed_attempts=?,locked_until=?,updated_at=? WHERE user_id=?",
                    (0 if locked_until else failures, locked_until, now, int(user_id)),
                )
                return False
            conn.execute(
                "UPDATE resellers SET failed_attempts=0,locked_until=NULL,telegram_username=?,updated_at=? WHERE user_id=?",
                ((telegram_username or "")[:64], now, int(user_id)),
            )
            conn.execute(
                "INSERT INTO reseller_sessions(user_id,expires_at) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET expires_at=excluded.expires_at",
                (int(user_id), now + SESSION_TTL),
            )
        return True

    def purchase_key(self, user: dict, plan_code: str, callback_id: str):
        plan = RESELLER_PLANS.get(plan_code)
        if not plan:
            return None, "invalid_plan", None
        user_id = int(user.get("id", 0))
        now = int(time.time())
        sale_id = uuid.uuid4().hex
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            duplicate = conn.execute("SELECT id,status FROM reseller_sales WHERE callback_id=?", (str(callback_id),)).fetchone()
            if duplicate:
                balance = conn.execute("SELECT balance_credits FROM resellers WHERE user_id=?", (user_id,)).fetchone()
                return duplicate["id"], "duplicate", balance[0] if balance else None
            reseller = conn.execute(
                "SELECT r.balance_credits FROM resellers r JOIN reseller_sessions s ON s.user_id=r.user_id "
                "WHERE r.user_id=? AND r.active=1 AND s.expires_at>?",
                (user_id, now),
            ).fetchone()
            if not reseller:
                return None, "login_required", None
            balance = reseller["balance_credits"]
            if balance < plan["credits"]:
                return None, "insufficient_credit", balance
            key = conn.execute("SELECT id FROM keys WHERE plan=? AND status='available' ORDER BY id LIMIT 1", (plan_code,)).fetchone()
            if not key:
                return None, "out_of_stock", balance
            changed = conn.execute(
                "UPDATE keys SET status='sold',sold_at=? WHERE id=? AND status='available'",
                (now, key["id"]),
            ).rowcount
            if changed != 1:
                return None, "out_of_stock", balance
            changed = conn.execute(
                "UPDATE resellers SET balance_credits=balance_credits-?,telegram_username=?,updated_at=? "
                "WHERE user_id=? AND active=1 AND balance_credits>=?",
                (plan["credits"], (user.get("username") or "")[:64], now, user_id, plan["credits"]),
            ).rowcount
            if changed != 1:
                raise RuntimeError("Reseller credit changed during purchase transaction.")
            conn.execute(
                "INSERT INTO reseller_sales(id,user_id,username,plan,credits,key_id,status,callback_id,created_at) "
                "VALUES(?,?,?,?,?,?,'delivery_pending',?,?)",
                (sale_id, user_id, (user.get("username") or "")[:64], plan_code, plan["credits"], key["id"], str(callback_id), now),
            )
            conn.execute(
                "INSERT INTO reseller_ledger(user_id,amount_credits,kind,source_id,created_at) VALUES(?,?,'key_purchase',?,?)",
                (user_id, -plan["credits"], f"reseller-sale:{sale_id}", now),
            )
            new_balance = balance - plan["credits"]
        return sale_id, "created", new_balance

    def _notify_reseller_sale(self, sale_id: str):
        with self.db() as conn:
            sale = conn.execute(
                "SELECT id,user_id,username,plan,credits,admin_notified_at FROM reseller_sales WHERE id=?",
                (sale_id,),
            ).fetchone()
        if not sale or sale["admin_notified_at"] is not None:
            return
        plan = RESELLER_PLANS[sale["plan"]]
        buyer = f"@{html_escape(sale['username'])}" if sale["username"] else "no Telegram username"
        text = (
            "🧑‍💼 <b>New reseller key purchase</b>\n\n"
            f"📦 Plan: <b>{plan['label']}</b>\n"
            f"💳 Credit used: <b>{format_credits(sale['credits'])}</b>\n"
            f"👤 Reseller: {buyer} (<code>{sale['user_id']}</code>)\n"
            f"🧾 Order: <code>{html_escape(sale_id)}</code>"
        )
        try:
            self.send(self.admin_id, text)
        except BotError:
            logging.warning("Could not notify administrator about reseller sale")
            return
        with self.db() as conn:
            conn.execute("UPDATE reseller_sales SET admin_notified_at=? WHERE id=? AND admin_notified_at IS NULL", (int(time.time()), sale_id))

    def _deliver_sale(self, sale_id: str):
        with self.db() as conn:
            sale = conn.execute(
                "SELECT s.user_id,s.plan,s.credits,s.key_id,s.status,k.encrypted_value "
                "FROM reseller_sales s JOIN keys k ON k.id=s.key_id WHERE s.id=?",
                (sale_id,),
            ).fetchone()
            if not sale or sale["status"] != "delivery_pending":
                return False
            reseller = conn.execute("SELECT balance_credits FROM resellers WHERE user_id=?", (sale["user_id"],)).fetchone()
            balance = reseller["balance_credits"] if reseller else 0
        try:
            key_value = self.cipher.decrypt(sale["encrypted_value"]).decode("utf-8")
        except (InvalidToken, UnicodeDecodeError):
            self.notify_admin(f"⚠️ Reseller sale <code>{html_escape(sale_id)}</code> has an unreadable key. Review it manually.")
            return False
        plan = RESELLER_PLANS[sale["plan"]]
        text = (
            "✅ <b>Reseller order complete</b>\n\n"
            f"📦 {plan['label']}\n"
            f"🔑 Your key:\n<code>{html_escape(key_value)}</code>\n\n"
            f"💳 Credit used: <b>{format_credits(sale['credits'])}</b>\n"
            f"💰 Remaining balance: <b>{format_credits(balance)}</b>\n"
            "🔒 Keep this key private."
        )
        try:
            self.send(sale["user_id"], text)
        except BotError:
            self.notify_admin(f"⚠️ Reseller order <code>{html_escape(sale_id)}</code> is awaiting key delivery; delivery will be retried.")
            return False
        with self.db() as conn:
            conn.execute("UPDATE reseller_sales SET status='delivered',delivered_at=? WHERE id=? AND status='delivery_pending'", (int(time.time()), sale_id))
        return True

    def retry_pending_deliveries(self, user_id: int | None = None):
        with self.db() as conn:
            if user_id is None:
                rows = conn.execute("SELECT id FROM reseller_sales WHERE status='delivery_pending' ORDER BY created_at LIMIT 100").fetchall()
            else:
                rows = conn.execute("SELECT id FROM reseller_sales WHERE user_id=? AND status='delivery_pending' ORDER BY created_at LIMIT 100", (int(user_id),)).fetchall()
        for row in rows:
            self._deliver_sale(row["id"])

    def retry_pending_notifications(self):
        with self.db() as conn:
            rows = conn.execute("SELECT id FROM reseller_sales WHERE admin_notified_at IS NULL ORDER BY created_at LIMIT 100").fetchall()
        for row in rows:
            self._notify_reseller_sale(row["id"])

    def reseller_history(self, user_id: int):
        with self.db() as conn:
            rows = conn.execute(
                "SELECT plan,credits,status,created_at FROM reseller_sales WHERE user_id=? ORDER BY created_at DESC LIMIT 10",
                (int(user_id),),
            ).fetchall()
        if not rows:
            return self.send(user_id, "📜 No reseller purchases yet.", self.reseller_menu())
        lines = ["📜 <b>Your latest reseller purchases</b>"]
        for row in rows:
            lines.append(f"{RESELLER_PLANS[row['plan']]['label']} — {format_credits(row['credits'])} — {html_escape(row['status'])}")
        return self.send(user_id, "\n".join(lines), self.reseller_menu())

    def notify_admin(self, text: str):
        try:
            self.send(self.admin_id, text)
            return True
        except BotError:
            logging.warning("Could not notify configured administrator")
            return False

    def handle_callback(self, callback):
        data = str(callback.get("data", ""))
        user = callback.get("from", {})
        user_id = int(user.get("id", 0))
        chat_id = int(callback.get("message", {}).get("chat", {}).get("id", user_id))
        try:
            self.api("answerCallbackQuery", {"callback_query_id": callback["id"]})
        except BotError:
            pass
        if chat_id != user_id:
            return
        if data == "admin_home":
            if user_id == self.admin_id:
                return self.send(chat_id, "🛠️ <b>VESPER Reseller Admin Panel</b>", self.admin_menu())
            return
        if data == "admin_add_stock":
            if user_id != self.admin_id:
                return
            rows = [[{"text": f"{plan['label']}", "callback_data": f"admin_stock_plan:{code}"}] for code, plan in RESELLER_PLANS.items()]
            rows.append([{"text": "↩️ Admin panel", "callback_data": "admin_home"}])
            return self.send(chat_id, "Choose which reseller key plan to add:", self.inline(rows))
        if data.startswith("admin_stock_plan:"):
            if user_id != self.admin_id:
                return
            code = data.split(":", 1)[1]
            if code not in RESELLER_PLANS:
                return
            self.pending_admin[user_id] = f"stock:{code}"
            return self.send(chat_id, f"🔑 Send <b>{RESELLER_PLANS[code]['label']}</b> keys, one per line. The upload message will be deleted after processing when possible. /cancel to stop.")
        if data == "admin_stock":
            if user_id == self.admin_id:
                return self.send(chat_id, self._stock_text(), self.admin_menu())
            return
        if data == "admin_resellers":
            if user_id == self.admin_id:
                return self.send(chat_id, "👥 <b>Reseller management</b>", self.admin_reseller_menu())
            return
        if data == "admin_credit_reseller":
            if user_id != self.admin_id:
                return
            self.pending_admin[user_id] = "credit_reseller"
            return self.send(chat_id, "Send <code>TELEGRAM_ID CREDIT_AMOUNT</code> (example: <code>123456789 10.00</code>). New accounts receive a generated login; existing accounts are topped up.")
        if data == "admin_list_resellers":
            if user_id == self.admin_id:
                return self.send(chat_id, self._reseller_list_text(), self.admin_reseller_menu())
            return
        if data == "admin_reset_reseller":
            if user_id != self.admin_id:
                return
            self.pending_admin[user_id] = "reset_reseller"
            return self.send(chat_id, "Send the approved reseller's numeric Telegram ID. Their current sessions will be logged out.")
        if data == "admin_disable_reseller":
            if user_id != self.admin_id:
                return
            self.pending_admin[user_id] = "disable_reseller"
            return self.send(chat_id, "Send the reseller's numeric Telegram ID to revoke access. Their remaining credit is preserved, but they will not be able to view prices or buy keys.")
        if data == "admin_sales":
            if user_id == self.admin_id:
                return self.send(chat_id, self._sales_text(), self.admin_menu())
            return
        if data == "admin_remove":
            if user_id == self.admin_id:
                return self.send(chat_id, "Choose a plan; the oldest unsold key will be removed.", self._remove_stock_keyboard())
            return
        if data.startswith("admin_remove:"):
            if user_id != self.admin_id:
                return
            code = data.split(":", 1)[1]
            if code not in RESELLER_PLANS:
                return
            with self.db() as conn:
                conn.execute("BEGIN IMMEDIATE")
                row = conn.execute("SELECT id FROM keys WHERE plan=? AND status='available' ORDER BY id LIMIT 1", (code,)).fetchone()
                removed = bool(row and conn.execute("DELETE FROM keys WHERE id=? AND status='available'", (row["id"],)).rowcount)
            return self.send(chat_id, "✅ One unsold key was removed." if removed else "There are no unsold keys for this plan.", self._remove_stock_keyboard())
        if data == "reseller_login_help":
            if self.is_reseller(user_id):
                return self.send(chat_id, "🔐 Sign in in this private chat with <code>/login USERNAME PASSWORD</code>. Your login is locked to this approved Telegram account.")
            return self.send(chat_id, "⛔ This Telegram account is not approved for the reseller program.")
        if data == "reseller_home":
            if not self.is_authenticated(user_id):
                return self.send(chat_id, "🔐 Your reseller session is not active. Sign in with /login USERNAME PASSWORD.")
            return self.reseller_intro(user_id)
        if data == "reseller_landing":
            if not self.is_authenticated(user_id):
                return self.send(chat_id, "🔐 Your reseller session is not active. Sign in with /login USERNAME PASSWORD.")
            return self.send(chat_id, "✅ Reseller account signed in. Tap below to open your private reseller plans and credit.", self.reseller_landing_menu())
        if data == "reseller_balance":
            if not self.is_authenticated(user_id):
                return self.send(chat_id, "🔐 Please sign in again with /login USERNAME PASSWORD.")
            return self.send(user_id, f"💳 Credit balance: <b>{format_credits(self.reseller_balance(user_id) or 0)}</b>", self.reseller_menu())
        if data == "reseller_history":
            if not self.is_authenticated(user_id):
                return self.send(chat_id, "🔐 Please sign in again with /login USERNAME PASSWORD.")
            return self.reseller_history(user_id)
        if data == "reseller_logout":
            self.logout(user_id)
            return self.send(chat_id, "🚪 You have been logged out. Reseller prices are hidden until you sign in again.")
        if data.startswith("reseller_buy:"):
            if not self.is_authenticated(user_id):
                return self.send(chat_id, "🔐 Please sign in again with /login USERNAME PASSWORD.")
            code = data.split(":", 1)[1]
            sale_id, status, balance = self.purchase_key(user, code, str(callback.get("id", "")))
            if status in ("created", "duplicate"):
                if sale_id:
                    self._notify_reseller_sale(sale_id)
                    self._deliver_sale(sale_id)
                return
            messages = {
                "invalid_plan": "⚠️ Unknown reseller plan.",
                "login_required": "🔐 Your reseller session expired. Sign in again.",
                "insufficient_credit": f"⚠️ Not enough credits. Balance: <b>{format_credits(balance or 0)}</b>.",
                "out_of_stock": "⚠️ This key plan is out of stock. No credits were deducted.",
            }
            return self.send(chat_id, messages.get(status, "⚠️ The purchase could not be completed."), self.reseller_menu())

    def _handle_admin_input(self, message, action: str):
        chat_id = int(message.get("chat", {}).get("id", 0))
        user_id = int(message.get("from", {}).get("id", 0))
        text = str(message.get("text", ""))
        self.pending_admin.pop(user_id, None)
        if action.startswith("stock:"):
            plan_code = action.split(":", 1)[1]
            try:
                added, duplicate = self._add_keys(text, plan_code)
            except ValueError as exc:
                self.pending_admin[user_id] = action
                self._delete_message(chat_id, int(message.get("message_id", 0)))
                return self.send(chat_id, f"⚠️ Stock upload rejected: {html_escape(exc)}\nSend a corrected list or /cancel.")
            self._delete_message(chat_id, int(message.get("message_id", 0)))
            return self.send(chat_id, f"✅ Added <b>{added}</b> keys. Duplicate keys skipped: {duplicate}.", self.admin_menu())
        if action == "credit_reseller":
            try:
                target_id, credits = parse_credit_grant(text)
                balance, credentials, duplicate = self.grant_credit(
                    target_id, credits, self.admin_id,
                    f"admin-credit:{self.admin_id}:{int(message.get('message_id', 0))}",
                )
            except (ValueError, sqlite3.IntegrityError) as exc:
                self.pending_admin[user_id] = action
                self._delete_message(chat_id, int(message.get("message_id", 0)))
                return self.send(chat_id, f"⚠️ Credit update rejected: {html_escape(exc)}\nSend <code>TELEGRAM_ID CREDIT_AMOUNT</code> or /cancel.")
            self._delete_message(chat_id, int(message.get("message_id", 0)))
            if duplicate:
                return self.send(chat_id, "ℹ️ This credit message was already processed; no duplicate credit was added.", self.admin_reseller_menu())
            if credentials:
                login, password = credentials
                text = (
                    "✅ <b>Reseller approved and credit added</b>\n\n"
                    f"Telegram ID: <code>{target_id}</code>\n"
                    f"Balance: <b>{format_credits(balance)}</b>\n"
                    f"Login username: <code>{html_escape(login)}</code>\n"
                    f"Generated password (shown once): <code>{html_escape(password)}</code>\n\n"
                    "Share these credentials only with this reseller. The password is shown once and stored as a salted hash."
                )
            else:
                text = f"✅ Added {format_credits(credits)} to <code>{target_id}</code>. New balance: <b>{format_credits(balance)}</b>."
            return self.send(chat_id, text, self.admin_reseller_menu())
        if action == "reset_reseller":
            try:
                target_id = int(text.strip())
                if target_id <= 0:
                    raise ValueError
            except ValueError:
                self.pending_admin[user_id] = action
                self._delete_message(chat_id, int(message.get("message_id", 0)))
                return self.send(chat_id, "⚠️ Send a positive numeric Telegram ID or /cancel.")
            credentials = self.reset_reseller_login(target_id)
            self._delete_message(chat_id, int(message.get("message_id", 0)))
            if not credentials:
                return self.send(chat_id, "⚠️ No active reseller exists for that Telegram ID.", self.admin_reseller_menu())
            login, password = credentials
            return self.send(
                chat_id,
                f"🔄 <b>Reseller login reset</b>\nTelegram ID: <code>{target_id}</code>\n"
                f"Username: <code>{html_escape(login)}</code>\nNew password: <code>{html_escape(password)}</code>\n\n"
                "Previous sessions were revoked. Share the new password privately.",
                self.admin_reseller_menu(),
            )
        if action == "disable_reseller":
            try:
                target_id = int(text.strip())
                if target_id <= 0:
                    raise ValueError
            except ValueError:
                self.pending_admin[user_id] = action
                self._delete_message(chat_id, int(message.get("message_id", 0)))
                return self.send(chat_id, "⚠️ Send a positive numeric Telegram ID or /cancel.")
            disabled = self.disable_reseller(target_id)
            self._delete_message(chat_id, int(message.get("message_id", 0)))
            result = "⛔ Reseller access revoked and sessions logged out. Remaining credit is preserved." if disabled else "⚠️ No active reseller exists for that Telegram ID."
            return self.send(chat_id, result, self.admin_reseller_menu())

    def handle_message(self, message):
        chat = message.get("chat", {})
        user = message.get("from", {})
        chat_id = int(chat.get("id", 0))
        user_id = int(user.get("id", 0))
        if chat.get("type") != "private":
            return
        text = str(message.get("text", ""))
        if user_id == self.admin_id and user_id in self.pending_admin and not text.startswith("/"):
            return self._handle_admin_input(message, self.pending_admin[user_id])
        command = text.split(maxsplit=1)[0].split("@", 1)[0].lower() if text else ""
        if command == "/cancel":
            if user_id == self.admin_id:
                self.pending_admin.pop(user_id, None)
                return self.send(chat_id, "✖️ Operation cancelled.", self.admin_menu())
            return
        if command == "/login":
            self._delete_message(chat_id, int(message.get("message_id", 0)))
            parts = text.split(maxsplit=2)
            if len(parts) != 3:
                return self.send(chat_id, "🔐 Use <code>/login USERNAME PASSWORD</code> in this private chat.")
            if self.authenticate(user_id, parts[1], parts[2], user.get("username") or ""):
                return self.send(chat_id, "✅ Reseller login successful. Your session lasts 30 days and is tied to this Telegram account. Tap below whenever you want to view your plans and credit.", self.reseller_landing_menu())
            return self.send(chat_id, "⛔ Login failed. Check your credentials and approved Telegram account; repeated failures temporarily lock login.")
        if command == "/logout":
            self.logout(user_id)
            return self.send(chat_id, "🚪 You are logged out. Reseller prices are hidden until you sign in again.")
        if command in ("/start", "/shop"):
            self.retry_pending_deliveries(user_id)
            if user_id == self.admin_id:
                return self.send(chat_id, "🛠️ <b>VESPER RESELLER BOT</b>\nManage key stock, approved reseller IDs and credit.", self.admin_menu())
            if self.is_authenticated(user_id):
                return self.send(chat_id, "🧑‍💼 <b>VESPER RESELLER ACCESS</b>\nYour account is signed in. Reseller prices and credit are hidden from this screen; tap the portal button to open them.", self.reseller_landing_menu())
            if self.is_reseller(user_id):
                return self.send(chat_id, "🔐 <b>VESPER RESELLER ACCESS</b>\nThis account is approved. Sign in with the credentials issued by the administrator: <code>/login USERNAME PASSWORD</code>.\n\nYour login is linked to your Telegram ID; reseller prices stay hidden until sign-in.")
            return self.send(chat_id, "🔒 <b>VESPER RESELLER ACCESS</b>\nThis bot is invite-only. Contact the administrator and provide your Telegram ID. Approved resellers receive login credentials privately.")
        if command == "/admin":
            if user_id != self.admin_id:
                return self.send(chat_id, "⛔ This command is for the administrator only.")
            return self.send(chat_id, "🛠️ <b>VESPER RESELLER ADMIN PANEL</b>", self.admin_menu())
        if command == "/reseller":
            if self.is_authenticated(user_id):
                return self.reseller_intro(user_id)
            return self.send(chat_id, "🔐 Sign in with /login USERNAME PASSWORD. Reseller plans are visible only after approval and login.")
        if command == "/help":
            return self.send(chat_id, "ℹ️ Reseller access is invite-only. Contact the administrator for approval. Approved users sign in with /login; use /reseller to open the portal and /logout to end the session.")

    def process_update(self, update):
        if "callback_query" in update:
            return self.handle_callback(update["callback_query"])
        if "message" in update:
            return self.handle_message(update["message"])

    def run(self):
        try:
            self.api("setMyCommands", {"commands": [
                {"command": "start", "description": "Open reseller access"},
                {"command": "login", "description": "Sign in to the approved reseller account"},
                {"command": "reseller", "description": "Open the reseller portal"},
                {"command": "logout", "description": "Log out of reseller access"},
                {"command": "help", "description": "Get help"},
                {"command": "admin", "description": "Open the administrator panel"},
            ]})
        except BotError as exc:
            logging.error("Could not initialize Telegram commands (%s)", exc)
        offset = 0
        with self.db() as conn:
            row = conn.execute("SELECT value FROM bot_state WHERE key='update_offset'").fetchone()
            if row:
                offset = int(row[0])
        logging.info("VESPER reseller bot polling started")
        self.retry_pending_notifications()
        self.retry_pending_deliveries()
        last_retry = time.monotonic()
        while True:
            try:
                if time.monotonic() - last_retry >= 60:
                    self.retry_pending_notifications()
                    self.retry_pending_deliveries()
                    last_retry = time.monotonic()
                updates = self.api("getUpdates", {"offset": offset, "timeout": 30, "allowed_updates": ["message", "callback_query"]}) or []
                for update in updates:
                    try:
                        self.process_update(update)
                    except BotError as exc:
                        logging.warning("Telegram update handling failed (%s)", exc)
                    except Exception as exc:
                        logging.exception("Unexpected reseller update error (%s)", type(exc).__name__)
                    offset = max(offset, int(update["update_id"]) + 1)
                    with self.db() as conn:
                        conn.execute("INSERT INTO bot_state(key,value) VALUES('update_offset',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(offset),))
            except BotError as exc:
                logging.warning("Telegram polling failed (%s); retrying shortly", exc)
                time.sleep(3)
            except KeyboardInterrupt:
                logging.info("VESPER reseller bot stopped")
                return


def main():
    token = os.environ.get("RESELLER_BOT_TOKEN", "")
    admin_id = os.environ.get("RESELLER_ADMIN_ID", "")
    if not token or not admin_id:
        logging.error("Set RESELLER_BOT_TOKEN and RESELLER_ADMIN_ID in the protected reseller service environment.")
        return 2
    try:
        bot = VesperResellerBot(
            token,
            int(admin_id),
            os.environ.get("RESELLER_BOT_DB", "/var/lib/vesperdash-reseller-bot/reseller.sqlite3"),
        )
    except ValueError as exc:
        logging.error("Invalid reseller bot configuration: %s", exc)
        return 2
    bot.run()
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    sys.exit(main())
