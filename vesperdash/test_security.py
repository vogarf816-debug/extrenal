"""Security regression tests for VesperDash client sessions and patch access."""

import hashlib
import hmac
import io
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.error
import uuid
import unittest
from pathlib import Path
from unittest.mock import patch

TEST_ROOT = Path(tempfile.mkdtemp(prefix="vesperdash-security-test-"))
os.environ["VESPERDASH_DATA"] = str(TEST_ROOT / "data")
os.environ["VESPERDASH_PACKAGE_PASSWORDS"] = json.dumps([
    "test-package-password-00000001",
    "test-package-password-00000002",
])
os.environ["M3SB_PACKAGE_TOKEN"] = "test-server-only-package-token"
os.environ["M3SB_HMAC_SECRET"] = "test-server-only-hmac-secret"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import server  # noqa: E402

server.app.config.update(TESTING=True)


def signed_license(key, device_id, valid=True, status=None):
    timestamp = int(time.time())
    payload = {
        "valid": valid,
        "status": status or ("active" if valid else "invalid"),
        "license": key,
        "device_hash": hashlib.sha256(device_id.encode()).hexdigest(),
        "expires_at": timestamp + 3600,
        "devices_left": 1,
        "allow_inject": valid,
        "ts": timestamp,
    }
    fields = (
        "valid", "status", "license", "device_hash", "expires_at",
        "devices_left", "allow_inject", "ts",
    )
    canonical = "&".join(f"{field}={server._signature_value(payload.get(field))}" for field in fields)
    payload["sig_v2"] = hmac.new(
        server.M3SB_HMAC_SECRET.encode(), canonical.encode(), hashlib.sha256
    ).hexdigest()
    payload["telegram_username"] = "@VesperSupport"
    payload["message"] = "active"
    return payload


