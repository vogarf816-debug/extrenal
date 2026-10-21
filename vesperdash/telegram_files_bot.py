#!/usr/bin/env python3
"""Standalone Telegram Stars digital-file shop. No file downloads or key-bot dependency."""
from __future__ import annotations

import http.client
import json
import logging
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from pathlib import Path

ORDER_TTL = 30 * 60
PAGE_SIZE = 10
PAYLOAD_PREFIX = "files:"
DEFAULT_DB = "/var/lib/vesper-files-bot/files.sqlite3"


def html_escape(value):
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class BotError(RuntimeError):
    """Safe-to-log API failure; ambiguous means Telegram may already have acted."""

    def __init__(self, message, *, ambiguous=False):
        super().__init__(message)
        self.ambiguous = ambiguous


class TelegramFilesBot:
    def __init__(self, token: str, admin_id: int, db_path: str):
        self.token = token
        self.admin_id = int(admin_id)
        if self.admin_id <= 0:
            raise ValueError("Administrator ID must be positive")
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.api_root = f"https://api.telegram.org/bot{token}/"
        self.pending_admin: dict[int, dict] = {}
        self._initialize()

    @contextmanager
    def db(self):
        # Pre-create a new database privately before SQLite writes any product metadata.
        descriptor = os.open(self.db_path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(descriptor)
        os.chmod(self.db_path, 0o600)
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
            for path in (self.db_path, Path(str(self.db_path) + "-wal"), Path(str(self.db_path) + "-shm")):
                try:
                    os.chmod(path, 0o600)
                except FileNotFoundError:
                    pass

    def _initialize(self):
        with self.db() as conn:
            if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name IN ('keys','shop_plans')").fetchone():
                raise ValueError("The files bot requires a separate database, not a key-shop database")
            # Additive, transactional and repeatable; never modifies key-shop tables.
            conn.executescript("""
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS products (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL DEFAULT '',
                    stars INTEGER NOT NULL CHECK(stars > 0),
                    telegram_file_id TEXT NOT NULL,
                    original_filename TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
                    created_at INTEGER NOT NULL,
                    mime_type TEXT NOT NULL DEFAULT '',
                    file_size INTEGER CHECK(file_size IS NULL OR file_size >= 0),
                    deleted_at INTEGER
                );
                CREATE TABLE IF NOT EXISTS file_orders (
                    id TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    username TEXT NOT NULL DEFAULT '',
                    product_id INTEGER NOT NULL REFERENCES products(id),
                    product_name TEXT NOT NULL,
                    telegram_file_id TEXT NOT NULL,
                    original_filename TEXT NOT NULL,
                    mime_type TEXT NOT NULL DEFAULT '',
                    file_size INTEGER,
                    stars INTEGER NOT NULL CHECK(stars > 0),
                    status TEXT NOT NULL DEFAULT 'invoice_created'
                        CHECK(status IN ('invoice_created','checkout_approved','invoice_failed',
                            'expired','paid_delivery_pending','delivering','delivery_unknown',
                            'delivered','refund_pending','refunded')),
                    created_at INTEGER NOT NULL,
                    paid_at INTEGER,
                    delivered_at INTEGER,
                    delivery_message_id INTEGER,
                    charge_id TEXT UNIQUE,
                    admin_notified_at INTEGER
                );
                CREATE TABLE IF NOT EXISTS payment_refunds (
                    charge_id TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    order_id TEXT,
                    reason TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('refunding','refunded','refund_unknown','failed')),
                    created_at INTEGER NOT NULL,
                    refunded_at INTEGER
                );
                CREATE TABLE IF NOT EXISTS bot_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_files_products ON products(enabled,id);
                CREATE INDEX IF NOT EXISTS idx_files_orders_user ON file_orders(user_id,created_at DESC);
            """)
            # Upgrade an existing products table with just the basic required schema.
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(products)")}
            for name, definition in {
                "mime_type": "TEXT NOT NULL DEFAULT ''",
                "file_size": "INTEGER CHECK(file_size IS NULL OR file_size >= 0)",
                "deleted_at": "INTEGER",
            }.items():
                if name not in columns:
                    conn.execute(f"ALTER TABLE products ADD COLUMN {name} {definition}")
            conn.execute("INSERT OR REPLACE INTO bot_state(key,value) VALUES('files_schema_version','1')")

    def api(self, method, payload=None):
        request = urllib.request.Request(
            self.api_root + method,
            data=json.dumps(payload or {}, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "VesperFilesShop/1.0"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                result = json.loads(response.read(2_000_000))
        except urllib.error.HTTPError as exc:
            # Do not print API URLs, response descriptions, file IDs or payment data.
            raise BotError(f"Telegram HTTP request rejected ({exc.code})", ambiguous=exc.code >= 500) from None
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError, http.client.HTTPException, UnicodeDecodeError) as exc:
            raise BotError(f"Telegram request failed ({type(exc).__name__})", ambiguous=True) from None
        if not isinstance(result, dict) or result.get("ok") is not True:
            ambiguous = not isinstance(result, dict) or result.get("ok") is not False
            if isinstance(result, dict) and type(result.get("error_code")) is int and result["error_code"] >= 500:
                ambiguous = True
            raise BotError("Telegram rejected the request", ambiguous=ambiguous)
        return result.get("result")

    @staticmethod
    def inline(rows):
        return {"inline_keyboard": rows}

    def send(self, chat_id, text, keyboard=None):
        payload = {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
        if keyboard is not None:
            payload["reply_markup"] = keyboard
        return self.api("sendMessage", payload)

    def notify_admin(self, text):
        try:
            self.send(self.admin_id, text)
            return True
        except BotError:
            logging.warning("Could not notify the files-bot administrator")
            return False

    @staticmethod
    def _telegram_int(value):
        return value if type(value) is int and value > 0 else None

    @staticmethod
    def _order_id(payload):
        if not isinstance(payload, str) or not payload.startswith(PAYLOAD_PREFIX):
            return None
        order_id = payload[len(PAYLOAD_PREFIX):]
        return order_id if len(order_id) == 32 and all(char in "0123456789abcdef" for char in order_id) else None

    @staticmethod
    def _positive_stars(value):
        text = str(value).strip()
        if not text.isascii() or not text.isdigit() or len(text) > 19 or not 0 < int(text) <= 2**63 - 1:
            raise ValueError("Stars must be a positive whole number.")
        return int(text)

    def user_menu(self, user_id):
        rows = [[{"text": "📁 Browse products", "callback_data": "products:0"}],
                [{"text": "🧾 My purchases", "callback_data": "my_orders"}]]
        if user_id == self.admin_id:
            rows.append([{"text": "🛠️ Admin panel", "callback_data": "admin"}])
        return self.inline(rows)

    def admin_menu(self):
        return self.inline([
            [{"text": "➕ Add product", "callback_data": "admin_add"}],
            [{"text": "📁 Manage products", "callback_data": "admin_products:0"}],
            [{"text": "🧾 Recent orders / delivery status", "callback_data": "admin_orders"}],
            [{"text": "↩️ Main menu", "callback_data": "home"}],
        ])

    def _add_product(self, name, stars, description, document):
        name, description = name.strip(), description.strip()
        stars = self._positive_stars(stars)
        if not 1 <= len(name) <= 64:
            raise ValueError("Product name must be between 1 and 64 characters.")
        if len(description) > 255:
            raise ValueError("Description must be 255 characters or fewer.")
        file_id = document.get("file_id")
        if not isinstance(file_id, str) or not file_id.strip() or len(file_id) > 4096:
            raise ValueError("Send a Telegram document as a file, not a photo or link.")
        file_size = document.get("file_size")
        if file_size is not None and (type(file_size) is not int or not 0 <= file_size <= 2**63 - 1):
            raise ValueError("Invalid document size metadata.")
        filename = str(document.get("file_name") or "document")[:255]
        mime_type = str(document.get("mime_type") or "")[:255]
        with self.db() as conn:
            return conn.execute(
                "INSERT INTO products(name,description,stars,telegram_file_id,original_filename,mime_type,file_size,enabled,created_at) "
                "VALUES(?,?,?,?,?,?,?,1,?)",
                (name, description, stars, file_id, filename, mime_type, file_size, int(time.time())),
            ).lastrowid

    def products(self, include_disabled=False):
        with self.db() as conn:
            return conn.execute("SELECT * FROM products WHERE deleted_at IS NULL "
                                + ("" if include_disabled else "AND enabled=1 ") + "ORDER BY id").fetchall()

    def _product(self, product_id, admin=False):
        with self.db() as conn:
            return conn.execute("SELECT * FROM products WHERE id=? AND deleted_at IS NULL "
                                + ("" if admin else "AND enabled=1"), (product_id,)).fetchone()

    def _update_product(self, product_id, *, stars=None, enabled=None, hide=False):
        if stars is not None:
            stars = self._positive_stars(stars)
        if enabled is not None and (type(enabled) is not int or enabled not in (0, 1)):
            raise ValueError("enabled must be 0 or 1.")
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            if not conn.execute("SELECT 1 FROM products WHERE id=? AND deleted_at IS NULL", (product_id,)).fetchone():
                raise ValueError("This product is no longer available.")
            if hide:
                conn.execute("UPDATE products SET enabled=0,deleted_at=? WHERE id=?", (int(time.time()), product_id))
            elif stars is not None:
                conn.execute("UPDATE products SET stars=? WHERE id=?", (stars, product_id))
            elif enabled is not None:
                conn.execute("UPDATE products SET enabled=? WHERE id=?", (enabled, product_id))

    def _products_menu(self, page=0, admin=False):
        where = "deleted_at IS NULL" + ("" if admin else " AND enabled=1")
        with self.db() as conn:
            count = conn.execute(f"SELECT count(*) FROM products WHERE {where}").fetchone()[0]
            page = min(max(page, 0), max(0, (count - 1) // PAGE_SIZE))
            products = conn.execute(f"SELECT id,name,stars,enabled FROM products WHERE {where} ORDER BY id LIMIT ? OFFSET ?",
                                    (PAGE_SIZE, page * PAGE_SIZE)).fetchall()
        rows = []
        for product in products:
            state = (" [ON]" if product["enabled"] else " [OFF]") if admin else ""
            rows.append([{"text": f"{product['name']} — {product['stars']} Stars{state}",
                          "callback_data": f"{'ap' if admin else 'p'}:{product['id']}"}])
        navigation = []
        prefix = "admin_products" if admin else "products"
        if page:
            navigation.append({"text": "Previous", "callback_data": f"{prefix}:{page - 1}"})
        if (page + 1) * PAGE_SIZE < count:
            navigation.append({"text": "Next", "callback_data": f"{prefix}:{page + 1}"})
        if navigation:
            rows.append(navigation)
        rows.append([{"text": "↩️ Admin panel" if admin else "↩️ Main menu", "callback_data": "admin" if admin else "home"}])
        title = "📁 <b>Manage products</b>" if admin else "📁 <b>Digital products</b>"
        return title + (f"\nPage {page + 1}. Select a product." if count else "\nNo products available."), self.inline(rows)

    def _show_product(self, chat_id, product_id, admin=False):
        product = self._product(product_id, admin=admin)
        if not product:
            return self.send(chat_id, "This product is no longer available.")
        text = f"📁 <b>{html_escape(product['name'])}</b>\n⭐ {product['stars']} Stars"
        if product["description"]:
            text += "\n\n" + html_escape(product["description"])
        if admin:
            text += f"\n\nFile: <code>{html_escape(product['original_filename'])}</code>"
            text += f"\nMIME: {html_escape(product['mime_type']) or 'Unknown'} | Size: {product['file_size'] if product['file_size'] is not None else 'Unknown'} bytes"
            text += f"\nStatus: {'Enabled' if product['enabled'] else 'Disabled'}"
            rows = [[{"text": "Disable" if product["enabled"] else "Enable", "callback_data": f"ae:{product_id}"}],
                    [{"text": "Edit Stars price", "callback_data": f"as:{product_id}"}],
                    [{"text": "Delete / hide product", "callback_data": f"ad:{product_id}"}],
                    [{"text": "↩️ Manage products", "callback_data": "admin_products:0"}]]
        else:
            rows = [[{"text": f"Buy — ⭐ {product['stars']} Stars", "callback_data": f"buy:{product_id}"}],
                    [{"text": "↩️ Browse products", "callback_data": "products:0"}]]
        return self.send(chat_id, text, self.inline(rows))

    def _expire_orders(self, conn):
        conn.execute("UPDATE file_orders SET status='expired' WHERE status IN ('invoice_created','checkout_approved') AND created_at < ?",
                     (int(time.time()) - ORDER_TTL,))

    def start_order(self, user, product_id):
        order_id = uuid.uuid4().hex
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            self._expire_orders(conn)
            product = conn.execute("SELECT * FROM products WHERE id=? AND enabled=1 AND deleted_at IS NULL", (product_id,)).fetchone()
            if product:
                # Immutable invoice and delivery snapshot survives product edits or soft deletion.
                conn.execute("INSERT INTO file_orders(id,user_id,username,product_id,product_name,telegram_file_id,original_filename,mime_type,file_size,stars,created_at) "
                             "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                             (order_id, user["id"], (user.get("username") or "")[:64], product_id, product["name"],
                              product["telegram_file_id"], product["original_filename"], product["mime_type"], product["file_size"],
                              product["stars"], int(time.time())))
        if not product:
            return self.send(user["id"], "This product is no longer available.")
        try:
            return self.api("sendInvoice", {
                "chat_id": user["id"], "title": product["name"],
                "description": product["description"] or "Digital document delivered here after successful payment.",
                "payload": PAYLOAD_PREFIX + order_id, "provider_token": "", "currency": "XTR",
                "prices": [{"label": product["name"], "amount": product["stars"]}],
                "start_parameter": f"p-{product_id}",
            })
        except BotError:
            with self.db() as conn:
                conn.execute("UPDATE file_orders SET status='invoice_failed' WHERE id=? AND status='invoice_created'", (order_id,))
            raise

    def _approve_checkout(self, query):
        order_id = self._order_id(query.get("invoice_payload"))
        user_id = self._telegram_int(query.get("from", {}).get("id"))
        if not order_id or user_id is None:
            return False, "This invoice is invalid. Please start a new purchase."
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            self._expire_orders(conn)
            order = conn.execute("SELECT * FROM file_orders WHERE id=?", (order_id,)).fetchone()
            if not order or order["user_id"] != user_id or order["status"] not in ("invoice_created", "checkout_approved"):
                return False, "This invoice is invalid or has expired. Please start a new purchase."
            if query.get("currency") != "XTR" or self._telegram_int(query.get("total_amount")) != order["stars"]:
                return False, "The payment amount does not match the price. The payment was not accepted."
            if not conn.execute("SELECT 1 FROM products WHERE id=? AND enabled=1 AND deleted_at IS NULL", (order["product_id"],)).fetchone():
                return False, "This product is no longer available. The payment was not accepted."
            conn.execute("UPDATE file_orders SET status='checkout_approved' WHERE id=?", (order_id,))
            return True, ""

    def handle_pre_checkout(self, query):
        ok, error = self._approve_checkout(query)
        return self.api("answerPreCheckoutQuery", {"pre_checkout_query_id": query["id"], "ok": ok,
                                                   **({"error_message": error} if not ok else {})})

    def _paid_order(self, message):
        payment = message["successful_payment"]
        order_id = self._order_id(payment.get("invoice_payload"))
        user_id = self._telegram_int(message.get("from", {}).get("id"))
        charge_id = payment.get("telegram_payment_charge_id")
        if user_id is None or not isinstance(charge_id, str) or not charge_id or len(charge_id) > 512:
            return None, "unmatched"
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            existing = conn.execute("SELECT id,user_id FROM file_orders WHERE charge_id=?", (charge_id,)).fetchone()
            if existing and (existing["id"] != order_id or existing["user_id"] != user_id):
                return None, "charge_reused"
            refund = conn.execute("SELECT * FROM payment_refunds WHERE charge_id=?", (charge_id,)).fetchone()
            if refund:
                if refund["order_id"] != order_id or refund["user_id"] != user_id:
                    return None, "charge_reused"
                return order_id, "refund" if refund["status"] == "failed" else "duplicate"
            order = conn.execute("SELECT * FROM file_orders WHERE id=?", (order_id,)).fetchone()
            if not order or order["user_id"] != user_id:
                return None, "unmatched"
            if payment.get("currency") != "XTR" or self._telegram_int(payment.get("total_amount")) != order["stars"]:
                return order_id, "invalid_amount"
            if order["charge_id"]:
                if order["charge_id"] != charge_id:
                    return order_id, "extra_charge"
                if order["status"] == "paid_delivery_pending":
                    return order_id, "deliver"
                return order_id, "duplicate"
            if order["status"] != "checkout_approved":
                return order_id, "unapproved"
            conn.execute("UPDATE file_orders SET status='paid_delivery_pending',charge_id=?,paid_at=? WHERE id=?",
                         (charge_id, int(time.time()), order_id))
            return order_id, "deliver"

    def _deliver(self, order_id, user_id):
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            order = conn.execute("SELECT * FROM file_orders WHERE id=? AND user_id=?", (order_id, user_id)).fetchone()
            if not order or order["status"] != "paid_delivery_pending":
                return
            # Claim before the API call. Re-entrant/concurrent updates and crash replay cannot send again.
            conn.execute("UPDATE file_orders SET status='delivering' WHERE id=?", (order_id,))
        try:
            result = self.api("sendDocument", {"chat_id": user_id, "document": order["telegram_file_id"],
                                               "caption": f"✅ Payment successful.\n{order['product_name']}"})
            if not isinstance(result, dict) or self._telegram_int(result.get("message_id")) is None:
                raise BotError("Document delivery could not be confirmed", ambiguous=True)
        except BotError as exc:
            # A timeout may happen AFTER Telegram delivered. Only definite failures are auto-retryable.
            status = "delivery_unknown" if exc.ambiguous else "paid_delivery_pending"
            with self.db() as conn:
                conn.execute("UPDATE file_orders SET status=? WHERE id=? AND status='delivering'", (status, order_id))
            raise
        with self.db() as conn:
            conn.execute("UPDATE file_orders SET status='delivered',delivered_at=?,delivery_message_id=? WHERE id=? AND status='delivering'",
                         (int(time.time()), result["message_id"], order_id))

    def _notify_sale(self, order_id):
        with self.db() as conn:
            order = conn.execute("SELECT * FROM file_orders WHERE id=? AND paid_at IS NOT NULL", (order_id,)).fetchone()
        if not order or order["admin_notified_at"] is not None:
            return
        buyer = f"@{html_escape(order['username'])}" if order["username"] else "No username"
        if self.notify_admin(f"💰 <b>New digital product sale</b>\n📁 {html_escape(order['product_name'])}\n"
                             f"⭐ {order['stars']} Stars\n👤 {buyer} (<code>{order['user_id']}</code>)\n🧾 <code>{order_id}</code>"):
            with self.db() as conn:
                conn.execute("UPDATE file_orders SET admin_notified_at=? WHERE id=? AND admin_notified_at IS NULL", (int(time.time()), order_id))

    def handle_successful_payment(self, message):
        order_id, status = self._paid_order(message)
        user_id = self._telegram_int(message.get("from", {}).get("id"))
        if status == "deliver":
            self._notify_sale(order_id)
            try:
                self._deliver(order_id, user_id)
            except BotError as exc:
                pending = "Delivery needs administrator review. Contact support." if exc.ambiguous else "Send /start to retry delivery."
                self.notify_admin(f"⚠️ Order <code>{order_id}</code> needs delivery attention. {pending}")
                self.send(user_id, "Your payment was received. " + pending)
        elif status == "charge_reused":
            self.notify_admin("⚠️ A reused payment charge was rejected. No additional delivery or refund was attempted.")
        elif status != "duplicate":
            self._refund_payment(user_id, message["successful_payment"], order_id, status)

    def _refund_payment(self, user_id, payment, order_id, reason):
        charge_id = payment.get("telegram_payment_charge_id")
        if user_id is None or not isinstance(charge_id, str) or not charge_id or len(charge_id) > 512 or payment.get("currency") != "XTR":
            self.notify_admin("⚠️ An invalid payment needs manual review; no identifiable Stars refund was attempted.")
            return
        with self.db() as conn:
            conn.execute("BEGIN IMMEDIATE")
            paid = conn.execute("SELECT id,user_id,paid_at,status FROM file_orders WHERE charge_id=?", (charge_id,)).fetchone()
            if paid and (paid["id"] != order_id or paid["user_id"] != user_id or paid["paid_at"] is not None or paid["status"] == "refunded"):
                return  # Never refund another order's charge or the original charge of a paid order.
            receipt = conn.execute("SELECT * FROM payment_refunds WHERE charge_id=?", (charge_id,)).fetchone()
            if receipt:
                if receipt["user_id"] != user_id or receipt["order_id"] != order_id or receipt["status"] != "failed":
                    return
                conn.execute("UPDATE payment_refunds SET status='refunding' WHERE charge_id=?", (charge_id,))
            else:
                conn.execute("INSERT INTO payment_refunds(charge_id,user_id,order_id,reason,status,created_at) VALUES(?,?,?,?,'refunding',?)",
                             (charge_id, user_id, order_id, reason, int(time.time())))
            # Keep the original paid status intact when refunding a second charge for the same invoice.
            conn.execute("UPDATE file_orders SET charge_id=?,status='refund_pending' WHERE id=? AND user_id=? AND paid_at IS NULL AND (charge_id IS NULL OR charge_id=?)",
                         (charge_id, order_id, user_id, charge_id))
        try:
            result = self.api("refundStarPayment", {"user_id": user_id, "telegram_payment_charge_id": charge_id})
            if result is not True:
                raise BotError("Stars refund could not be confirmed", ambiguous=True)
        except BotError as exc:
            with self.db() as conn:
                conn.execute("UPDATE payment_refunds SET status=? WHERE charge_id=?", ("refund_unknown" if exc.ambiguous else "failed", charge_id))
            self.notify_admin("⚠️ Automatic Stars refund could not be confirmed. Review the payment in Telegram.")
            return
        with self.db() as conn:
            conn.execute("UPDATE payment_refunds SET status='refunded',refunded_at=? WHERE charge_id=?", (int(time.time()), charge_id))
            conn.execute("UPDATE file_orders SET status='refunded' WHERE id=? AND charge_id=? AND status='refund_pending'", (order_id, charge_id))
        self.notify_admin(f"An incomplete digital payment was refunded. Reason: {html_escape(reason)}")
        self.send(user_id, "The incomplete payment has been refunded automatically.")

    def retry_pending_admin_notifications(self):
        with self.db() as conn:
            orders = conn.execute("SELECT id FROM file_orders WHERE paid_at IS NOT NULL AND admin_notified_at IS NULL ORDER BY paid_at LIMIT 100").fetchall()
        for order in orders:
            self._notify_sale(order["id"])

    def retry_pending_delivery(self, user_id):
        with self.db() as conn:
            orders = conn.execute("SELECT id FROM file_orders WHERE user_id=? AND status='paid_delivery_pending' ORDER BY paid_at", (user_id,)).fetchall()
        for order in orders:
            self._deliver(order["id"], user_id)

    def my_orders(self, user_id, admin=False):
        with self.db() as conn:
            orders = conn.execute("SELECT id,user_id,product_name,stars,status FROM file_orders "
                                  + ("" if admin else "WHERE user_id=? ") + "ORDER BY created_at DESC LIMIT 10",
                                  () if admin else (user_id,)).fetchall()
        lines = ["🧾 <b>Recent orders</b>"]
        for order in orders:
            lines.append(f"{html_escape(order['product_name'])} — {order['stars']} Stars — {html_escape(order['status'])}")
            if admin:
                lines.append(f"Buyer: <code>{order['user_id']}</code> | Order: <code>{order['id']}</code>")
        if not orders:
            lines.append("No purchases yet.")
        return self.send(user_id, "\n".join(lines), self.admin_menu() if admin else self.user_menu(user_id))

    def _admin_text(self, message):
        user_id = message["from"]["id"]
        state = self.pending_admin[user_id]
        text = message.get("text", "").strip()
        try:
            if state["stage"] == "edit_price":
                self._update_product(state["product_id"], stars=text)
                self.pending_admin.pop(user_id, None)
                return self._show_product(user_id, state["product_id"], admin=True)
            if state["stage"] == "name":
                if not 1 <= len(text) <= 64:
                    raise ValueError("Product name must be between 1 and 64 characters.")
                state.update(name=text, stage="stars")
                return self.send(user_id, "Send the price as a positive whole number of Stars. Send /cancel to stop.")
            if state["stage"] == "stars":
                state.update(stars=self._positive_stars(text), stage="description")
                return self.send(user_id, "Send a description (up to 255 characters), or /skip for none. Send /cancel to stop.")
            if state["stage"] == "description":
                if len(text) > 255:
                    raise ValueError("Description must be 255 characters or fewer.")
                state.update(description="" if text == "/skip" else text, stage="document")
                return self.send(user_id, "Now send the Telegram document as a file, not a photo or link. Only its file_id and metadata are stored; no download. Send /cancel to stop.")
            return self.send(user_id, "Please send a Telegram document as a file, or /cancel.")
        except ValueError as exc:
            return self.send(user_id, f"⚠️ {html_escape(exc)}\nSend a corrected value or /cancel.")

    def handle_document(self, message):
        user_id = message.get("from", {}).get("id")
        chat = message.get("chat", {})
        if user_id != self.admin_id or chat.get("type") != "private" or chat.get("id") != user_id:
            return
        state = self.pending_admin.get(user_id)
        if not state:
            return
        if state["stage"] != "document":
            return self.send(user_id, "This step expects text, not a document. Send the requested text or /cancel.")
        try:
            product_id = self._add_product(state["name"], state["stars"], state["description"], message.get("document", {}))
        except ValueError as exc:
            return self.send(user_id, f"⚠️ {html_escape(exc)}\nSend a document or /cancel.")
        self.pending_admin.pop(user_id, None)
        self.send(user_id, "✅ Product added and enabled. No file was downloaded to the server.")
        return self._show_product(user_id, product_id, admin=True)

    def handle_callback(self, callback):
        user = callback.get("from", {})
        user_id = self._telegram_int(user.get("id"))
        chat = callback.get("message", {}).get("chat", {})
        try:
            self.api("answerCallbackQuery", {"callback_query_id": callback["id"]})
        except BotError:
            pass
        if user_id is None or chat.get("type") != "private" or chat.get("id") != user_id:
            return
        data = callback.get("data", "")
        if not isinstance(data, str) or len(data.encode("utf-8")) > 64:
            return
        number = None
        if data.startswith(("products:", "p:", "buy:", "admin_products:", "ap:", "ae:", "as:", "ad:", "ac:")):
            suffix = data.split(":", 1)[1]
            if not suffix.isascii() or not suffix.isdigit() or len(suffix) > 19 or int(suffix) > 2**63 - 1:
                return
            number = int(suffix)
        if data == "home":
            self.pending_admin.pop(user_id, None)
            return self.send(user_id, "📁 <b>Digital Files Shop</b>\nBrowse products and pay securely with Telegram Stars.", self.user_menu(user_id))
        if data == "my_orders":
            try:
                self.retry_pending_delivery(user_id)
            except BotError:
                pass
            return self.my_orders(user_id)
        if data.startswith("products:"):
            return self.send(user_id, *self._products_menu(number))
        if data.startswith("p:"):
            return self._show_product(user_id, number)
        if data.startswith("buy:"):
            return self.start_order(user, number)
        if user_id != self.admin_id:
            return
        if data == "admin":
            self.pending_admin.pop(user_id, None)
            return self.send(user_id, "🛠️ <b>Digital Files Admin Panel</b>", self.admin_menu())
        if data == "admin_add":
            self.pending_admin[user_id] = {"stage": "name"}
            return self.send(user_id, "Send the product name (1–64 characters). Send /cancel to stop.")
        if data.startswith("admin_products:"):
            self.pending_admin.pop(user_id, None)
            return self.send(user_id, *self._products_menu(number, admin=True))
        if data == "admin_orders":
            return self.my_orders(user_id, admin=True)
        if data.startswith(("ap:", "ae:", "as:", "ad:", "ac:")):
            product = self._product(number, admin=True)
            if not product:
                return self.send(user_id, "This product is no longer available.")
            self.pending_admin.pop(user_id, None)
            if data.startswith("ae:"):
                self._update_product(number, enabled=1 - product["enabled"])
            elif data.startswith("ad:"):
                return self.send(user_id, "Hide this product permanently? Existing paid orders will keep their file.",
                                 self.inline([[{"text": "Confirm hide", "callback_data": f"ac:{number}"}],
                                              [{"text": "Cancel", "callback_data": f"ap:{number}"}]]))
            elif data.startswith("ac:"):
                self._update_product(number, hide=True)
                text, keyboard = self._products_menu(admin=True)
                return self.send(user_id, "✅ Product hidden.\n\n" + text, keyboard)
            elif data.startswith("as:"):
                self.pending_admin[user_id] = {"stage": "edit_price", "product_id": number}
                return self.send(user_id, "Send the new positive whole-number price in Stars. Existing invoices keep their original price. Send /cancel to stop.")
            return self._show_product(user_id, number, admin=True)

    def handle_message(self, message):
        user = message.get("from", {})
        user_id = self._telegram_int(user.get("id"))
        chat = message.get("chat", {})
        if user_id is None or chat.get("type") != "private" or chat.get("id") != user_id:
            return
        if message.get("successful_payment"):
            return self.handle_successful_payment(message)
        text = str(message.get("text", ""))
        command = text.split(maxsplit=1)[0].split("@", 1)[0] if text.startswith("/") else ""
        if command == "/cancel":
            if user_id == self.admin_id:
                self.pending_admin.pop(user_id, None)
                return self.send(user_id, "Operation cancelled.", self.admin_menu())
            return
        if "document" in message:
            return self.handle_document(message)
        state = self.pending_admin.get(user_id) if user_id == self.admin_id else None
        if state and (not command or (command == "/skip" and state["stage"] == "description")):
            if command == "/skip":
                message = {**message, "text": "/skip"}
            return self._admin_text(message)
        if command in ("/start", "/shop"):
            self.pending_admin.pop(user_id, None)
            try:
                self.retry_pending_delivery(user_id)
            except BotError:
                pass
            return self.send(user_id, "📁 <b>Digital Files Shop</b>\nBrowse products and pay securely with Telegram Stars.", self.user_menu(user_id))
        if command == "/admin":
            if user_id != self.admin_id:
                return self.send(user_id, "This command is for the administrator only.")
            self.pending_admin.pop(user_id, None)
            return self.send(user_id, "🛠️ <b>Digital Files Admin Panel</b>", self.admin_menu())
        if command in ("/help", "/paysupport"):
            return self.send(user_id, "Use /start to browse products. Documents are delivered here after successful Stars payment. For payment or delivery support, contact the shop administrator.", self.user_menu(user_id))
        if state and command == "/skip":
            return self.send(user_id, "/skip is only available at the description step. Send the requested value or /cancel.")

    def process_update(self, update):
        if "pre_checkout_query" in update:
            return self.handle_pre_checkout(update["pre_checkout_query"])
        if "callback_query" in update:
            return self.handle_callback(update["callback_query"])
        if "message" in update:
            return self.handle_message(update["message"])

    def run(self):
        try:
            self.api("setMyCommands", {"commands": [
                {"command": "start", "description": "Open the Digital Files shop"},
                {"command": "shop", "description": "Browse digital products"},
                {"command": "help", "description": "Get help"},
                {"command": "paysupport", "description": "Payment and delivery support"},
                {"command": "admin", "description": "Open the admin panel"},
            ]})
        except BotError as exc:
            logging.warning("Could not initialize files-bot commands (%s)", type(exc).__name__)
        with self.db() as conn:
            row = conn.execute("SELECT value FROM bot_state WHERE key='update_offset'").fetchone()
        offset = int(row["value"]) if row else 0
        logging.info("Telegram Digital Files shop polling started")
        self.retry_pending_admin_notifications()
        last_admin_retry = time.monotonic()
        while True:
            try:
                if time.monotonic() - last_admin_retry >= 60:
                    self.retry_pending_admin_notifications()
                    last_admin_retry = time.monotonic()
                updates = self.api("getUpdates", {"offset": offset, "timeout": 30,
                                                   "allowed_updates": ["message", "callback_query", "pre_checkout_query"]}) or []
                for update in updates:
                    try:
                        self.process_update(update)
                    except Exception as exc:
                        # Never log exception messages, tracebacks or raw Telegram updates.
                        logging.warning("Files-bot update handling failed (%s)", type(exc).__name__)
                    offset = max(offset, int(update["update_id"]) + 1)
                    with self.db() as conn:
                        conn.execute("INSERT INTO bot_state(key,value) VALUES('update_offset',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(offset),))
            except BotError as exc:
                logging.warning("Files-bot polling failed (%s); retrying", type(exc).__name__)
                time.sleep(3)
            except KeyboardInterrupt:
                logging.info("Telegram Digital Files shop stopped")
                return


def main():
    token = os.environ.get("TELEGRAM_FILES_BOT_TOKEN", "")
    admin_id = os.environ.get("TELEGRAM_FILES_ADMIN_ID", "")
    if not token or not admin_id:
        logging.error("Set TELEGRAM_FILES_BOT_TOKEN and TELEGRAM_FILES_ADMIN_ID in the protected service environment.")
        return 2
    try:
        bot = TelegramFilesBot(token, int(admin_id), os.environ.get("TELEGRAM_FILES_DB", DEFAULT_DB))
    except (ValueError, OSError, sqlite3.Error) as exc:
        logging.error("Invalid files-bot configuration (%s)", type(exc).__name__)
        return 2
    bot.run()
    return 0


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    sys.exit(main())
