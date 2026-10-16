"""Security regression tests for VesperDash client sessions and patch access."""

import os
import hashlib
import hmac
import io
import json
import shutil
import sys
import tempfile
import time
import urllib.error
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

TEST_ROOT = Path(tempfile.mkdtemp(prefix="vesperdash-security-test-"))
os.environ["VESPERDASH_DATA"] = str(TEST_ROOT / "data")
os.environ["VESPERDASH_ADMIN_TOKEN"] = "test-admin-token-never-use-in-production"
os.environ["VESPERDASH_ADMIN_USERNAME"] = "admin"
os.environ["VESPERDASH_ADMIN_PASSWORD"] = "test-admin-password-never-use-in-production"
os.environ["VESPERDASH_JEFRY_PASSWORD"] = ""
os.environ["VESPERDASH_PACKAGE_PASSWORDS"] = '["test-package-password-0123456789"]'
os.environ["VESPERDASH_M3SB_PACKAGE_TOKEN"] = "test-server-token"
os.environ["VESPERDASH_M3SB_HMAC_SECRET"] = "test-server-hmac-secret"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import server  # noqa: E402
real_m3sb_verifier = server.verify_subscription_license


def fake_license_verification(license_key, device_id, body):
    if license_key == "blocked-license":
        return {
            "valid": False,
            "status": "banned",
            "expires_at": None,
            "telegram_username": None,
            "message": "License is not active",
        }
    if license_key == "invalid-expiry-license":
        return {
            "valid": True,
            "status": "active",
            "expires_at": "not-a-date",
            "telegram_username": "@test-owner",
            "message": "Activated successfully",
        }
    return {
        "valid": True,
        "status": "active",
        "expires_at": None,
        "telegram_username": "@test-owner",
        "message": "Activated successfully",
    }


server.verify_subscription_license = fake_license_verification
server.app.config.update(TESTING=True)


class M3SBRequestCompatibilityTests(unittest.TestCase):
    def signed_response(self, device_id):
        secret = os.environ["VESPERDASH_M3SB_HMAC_SECRET"]
        payload = {
            "valid": False,
            "status": "invalid",
            "license": "diagnostic-license",
            "device_hash": hashlib.sha256(device_id.encode("utf-8")).hexdigest(),
            "expires_at": None,
            "devices_left": 0,
            "allow_inject": False,
            "ts": int(time.time()),
        }
        fields = ("valid", "status", "license", "device_hash", "expires_at", "devices_left", "allow_inject", "ts")
        parts = []
        for field in fields:
            value = payload[field]
            value_text = "true" if value is True else "false" if value is False else "" if value is None else str(value)
            parts.append(f"{field}={value_text}")
        payload["sig_v2"] = hmac.new(secret.encode(), "&".join(parts).encode(), hashlib.sha256).hexdigest()
        return payload

    def test_signed_upstream_body_matches_legacy_ios_gate(self):
        device_id = "device-1234567890"
        client_body = {
            "device_name": "Test iPhone",
            "system_info": "iOS 18.7.9",
            "os_info": "18.7.9",
            "dylibs": "2",
        }
        response_payload = self.signed_response(device_id)
        captured = {}

        class FakeResponse:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return None

            def read(self, _limit):
                return json.dumps(response_payload).encode("utf-8")

        class FakeOpener:
            def open(self, request, timeout):
                captured["request"] = request
                captured["timeout"] = timeout
                return FakeResponse()

        with patch.object(server.urllib.request, "build_opener", return_value=FakeOpener()):
            result = real_m3sb_verifier("diagnostic-license", device_id, client_body)

        request = captured["request"]
        request_body = json.loads(request.data)
        expected = {
            "token": "test-server-token",
            "key": "diagnostic-license",
            "device_id": device_id,
            "udid": hashlib.sha256(device_id.encode("utf-8")).hexdigest(),
            "device_name": "Test iPhone",
            "system_info": "iOS 18.7.9",
            "os_info": "18.7.9",
        }
        self.assertEqual(request_body, expected)
        self.assertNotIn("dylibs", request_body)
        self.assertNotIn("device_hash", request_body)
        self.assertEqual(captured["timeout"], 15)
        self.assertEqual(result, response_payload)

        headers = {name.lower(): value for name, value in request.header_items()}
        body_hash = hashlib.sha256(request.data).hexdigest()
        self.assertEqual(headers["x-m3sb-body-sha256"], body_hash)
        canonical = "\n".join((
            "M3SB-API-SIGNATURE-V3", "POST", "/api/sdk/verify",
            headers["x-m3sb-timestamp"], headers["x-m3sb-nonce"], body_hash,
            "test-server-token", "diagnostic-license", device_id,
        ))
        expected_signature = hmac.new(
            os.environ["VESPERDASH_M3SB_HMAC_SECRET"].encode(), canonical.encode(), hashlib.sha256
        ).hexdigest()
        self.assertEqual(headers["x-m3sb-signature"], expected_signature)
        self.assertNotIn("x-apon-client", headers)

    def test_upstream_http_rejection_is_not_reported_as_network_outage(self):
        class RejectingOpener:
            def open(self, _request, timeout):
                raise urllib.error.HTTPError(
                    "https://api.m3sbapi.shop/api/sdk/verify",
                    401,
                    "Unauthorized",
                    {},
                    io.BytesIO(b"must not be logged or returned"),
                )

        with patch.object(server.urllib.request, "build_opener", return_value=RejectingOpener()):
            with self.assertRaisesRegex(RuntimeError, "subscription service rejected the request \\(HTTP 401\\)"):
                real_m3sb_verifier("diagnostic-license", "device-1234567890", {})