class ClientSessionSecurityTests(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(TEST_ROOT / "data", ignore_errors=True)
        server._DB_INITIALIZED.clear()
        secret_patcher = patch.object(server, "M3SB_HMAC_SECRET", "test-server-only-hmac-secret")
        secret_patcher.start()
        self.addCleanup(secret_patcher.stop)
        self.client = server.app.test_client()
        self.key = "TEST-LICENSE-KEY-1234"
        self.device_id = "00000000-0000-4000-8000-000000000001"

    def _activate(self, key=None, device_id=None, valid=True):
        key = key or self.key
        device_id = device_id or self.device_id
        result = signed_license(key, device_id, valid=valid)
        with patch.object(server, "_verify_license_with_m3sb", return_value=result):
            return self.client.post("/api/client/session", json={"key": key, "device_id": device_id})

    def test_db_uses_wal_and_busy_timeout(self):
        conn = server.db()
        self.assertEqual(conn.execute("PRAGMA busy_timeout").fetchone()[0], 8000)
        self.assertEqual(conn.execute("PRAGMA journal_mode").fetchone()[0].lower(), "wal")
        conn.close()

    def test_signed_provider_proof_exchanges_for_download_session(self):
        provider_result = signed_license(self.key, self.device_id)
        with patch.object(server.urllib.request, "urlopen", side_effect=AssertionError("must not contact M3SB")):
            response = self.client.post(
                "/api/client/session/bridge",
                json={"key": self.key, "device_id": self.device_id, "provider_result": provider_result},
            )
        self.assertEqual(response.status_code, 200)
        self.assertIn("no-store", response.headers.get("Cache-Control", ""))
        token = response.get_json()["client_session"]
        manifest = self.client.get("/api/patches", headers={"Authorization": f"Bearer {token}"})
        self.assertEqual(manifest.status_code, 200)

    def test_bridge_migrates_legacy_client_sessions_table_in_place(self):
        legacy_db = TEST_ROOT / "legacy-client-sessions.sqlite3"
        legacy_device = "legacy-device-0001"
        legacy_token_hash = "legacy-token-hash"
        legacy_license_hash = hashlib.sha256(b"legacy-license").hexdigest()
        conn = server.sqlite3.connect(legacy_db)
        conn.execute(
            "CREATE TABLE client_sessions(token_hash TEXT PRIMARY KEY, license_hash TEXT NOT NULL, device_id TEXT NOT NULL, expires_at INTEGER NOT NULL)"
        )
        conn.execute(
            "INSERT INTO client_sessions(token_hash,license_hash,device_id,expires_at) VALUES(?,?,?,?)",
            (legacy_token_hash, legacy_license_hash, legacy_device, int(time.time()) + 3600),
        )
        conn.commit()
        conn.close()

        provider_result = signed_license(self.key, self.device_id)
        with patch.object(server, "DB", legacy_db):
            response = self.client.post(
                "/api/client/session/bridge",
                json={"key": self.key, "device_id": self.device_id, "provider_result": provider_result},
            )
            self.assertEqual(response.status_code, 200)
            token = response.get_json()["client_session"]
            manifest = self.client.get("/api/patches", headers={"Authorization": f"Bearer {token}"})
            self.assertEqual(manifest.status_code, 200)

        conn = server.sqlite3.connect(legacy_db)
        columns = {row[1] for row in conn.execute("PRAGMA table_info(client_sessions)")}
        row = conn.execute(
            "SELECT device_hash FROM client_sessions WHERE token_hash=?", (legacy_token_hash,)
        ).fetchone()
        conn.close()
        self.assertIn("device_hash", columns)
        self.assertEqual(row[0], hashlib.sha256(legacy_device.encode()).hexdigest())

    def test_bridge_rejects_tampered_or_wrong_device_provider_proof(self):
        tampered = signed_license(self.key, self.device_id)
        tampered["status"] = "banned"
        response = self.client.post(
            "/api/client/session/bridge",
            json={"key": self.key, "device_id": self.device_id, "provider_result": tampered},
        )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.get_json()["status"], "signature_mismatch")
        self.assertNotIn("client_session", response.get_json())

        other_device = signed_license(self.key, "another-device")
        response = self.client.post(
            "/api/client/session/bridge",
            json={"key": self.key, "device_id": self.device_id, "provider_result": other_device},
        )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.get_json()["status"], "device_identity_mismatch")
        self.assertNotIn("client_session", response.get_json())

        banned = signed_license(self.key, self.device_id, status="banned")
        response = self.client.post(
            "/api/client/session/bridge",
            json={"key": self.key, "device_id": self.device_id, "provider_result": banned},
        )
        self.assertEqual(response.status_code, 403)
        self.assertNotIn("client_session", response.get_json())

    def test_bridge_reports_hmac_secret_mismatch_without_exposing_proof(self):
        provider_result = signed_license(self.key, self.device_id)
        with patch.object(server, "M3SB_HMAC_SECRET", "different-test-secret"):
            response = self.client.post(
                "/api/client/session/bridge",
                json={"key": self.key, "device_id": self.device_id, "provider_result": provider_result},
            )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.get_json()["status"], "signature_mismatch")
        self.assertIn("HMAC secret", response.get_json()["message"])
        self.assertNotIn("sig_v2", response.get_json())

    def test_bridge_is_disabled_without_server_hmac_secret(self):
        provider_result = signed_license(self.key, self.device_id)
        with patch.object(server, "M3SB_HMAC_SECRET", ""):
            response = self.client.post(
                "/api/client/session/bridge",
                json={"key": self.key, "device_id": self.device_id, "provider_result": provider_result},
            )
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("client_session", response.get_json())

    def test_public_manifest_is_rejected(self):
        response = self.client.get("/api/patches")
        self.assertEqual(response.status_code, 401)
        self.assertNotIn(b"test-package-password", response.data)

    def test_valid_license_receives_session_and_package_passwords_only_after_auth(self):
        response = self._activate()
        self.assertEqual(response.status_code, 200)
        payload = response.get_json()
        self.assertTrue(payload["valid"])
        self.assertTrue(payload["client_session"])
        self.assertNotIn("token", payload)
        headers = {"Authorization": f"Bearer {payload['client_session']}"}
        manifest_response = self.client.get("/api/patches", headers=headers)
        self.assertEqual(manifest_response.status_code, 200)
        self.assertEqual(
            manifest_response.get_json()["package_passwords"],
            ["test-package-password-00000001", "test-package-password-00000002"],
        )
        self.assertIn("no-store", manifest_response.headers.get("Cache-Control", ""))

    def test_invalid_license_cannot_create_client_session(self):
        response = self._activate(valid=False)
        self.assertEqual(response.status_code, 403)
        self.assertFalse(response.get_json()["valid"])
        self.assertNotIn("client_session", response.get_json())

    def test_provider_http_403_invalid_license_is_returned_as_license_rejection(self):
        provider_body = json.dumps({"valid": False, "status": "invalid", "message": "license is invalid"}).encode()
        provider_error = urllib.error.HTTPError(
            "https://license.invalid/api/sdk/verify", 403, "Forbidden", {}, io.BytesIO(provider_body)
        )
        with patch.object(server, "M3SB_PACKAGE_TOKEN", "test-server-only-package-token"), patch.object(
            server, "M3SB_HMAC_SECRET", "test-server-only-hmac-secret"
        ), patch.object(server.urllib.request, "urlopen", side_effect=provider_error):
            response = self.client.post(
                "/api/client/session", json={"key": self.key, "device_id": self.device_id}
            )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.get_json()["status"], "invalid")
        self.assertEqual(response.get_json()["message"], "license is invalid")

    def test_provider_http_403_authorization_error_is_not_reported_as_outage(self):
        provider_body = json.dumps({"status": "forbidden", "message": "request rejected"}).encode()
        provider_error = urllib.error.HTTPError(
            "https://license.invalid/api/sdk/verify", 403, "Forbidden", {}, io.BytesIO(provider_body)
        )
        with patch.object(server, "M3SB_PACKAGE_TOKEN", "test-server-only-package-token"), patch.object(
            server, "M3SB_HMAC_SECRET", "test-server-only-hmac-secret"
        ), patch.object(server.urllib.request, "urlopen", side_effect=provider_error):
            response = self.client.post(
                "/api/client/session", json={"key": self.key, "device_id": self.device_id}
            )
        self.assertEqual(response.status_code, 502)
        self.assertEqual(response.get_json()["status"], "provider_rejected")
        self.assertIn("HTTP 403", response.get_json()["message"])

    def test_provider_nonce_matches_legacy_uppercase_uuid_hex(self):
        captured = {}

        def fake_urlopen(req, timeout):
            captured["nonce"] = next(
                value for name, value in req.header_items() if name.lower() == "x-m3sb-nonce"
            )
            return io.BytesIO(b'{"valid":false,"status":"invalid"}')

        with patch.object(server, "M3SB_PACKAGE_TOKEN", "test-server-only-package-token"), patch.object(
            server, "M3SB_HMAC_SECRET", "test-server-only-hmac-secret"
        ), patch.object(server.urllib.request, "urlopen", side_effect=fake_urlopen):
            result = server._verify_license_with_m3sb(self.key, self.device_id, {})
        self.assertFalse(result["valid"])
        self.assertRegex(captured["nonce"], r"^[0-9A-F]{32}$")
        self.assertEqual(uuid.UUID(captured["nonce"]).version, 4)

    def test_mismatched_signed_license_identity_is_rejected(self):
        result = signed_license(self.key, "another-device")
        with patch.object(server, "_verify_license_with_m3sb", return_value=result):
            response = self.client.post(
                "/api/client/session", json={"key": self.key, "device_id": self.device_id}
            )
        self.assertEqual(response.status_code, 502)
        self.assertNotIn("client_session", response.get_json())

    def test_download_requires_a_client_session(self):
        response = self.client.get("/api/patches/nonexistent/download")
        self.assertEqual(response.status_code, 401)

    def test_expired_session_is_rejected_and_deleted(self):
        response = self._activate()
        token = response.get_json()["client_session"]
        digest = hashlib.sha256(token.encode()).hexdigest()
        conn = server.db()
        conn.execute("UPDATE client_sessions SET expires_at=? WHERE token_hash=?", (int(time.time()) - 1, digest))
        conn.commit()
        conn.close()
        protected = self.client.get("/api/patches", headers={"Authorization": f"Bearer {token}"})
        self.assertEqual(protected.status_code, 401)

    def test_logout_revokes_session(self):
        response = self._activate()
        token = response.get_json()["client_session"]
        headers = {"Authorization": f"Bearer {token}"}
        logout = self.client.post("/api/client/session/logout", headers=headers)
        self.assertEqual(logout.status_code, 200)
        self.assertEqual(self.client.get("/api/patches", headers=headers).status_code, 401)


if __name__ == "__main__":
    unittest.main()
