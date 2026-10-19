import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from vesper_reseller_bot import (
    RESELLER_PLANS,
    BotError,
    VesperResellerBot,
    format_credits,
    parse_credit_grant,
    parse_credits,
)


class VesperResellerBotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bot = VesperResellerBot("test-token", 9001, str(Path(self.temp.name) / "reseller.sqlite3"))
        self.sent = []

    def fake_api(self, method, payload=None):
        if method == "sendMessage":
            self.sent.append(payload)
            return {"message_id": len(self.sent)}
        return True

    def add_stock(self, plan="d1", key="PRIVATE-RESELLER-KEY"):
        return self.bot._add_keys(key, plan)

    def create_reseller(self, credit=1000, user_id=12345):
        balance, credentials, duplicate = self.bot.grant_credit(user_id, credit, 9001, f"test-credit:{user_id}")
        self.assertFalse(duplicate)
        self.assertIsNotNone(credentials)
        return credentials, balance

    def login(self, user_id, credentials):
        username, password = credentials
        return self.bot.authenticate(user_id, username, password, "testreseller")

    def test_plan_prices_and_credit_amount_parsing(self):
        self.assertEqual({key: item["credits"] for key, item in RESELLER_PLANS.items()}, {"d1": 99, "d7": 250, "d31": 500})
        self.assertEqual(format_credits(99), "0.99 credits")
        self.assertEqual(parse_credits("2.50"), 250)
        self.assertEqual(parse_credits("10.00 credits"), 1000)
        self.assertEqual(parse_credit_grant("123456789 10.00"), (123456789, 1000))
        for invalid in ("0", "-1", "1.001", "$5", "nope"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                parse_credits(invalid)
        with self.assertRaises(ValueError):
            parse_credit_grant("not-an-id 5")

    def test_admin_credit_creates_hash_only_credentials_and_is_idempotent(self):
        balance, credentials, duplicate = self.bot.grant_credit(12345, 500, 9001, "admin-credit:9001:101")
        self.assertEqual(balance, 500)
        self.assertIsNotNone(credentials)
        self.assertFalse(duplicate)
        login, password = credentials
        self.assertTrue(login.startswith("vesper_"))
        with self.bot.db() as conn:
            row = conn.execute("SELECT login_username,password_salt,password_hash,balance_credits FROM resellers WHERE user_id=12345").fetchone()
            self.assertEqual(row["login_username"], login)
            self.assertNotEqual(bytes(row["password_hash"]), password.encode())
            self.assertEqual(row["balance_credits"], 500)
            ledger_rows = conn.execute("SELECT count(*) FROM reseller_ledger").fetchone()[0]
            self.assertEqual(ledger_rows, 1)
        balance, duplicate_credentials, duplicate = self.bot.grant_credit(12345, 500, 9001, "admin-credit:9001:101")
        self.assertEqual(balance, 500)
        self.assertIsNone(duplicate_credentials)
        self.assertTrue(duplicate)

    def test_login_is_bound_to_approved_telegram_id_and_session_expires(self):
        credentials, _ = self.create_reseller()
        self.assertFalse(self.login(99999, credentials))
        self.assertFalse(self.bot.is_authenticated(12345))
        self.assertTrue(self.login(12345, credentials))
        self.assertTrue(self.bot.is_authenticated(12345))
        with self.bot.db() as conn:
            conn.execute("UPDATE reseller_sessions SET expires_at=1 WHERE user_id=12345")
        self.assertFalse(self.bot.is_authenticated(12345))

    def test_five_bad_password_attempts_lock_account(self):
        credentials, _ = self.create_reseller()
        username, _ = credentials
        for _ in range(4):
            self.assertFalse(self.bot.authenticate(12345, username, "wrong-password"))
        with self.bot.db() as conn:
            conn.execute("UPDATE resellers SET failed_attempts=4 WHERE user_id=12345")
        self.assertFalse(self.bot.authenticate(12345, username, "wrong-password"))
        with self.bot.db() as conn:
            row = conn.execute("SELECT locked_until,failed_attempts FROM resellers WHERE user_id=12345").fetchone()
        self.assertGreater(row["locked_until"], 0)
        self.assertEqual(row["failed_attempts"], 0)
        self.assertFalse(self.login(12345, credentials))

    def test_reseller_prices_are_hidden_until_approved_account_logs_in(self):
        with patch.object(self.bot, "api", side_effect=self.fake_api):
            self.bot.handle_message({"chat": {"id": 456, "type": "private"}, "from": {"id": 456}, "text": "/start"})
        self.assertNotIn("0.99 credits", self.sent[-1]["text"])
        credentials, _ = self.create_reseller(user_id=12345)
        with patch.object(self.bot, "api", side_effect=self.fake_api):
            self.bot.handle_message({"chat": {"id": 12345, "type": "private"}, "from": {"id": 12345}, "text": "/start"})
        self.assertNotIn("0.99 credits", self.sent[-1]["text"])
        self.assertTrue(self.login(12345, credentials))
        with patch.object(self.bot, "api", side_effect=self.fake_api):
            self.bot.handle_message({"chat": {"id": 12345, "type": "private"}, "from": {"id": 12345}, "text": "/start"})
        self.assertIn("0.99 credits", self.sent[-1]["text"])
        self.assertIn("31 days — 5.00 credits", self.sent[-1]["text"])

    def test_purchase_deducts_credit_marks_stock_sold_and_delivers_key(self):
        credentials, _ = self.create_reseller(credit=1000)
        self.assertTrue(self.login(12345, credentials))
        self.add_stock(key="PRIVATE-RESELLER-KEY")
        sale_id, status, balance = self.bot.purchase_key({"id": 12345, "username": "reseller"}, "d1", "callback-one")
        self.assertEqual(status, "created")
        self.assertEqual(balance, 901)
        with patch.object(self.bot, "api", side_effect=self.fake_api):
            self.bot._notify_reseller_sale(sale_id)
            self.assertTrue(self.bot._deliver_sale(sale_id))
        admin_texts = [row["text"] for row in self.sent if row["chat_id"] == 9001]
        buyer_texts = [row["text"] for row in self.sent if row["chat_id"] == 12345]
        self.assertTrue(any("New reseller key purchase" in text for text in admin_texts))
        self.assertTrue(any("PRIVATE-RESELLER-KEY" in text for text in buyer_texts))
        self.assertTrue(all("PRIVATE-RESELLER-KEY" not in text for text in admin_texts))
        with self.bot.db() as conn:
            self.assertEqual(conn.execute("SELECT balance_credits FROM resellers WHERE user_id=12345").fetchone()[0], 901)
            self.assertEqual(conn.execute("SELECT status FROM keys").fetchone()[0], "sold")
            sale = conn.execute("SELECT status,admin_notified_at FROM reseller_sales WHERE id=?", (sale_id,)).fetchone()
            self.assertEqual(sale["status"], "delivered")
            self.assertIsNotNone(sale["admin_notified_at"])
            ledger = conn.execute("SELECT amount_credits FROM reseller_ledger ORDER BY id").fetchall()
            self.assertEqual([row[0] for row in ledger], [1000, -99])

    def test_replayed_callback_does_not_charge_or_sell_another_key(self):
        credentials, _ = self.create_reseller(credit=1000)
        self.assertTrue(self.login(12345, credentials))
        self.add_stock(key="FIRST-KEY")
        self.add_stock(key="SECOND-KEY")
        first_id, first_status, _ = self.bot.purchase_key({"id": 12345}, "d1", "callback-same")
        second_id, second_status, balance = self.bot.purchase_key({"id": 12345}, "d1", "callback-same")
        self.assertEqual(first_status, "created")
        self.assertEqual(second_status, "duplicate")
        self.assertEqual(first_id, second_id)
        self.assertEqual(balance, 901)
        with self.bot.db() as conn:
            self.assertEqual(conn.execute("SELECT count(*) FROM reseller_sales").fetchone()[0], 1)
            self.assertEqual(conn.execute("SELECT count(*) FROM keys WHERE status='sold'").fetchone()[0], 1)

    def test_insufficient_credit_and_missing_stock_never_deduct(self):
        credentials, _ = self.create_reseller(credit=98)
        self.assertTrue(self.login(12345, credentials))
        self.add_stock()
        _, status, balance = self.bot.purchase_key({"id": 12345}, "d1", "not-enough")
        self.assertEqual(status, "insufficient_credit")
        self.assertEqual(balance, 98)
        with self.bot.db() as conn:
            conn.execute("UPDATE resellers SET balance_credits=1000 WHERE user_id=12345")
        _, status, balance = self.bot.purchase_key({"id": 12345}, "d7", "no-stock")
        self.assertEqual(status, "out_of_stock")
        self.assertEqual(balance, 1000)
        with self.bot.db() as conn:
            self.assertEqual(conn.execute("SELECT status FROM keys").fetchone()[0], "available")

    def test_reset_password_revokes_existing_session(self):
        credentials, _ = self.create_reseller()
        self.assertTrue(self.login(12345, credentials))
        replacement = self.bot.reset_reseller_login(12345)
        self.assertIsNotNone(replacement)
        self.assertFalse(self.bot.is_authenticated(12345))
        self.assertFalse(self.login(12345, credentials))
        self.assertTrue(self.login(12345, replacement))

    def test_admin_can_revoke_reseller_access_without_deleting_credit_history(self):
        credentials, balance = self.create_reseller(credit=750)
        self.assertTrue(self.login(12345, credentials))
        self.assertTrue(self.bot.disable_reseller(12345))
        self.assertFalse(self.bot.is_reseller(12345))
        self.assertFalse(self.bot.is_authenticated(12345))
        self.assertFalse(self.login(12345, credentials))
        with self.bot.db() as conn:
            row = conn.execute("SELECT active,balance_credits FROM resellers WHERE user_id=12345").fetchone()
            self.assertEqual((row["active"], row["balance_credits"]), (0, balance))
            self.assertEqual(conn.execute("SELECT count(*) FROM reseller_sessions WHERE user_id=12345").fetchone()[0], 0)
        new_balance, new_credentials, duplicate = self.bot.grant_credit(12345, 100, 9001, "reactivate-credit:12345")
        self.assertFalse(duplicate)
        self.assertIsNotNone(new_credentials)
        self.assertEqual(new_balance, balance + 100)
        self.assertFalse(self.login(12345, credentials))
        self.assertTrue(self.login(12345, new_credentials))

    def test_failed_delivery_remains_pending_and_can_be_retried(self):
        credentials, _ = self.create_reseller()
        self.assertTrue(self.login(12345, credentials))
        self.add_stock(key="RETRY-ME")
        sale_id, status, _ = self.bot.purchase_key({"id": 12345}, "d1", "delivery-retry")
        self.assertEqual(status, "created")
        def flaky_api(method, payload=None):
            if method == "sendMessage" and payload["chat_id"] == 12345:
                raise BotError("temporary send failure")
            return self.fake_api(method, payload)
        with patch.object(self.bot, "api", side_effect=flaky_api):
            self.assertFalse(self.bot._deliver_sale(sale_id))
        with self.bot.db() as conn:
            self.assertEqual(conn.execute("SELECT status FROM reseller_sales WHERE id=?", (sale_id,)).fetchone()[0], "delivery_pending")
        with patch.object(self.bot, "api", side_effect=self.fake_api):
            self.assertTrue(self.bot._deliver_sale(sale_id))
        self.assertTrue(any("RETRY-ME" in row["text"] for row in self.sent))

    def test_only_admin_can_open_reseller_management(self):
        with patch.object(self.bot, "api", side_effect=self.fake_api):
            self.bot.handle_callback({
                "id": "cb-admin-denied",
                "from": {"id": 456},
                "message": {"chat": {"id": 456}},
                "data": "admin_resellers",
            })
        self.assertFalse(any("Manage resellers" in row.get("text", "") for row in self.sent))
        self.assertEqual(self.bot.pending_admin, {})


if __name__ == "__main__":
    unittest.main()
