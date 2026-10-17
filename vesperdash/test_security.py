"""Security regression tests for VesperDash client sessions and patch access."""

import hashlib
import hmac
import json
import os
import shutil
import sys
import tempfile
import time
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


def signed_license(key, device_id, valid=True):
    timestamp = int(time.time())
    payload = {
        "valid": valid,
        "status": "active" if valid else "invalid",
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
        self.client = server.app.test_client()
        self.key = "TEST-LICENSE-KEY-1234"
        self.device_id = "00000000-0000-4000-8000-000000000001"

    def _activate(self, key=None, device_id=None, valid=True):
        key = key or self.key
        device_id = device_id or self.device_id
        result = signed_license(key, device_id, valid=valid)
        with patch.object(server, "_verify_license_with_m3sb", return_value=result):
            return self.client.post("/api/client/session", json={"key": key, "device_id": device_id})

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