class ClientSecurityTests(unittest.TestCase):
    def setUp(self):
        data_dir = TEST_ROOT / "data"
        shutil.rmtree(data_dir, ignore_errors=True)
        self.client = server.app.test_client()
        self.device_id = str(uuid.uuid4())

    def create_session(self, key="valid-license", device_id=None):
        device_id = device_id or self.device_id
        response = self.client.post(
            "/api/auth/client-session",
            json={
                "key": key,
                "device_id": device_id,
                "device_name": "Test iPhone",
                "system_info": "iOS 18.7.9",
                "os_info": "18.7.9",
                "dylibs": "0",
            },
        )
        return response, device_id

    def insert_patch(self, owner="vesper", enabled=1):
        server.PATCH_DIR.mkdir(parents=True, exist_ok=True)
        server.IMAGE_DIR.mkdir(parents=True, exist_ok=True)
        patch_id = f"patch-{owner}"
        stored_filename = f"{patch_id}.3105"
        image_filename = f"{patch_id}.png"
        (server.PATCH_DIR / stored_filename).write_bytes(b"encrypted-test-package")
        (server.IMAGE_DIR / image_filename).write_bytes(b"fake-image-bytes")
        conn = server.db()
        conn.execute(
            """INSERT INTO patches(
                id,name,owner,category,game,bundle_id,target_path,target_paths,filename,
                stored_filename,sha256,size,enabled,paused,version,image_filename,
                status_text,sort_order,created_at,updated_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                patch_id,
                patch_id,
                owner,
                "aim",
                "normal",
                "com.dts.freefireth",
                "",
                "[]",
                stored_filename,
                stored_filename,
                "0" * 64,
                len(b"encrypted-test-package"),
                enabled,
                0,
                "test",
                image_filename,
                "test status",
                1,
                1,
                1,
            ),
        )
        conn.commit()
        conn.close()
        return patch_id, stored_filename, image_filename

    def test_manifest_and_download_require_device_bound_session(self):
        self.insert_patch("vesper")
        self.insert_patch("jefry")
        self.assertEqual(self.client.get("/api/patches").status_code, 401)

        response, device_id = self.create_session()
        self.assertEqual(response.status_code, 200)
        auth_data = response.get_json()
        self.assertIn("access_token", auth_data)
        self.assertEqual(auth_data["package_passwords"], ["test-package-password-0123456789"])
        headers = {
            "Authorization": f"Bearer {auth_data['access_token']}",
            "X-Device-ID": device_id,
        }

        wrong_device = dict(headers, **{"X-Device-ID": str(uuid.uuid4())})
        self.assertEqual(self.client.get("/api/patches", headers=wrong_device).status_code, 401)

        manifest_response = self.client.get("/api/patches?tenant=jefry", headers=headers)
        self.assertEqual(manifest_response.status_code, 200)
        manifest = manifest_response.get_json()
        self.assertEqual(manifest["tenant"], "vesper")
        self.assertEqual([item["id"] for item in manifest["all_patches"]], ["patch-vesper"])
        self.assertIn("no-store", manifest_response.headers["Cache-Control"])

        self.assertEqual(
            self.client.get("/api/patches/patch-vesper/download").status_code,
            401,
        )
        download = self.client.get(
            "/api/patches/patch-vesper/download?tenant=jefry", headers=headers
        )
        self.assertEqual(download.status_code, 200)
        self.assertEqual(download.data, b"encrypted-test-package")
        download.close()
        logout = self.client.post("/api/auth/client-session/logout", headers=headers)
        self.assertEqual(logout.status_code, 200)
        self.assertEqual(self.client.get("/api/patches", headers=headers).status_code, 401)

    def test_admin_dashboard_can_load_preview_but_public_cannot(self):
        _patch_id, _stored, image_filename = self.insert_patch("vesper")
        public_response = self.client.get("/api/patches/patch-vesper/image")
        self.assertEqual(public_response.status_code, 401)

        login = self.client.post(
            "/api/auth/login",
            json={"username": "admin", "password": "test-admin-password-never-use-in-production"},
        )
        self.assertEqual(login.status_code, 200)
        image = self.client.get("/api/patches/patch-vesper/image")
        self.assertEqual(image.status_code, 200)
        self.assertEqual(image.data, (server.IMAGE_DIR / image_filename).read_bytes())
        image.close()

    def test_blocked_license_does_not_receive_session_or_passwords(self):
        response, _ = self.create_session(key="blocked-license")
        self.assertEqual(response.status_code, 401)
        body = response.get_json()
        self.assertFalse(body["valid"])
        self.assertNotIn("access_token", body)
        self.assertNotIn("package_passwords", body)

    def test_short_package_passwords_fail_closed(self):
        original = os.environ["VESPERDASH_PACKAGE_PASSWORDS"]
        try:
            os.environ["VESPERDASH_PACKAGE_PASSWORDS"] = '["weak"]'
            self.assertEqual(server.package_passwords_from_environment(), [])
            response, _ = self.create_session()
            self.assertEqual(response.status_code, 503)
            self.assertNotIn("access_token", response.get_json())
        finally:
            os.environ["VESPERDASH_PACKAGE_PASSWORDS"] = original

    def test_invalid_license_expiry_fails_closed(self):
        response, _ = self.create_session(key="invalid-expiry-license")
        self.assertEqual(response.status_code, 502)
        self.assertNotIn("access_token", response.get_json())

    def test_m3sb_response_signature_is_required_and_fresh(self):
        secret = "server-test-secret"
        payload = {
            "valid": True,
            "status": "active",
            "license": "test-license",
            "device_hash": "device-hash",
            "expires_at": None,
            "devices_left": 1,
            "allow_inject": True,
            "ts": int(time.time()),
        }
        fields = ("valid", "status", "license", "device_hash", "expires_at", "devices_left", "allow_inject", "ts")
        parts = []
        for field in fields:
            value = payload[field]
            value_text = "true" if value is True else "false" if value is False else "" if value is None else str(value)
            parts.append(f"{field}={value_text}")
        payload["sig_v2"] = hmac.new(secret.encode(), "&".join(parts).encode(), hashlib.sha256).hexdigest()
        self.assertTrue(server.m3sb_response_is_trusted(payload, secret))

        tampered = dict(payload, valid=False)
        self.assertFalse(server.m3sb_response_is_trusted(tampered, secret))
        stale = dict(payload, ts=int(time.time()) - 301)
        self.assertFalse(server.m3sb_response_is_trusted(stale, secret))


def tearDownModule():
    shutil.rmtree(TEST_ROOT, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
