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

PLANS = {
    "h1": {"label": "1 HOUR KEY", "display": "ساعة وحدة", "stars": 30, "emoji": "⏱️"},
    "d1": {"label": "1 DAY KEY", "display": "نهار واحد", "stars": 150, "emoji": "🌙"},
    "d7": {"label": "7 DAY KEY", "display": "7 أيام", "stars": 250, "emoji": "🔥"},
    "d31": {"label": "31 DAY KEY", "display": "31 يوم", "stars": 650, "emoji": "👑"},
}
ORDER_TTL = 30 * 60
RESERVATION_TTL = 15 * 60
MAX_KEYS_PER_MESSAGE = 200


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
                    FOREIGN KEY(key_id) REFERENCES keys(id)
                );
                CREATE TABLE IF NOT EXISTS bot_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_keys_stock ON keys(plan,status,id);
                CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id,created_at DESC);
            """)

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

    def user_menu(self, user_id: int):
        rows = []
        for code, plan in PLANS.items():
            rows.append([{"text": f"{plan['emoji']} {plan['display']}  ·  {plan['stars']} ⭐", "callback_data": f"buy:{code}"}])
        rows.append([{"text": "📦 مشترياتي / My purchases", "callback_data": "my_orders"}])
        if user_id == self.admin_id:
            rows.append([{"text": "🛠 لوحة الإدارة / Admin", "callback_data": "admin"}])
        return self.inline(rows)

    def admin_menu(self):
        return self.inline([
            [{"text": "➕ زيد مفاتيح للمخزون", "callback_data": "admin_add"}],
            [{"text": "📦 المخزون المتوفر", "callback_data": "admin_stock"}],
            [{"text": "🧹 حذف مفتاح غير مباع", "callback_data": "admin_remove"}],
            [{"text": "📊 المبيعات", "callback_data": "admin_sales"}],
            [{"text": "⬅️ القائمة الرئيسية", "callback_data": "home"}],
        ])

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
        plan = PLANS.get(plan_code)
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
                return self.send(user["id"], f"حالياً سالا مخزون <b>{plan['display']}</b>. جرب من بعد أو تواصل مع الأدمن.", self.user_menu(user["id"]))
            conn.execute(
                "INSERT INTO orders(id,user_id,username,plan,stars,status,created_at) VALUES(?,?,?,?,?,'invoice_created',?)",
                (order_id, user["id"], (user.get("username") or "")[:64], plan_code, plan["stars"], now),
            )
        try:
            return self.api("sendInvoice", {
                "chat_id": user["id"],
                "title": f"{plan['label']} — VESPER",
                "description": f"مفتاح VESPER لمدة {plan['display']}. الدفع عبر Telegram Stars فقط.",
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
                return False, "الطلب غير صالح أو انتهت صلاحيته. ابدأ شراءً جديداً."
            plan = PLANS.get(order["plan"])
            if query.get("currency") != "XTR" or int(query.get("total_amount", -1)) != plan["stars"]:
                return False, "معلومات الدفع لا تطابق السعر. لم يتم قبول الطلب."
            if order["status"] == "reserved" and order["key_id"]:
                conn.execute("UPDATE orders SET reservation_expires_at=? WHERE id=?", (now + RESERVATION_TTL, order_id))
                return True, ""
            key = conn.execute("SELECT id FROM keys WHERE plan=? AND status='available' ORDER BY id LIMIT 1", (order["plan"],)).fetchone()
            if not key:
                return False, "نفد المخزون قبل إتمام الدفع. لم يتم قبول الطلب."
            changed = conn.execute("UPDATE keys SET status='reserved',reserved_order=? WHERE id=? AND status='available'", (order_id, key["id"])).rowcount
            if changed != 1:
                return False, "المفتاح لم يعد متوفراً. لم يتم قبول الطلب."
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
            plan = PLANS.get(order["plan"])
            if payment.get("currency") != "XTR" or int(payment.get("total_amount", -1)) != plan["stars"]:
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
        plan = PLANS[self._order_plan(order_id)]
        safe_key = html_escape(key_value)
        text = (
            "✅ <b>تم الدفع بنجاح!</b>\n\n"
            f"{plan['emoji']} <b>{plan['label']}</b>\n"
            f"🔑 المفتاح ديالك:\n<code>{safe_key}</code>\n\n"
            "احتافظ بالمفتاح وما تشاركوش مع حتى واحد."
        )
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
            try:
                self._deliver_paid(order_id, key_value, user_id)
            except BotError:
                self.send(user_id, "وصل الدفع ولكن تعذر إرسال المفتاح الآن. راسل الدعم أو اضغط /start لإعادة المحاولة.")
                self.notify_admin(f"⚠️ تعذر تسليم طلب مدفوع <code>{html_escape(order_id)}</code>؛ سيعاد الإرسال عند /start.")
        elif status in ("invalid_amount", "unreserved", "key_missing", "unmatched", "duplicate_charge"):
            self._refund_payment(user_id, payment, result, status)
        elif status == "duplicate":
            # The same Telegram update may be redelivered. Do not deliver twice here.
            return

    def _refund_payment(self, user_id, payment, order_id, reason):
        charge_id = str(payment.get("telegram_payment_charge_id", ""))
        if not charge_id:
            self.notify_admin(f"⚠️ دفعة غير متطابقة؛ تعذر تحديد عملية الاسترجاع. السبب: {html_escape(reason)}")
            return
        try:
            self.api("refundStarPayment", {"user_id": user_id, "telegram_payment_charge_id": charge_id})
            if isinstance(order_id, str):
                with self.db() as conn:
                    conn.execute("UPDATE orders SET status='refunded' WHERE id=? AND status!='delivered'", (order_id,))
            self.send(user_id, "⚠️ ما قدرناش نكملو الطلب، وتم إرجاع Stars تلقائياً.")
            self.notify_admin(f"⚠️ أُرجعت دفعة غير مكتملة تلقائياً. السبب: {html_escape(reason)}")
        except BotError:
            self.notify_admin(f"🚨 فشل استرجاع دفعة! السبب: {html_escape(reason)}. راجعها من Telegram بالأمر <code>/refundstar</code>.")

    def notify_admin(self, text):
        try:
            self.send(self.admin_id, text)
        except BotError:
            logging.warning("Could not notify configured administrator")

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
            return self.send(user_id, "مازال ما عندك حتى طلب. اختار المدة باش تشري مفتاح.", self.user_menu(user_id))
        lines = ["<b>📦 آخر الطلبات ديالك</b>"]
        for row in rows:
            status = {"delivered": "مسلّم ✅", "paid_delivery_pending": "مدفوع - جاري التسليم ⏳", "refunded": "مرجع ↩️", "invoice_created": "في انتظار الدفع", "reserved": "في انتظار الدفع", "expired": "منتهي"}.get(row["status"], row["status"])
            lines.append(f"• {PLANS[row['plan']]['label']} — {row['stars']} ⭐ — {status}")
        return self.send(user_id, "\n".join(lines), self.user_menu(user_id))

    def _add_keys(self, text, plan_code):
        if plan_code not in PLANS:
            raise ValueError("unknown plan")
        candidates = []
        seen = set()
        repeated_in_message = 0
        for line in text.splitlines():
            value = line.strip()
            if not value:
                continue
            if len(value) > 512:
                raise ValueError("كل مفتاح خاصو يكون أقل من 512 حرف.")
            if value in seen:
                repeated_in_message += 1
                continue
            seen.add(value)
            candidates.append(value)
        if not candidates:
            return 0, 0
        if len(candidates) > MAX_KEYS_PER_MESSAGE:
            raise ValueError(f"الحد هو {MAX_KEYS_PER_MESSAGE} مفتاح فكل رسالة.")
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
        lines = ["<b>📦 المخزون الحالي</b>"]
        for code, plan in PLANS.items():
            available = counts.get((code, "available"), 0)
            reserved = counts.get((code, "reserved"), 0)
            sold = counts.get((code, "sold"), 0)
            lines.append(f"{plan['emoji']} {plan['label']} · {plan['stars']} ⭐\nمتوفر: <b>{available}</b> | محجوز: {reserved} | مباع: {sold}")
        return "\n\n".join(lines)

    def _sales_text(self):
        with self.db() as conn:
            rows = conn.execute("SELECT status,count(*) AS n,coalesce(sum(stars),0) AS stars FROM orders GROUP BY status").fetchall()
            paid = conn.execute("SELECT count(*),coalesce(sum(stars),0) FROM orders WHERE status IN ('delivered','paid_delivery_pending')").fetchone()
        status_names = {"delivered": "تسلّم", "paid_delivery_pending": "مدفوع غير مسلّم", "refunded": "مُرجع", "invoice_created": "فواتير مفتوحة", "reserved": "دفع جاري", "expired": "منتهي", "invoice_failed": "فشل إرسال الفاتورة"}
        lines = ["<b>📊 تقرير المبيعات</b>", f"مبيعات مكتملة: <b>{paid[0]}</b>", f"إجمالي Stars المحصلة: <b>{paid[1]} ⭐</b>"]
        for row in rows:
            lines.append(f"{status_names.get(row['status'], row['status'])}: {row['n']} ({row['stars']} ⭐)")
        return "\n".join(lines)

    def _remove_stock_keyboard(self):
        rows = []
        with self.db() as conn:
            for code, plan in PLANS.items():
                row = conn.execute("SELECT count(*) FROM keys WHERE plan=? AND status='available'", (code,)).fetchone()
                if row[0]:
                    rows.append([{"text": f"حذف مفتاح {plan['display']} ({row[0]})", "callback_data": f"admin_del:{code}"}])
        rows.append([{"text": "⬅️ رجوع", "callback_data": "admin"}])
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
        try:
            self.api("answerCallbackQuery", {"callback_query_id": callback["id"]})
        except BotError:
            pass
        if data == "home":
            return self.send(chat_id, "<b>✨ VESPER KEY SHOP</b>\nاختار المدة، خلّص بـTelegram Stars، والمفتاح يوصلك مباشرة بعد الدفع.", self.user_menu(user_id))
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
            return self.send(chat_id, "<b>🛠 لوحة إدارة VESPER</b>\nالمفاتيح تُخزّن مشفّرة داخل قاعدة البيانات.", self.admin_menu())
        if user_id != self.admin_id or chat_id != user_id:
            return
        if data == "admin_add":
            rows = [[{"text": f"{plan['label']} · {plan['stars']} ⭐", "callback_data": f"admin_add_plan:{code}"}] for code, plan in PLANS.items()]
            rows.append([{"text": "إلغاء", "callback_data": "admin"}])
            return self.send(chat_id, "اختار نوع المفاتيح اللي غادي تزيد للمخزون:", self.inline(rows))
        if data.startswith("admin_add_plan:"):
            code = data.split(":", 1)[1]
            if code not in PLANS:
                return
            self.pending_admin[user_id] = code
            return self.send(chat_id, f"لسّق المفاتيح ديال <b>{PLANS[code]['label']}</b>، مفتاح واحد فكل سطر.\nغادي نحاول نمسح رسالتك من بعد ما نسجلهم. كتب /cancel للإلغاء.")
        if data == "admin_stock":
            return self.send(chat_id, self._stock_text(), self.admin_menu())
        if data == "admin_sales":
            return self.send(chat_id, self._sales_text(), self.admin_menu())
        if data == "admin_remove":
            return self.send(chat_id, "اختار الفئة. غادي يتحذف أقدم مفتاح غير مباع فقط:", self._remove_stock_keyboard())
        if data.startswith("admin_del:"):
            code = data.split(":", 1)[1]
            if code not in PLANS:
                return
            removed = self._remove_one(code)
            return self.send(chat_id, "تم حذف مفتاح واحد من المخزون." if removed else "ما كاين حتى مفتاح غير مباع فهاد الفئة.", self._remove_stock_keyboard())

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
            return self.handle_successful_payment(message)
        if text.startswith("/cancel"):
            if user_id == self.admin_id:
                self.pending_admin.pop(user_id, None)
                return self.send(chat_id, "تلغى الإجراء.", self.admin_menu())
            return
        if user_id == self.admin_id and user_id in self.pending_admin and not text.startswith("/"):
            plan_code = self.pending_admin.pop(user_id)
            try:
                added, duplicate = self._add_keys(text, plan_code)
            except ValueError as exc:
                self.pending_admin[user_id] = plan_code
                try:
                    self.api("deleteMessage", {"chat_id": chat_id, "message_id": message["message_id"]})
                except BotError:
                    pass
                return self.send(chat_id, f"ما تقبلاتش اللائحة: {html_escape(str(exc))}\nعاود برسالة أصغر أو كتب /cancel.")
            try:
                self.api("deleteMessage", {"chat_id": chat_id, "message_id": message["message_id"]})
            except BotError:
                pass
            return self.send(chat_id, f"✅ تزادو <b>{added}</b> مفاتيح للمخزون.\nتجاوزت مفاتيح مكررة: {duplicate}.", self.admin_menu())
        if text.startswith("/start") or text.startswith("/shop"):
            try:
                self.retry_pending_delivery(user_id)
            except BotError:
                pass
            return self.send(chat_id, "<b>✨ VESPER KEY SHOP</b>\nاختار المدة، خلّص بـTelegram Stars، والمفتاح يوصلك مباشرة بعد الدفع.\n\n<i>الدفع والشراء كيدوزو داخل Telegram.</i>", self.user_menu(user_id))
        if text.startswith("/admin"):
            if user_id != self.admin_id:
                return self.send(chat_id, "هاد الأمر خاص بالإدارة فقط.")
            return self.send(chat_id, "<b>🛠 لوحة إدارة VESPER</b>", self.admin_menu())
        if text.startswith("/help"):
            return self.send(chat_id, "استعمل /start باش تشوف الأسعار. من بعد الدفع الناجح، المفتاح كيوصلك هنا مباشرة. للدعم تواصل مع الإدارة.", self.user_menu(user_id))

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
                {"command": "start", "description": "فتح متجر المفاتيح"},
                {"command": "shop", "description": "عرض المدد والأسعار"},
                {"command": "help", "description": "مساعدة"},
                {"command": "admin", "description": "لوحة الإدارة"},
            ]})
        except BotError as exc:
            logging.error("Could not initialize Telegram commands (%s)", exc)
        offset = 0
        with self.db() as conn:
            row = conn.execute("SELECT value FROM bot_state WHERE key='update_offset'").fetchone()
            if row:
                offset = int(row[0])
        logging.info("Telegram Stars shop polling started")
        while True:
            try:
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
