import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from telegram_stars_bot import PLANS, StarsKeyBot


class TelegramStarsBotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="vesper-stars-test-")
        self.addCleanup(self.tmp.cleanup)
        self.bot = StarsKeyBot("123456:fake-token-for-tests", 9001, str(Path(self.tmp.name) / "shop.sqlite3"))
        self.user = {"id": 12001, "username": "buyer"}

    def fake_api(self, method, payload=None):
        if method == "sendMessage":
            return {"message_id": 1}
        if method == "sendInvoice":
            return {"invoice": True, **(payload or {})}
        if method == "answerPreCheckoutQuery":
            return True
        if method == "refundStarPayment":
            return True
        if method == "deleteMessage":
            return True
        if method == "answerCallbackQuery":
            return True
        return []

    def add_stock(self, plan="d1", values=("KEY-ONE",)):
        return self.bot._add_keys("\n".join(values), plan)

    def create_invoice(self, plan="d1"):
        with patch.object(self.bot, "api", side_effect=self.fake_api) as api:
            self.bot.start_order(self.user, plan)
        request = next(call.args[1] for call in api.call_args_list if call.args[0] == "sendInvoice")
        return request["payload"]

    def reserve(self, payload, stars=150, user_id=12001):
        query = {
            "id": "checkout-1", "invoice_payload": payload,
            "from": {"id": user_id}, "currency": "XTR", "total_amount": stars,
        }
        return self.bot._reserve_for_checkout(query)

    def test_prices_and_star_invoice_are_as_requested(self):
        self.assertEqual([PLANS[k]["stars"] for k in ("h1", "d1", "d7", "d31")], [30, 150, 250, 650])
        self.add_stock()
        with patch.object(self.bot, "api", side_effect=self.fake_api) as api:
            self.bot.start_order(self.user, "d1")
        invoice = next(call.args[1] for call in api.call_args_list if call.args[0] == "sendInvoice")
        self.assertEqual(invoice["currency"], "XTR")
        self.assertEqual(invoice["provider_token"], "")
        self.assertEqual(invoice["prices"], [{"label": "1 DAY KEY", "amount": 150}])

    def test_stock_is_encrypted_and_duplicate_keys_are_not_added(self):
        self.assertEqual(self.add_stock(values=("PRIVATE-KEY-123", "PRIVATE-KEY-123", "SECOND-KEY")), (2, 1))
        raw_db = Path(self.tmp.name, "shop.sqlite3").read_bytes()
        self.assertNotIn(b"PRIVATE-KEY-123", raw_db)
        self.assertEqual(self.bot.stock_count("d1"), 2)

    def test_internal_encryption_key_is_created_and_reused_automatically(self):
        db_path = Path(self.tmp.name, "auto-shop.sqlite3")
        bot = StarsKeyBot("123456:fake-token-for-tests", 9001, str(db_path))
        key_path = Path(str(db_path) + ".fernet")
        self.assertTrue(key_path.is_file())
        self.assertEqual(key_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(bot._add_keys("AUTO-STORED-KEY", "d1"), (1, 0))
        restarted = StarsKeyBot("123456:fake-token-for-tests", 9001, str(db_path))
        self.assertEqual(restarted._add_keys("AUTO-STORED-KEY", "d1"), (0, 1))

    def test_key_is_reserved_only_after_valid_precheckout_and_delivered_after_payment(self):
        self.add_stock(values=("PRIVATE-KEY-123",))
        payload = self.create_invoice()
        self.assertEqual(self.reserve(payload), (True, ""))
        with self.bot.db() as conn:
            state = conn.execute("SELECT status FROM keys").fetchone()["status"]
            self.assertEqual(state, "reserved")
        message = {
            "from": self.user,
            "successful_payment": {
                "invoice_payload": payload, "currency": "XTR", "total_amount": 150,
                "telegram_payment_charge_id": "charge-abc",
            },
        }
        with patch.object(self.bot, "api", side_effect=self.fake_api) as api:
            self.bot.handle_successful_payment(message)
        delivered = [call.args[1]["text"] for call in api.call_args_list if call.args[0] == "sendMessage"]
        self.assertTrue(any("PRIVATE-KEY-123" in text for text in delivered))
        with self.bot.db() as conn:
            self.assertEqual(conn.execute("SELECT status FROM keys").fetchone()["status"], "sold")
            self.assertEqual(conn.execute("SELECT status FROM orders").fetchone()["status"], "delivered")
        with patch.object(self.bot, "api", side_effect=self.fake_api) as api:
            self.bot.handle_successful_payment(message)
        self.assertFalse(any(call.args[0] == "sendMessage" for call in api.call_args_list))

    def test_precheckout_rejects_wrong_user_or_wrong_amount_without_reserving(self):
        self.add_stock()
        payload = self.create_invoice()
        self.assertFalse(self.reserve(payload, stars=30)[0])
        self.assertFalse(self.reserve(payload, user_id=22222)[0])
        with self.bot.db() as conn:
            self.assertEqual(conn.execute("SELECT status FROM keys").fetchone()["status"], "available")

    def test_out_of_stock_does_not_create_invoice(self):
        with patch.object(self.bot, "api", side_effect=self.fake_api) as api:
            self.bot.start_order(self.user, "d7")
        self.assertFalse(any(call.args[0] == "sendInvoice" for call in api.call_args_list))

    def test_only_admin_gets_admin_controls(self):
        self.assertIn("admin", str(self.bot.user_menu(9001)))
        self.assertNotIn("admin", str(self.bot.user_menu(12001)))

    def test_expired_reservation_returns_key_to_stock(self):
        self.add_stock()
        payload = self.create_invoice()
        self.assertTrue(self.reserve(payload)[0])
        with self.bot.db() as conn:
            conn.execute("UPDATE orders SET reservation_expires_at=1")
            self.bot._expire_old_orders(conn)
        with self.bot.db() as conn:
            self.assertEqual(conn.execute("SELECT status FROM keys").fetchone()["status"], "available")
            self.assertEqual(conn.execute("SELECT status FROM orders").fetchone()["status"], "expired")


if __name__ == "__main__":
    unittest.main()
