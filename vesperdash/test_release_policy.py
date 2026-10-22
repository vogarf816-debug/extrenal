"""Regression tests for public and administrator release-policy endpoints."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

TEST_ROOT = Path(tempfile.mkdtemp(prefix="vesperdash-release-policy-test-"))
os.environ["VESPERDASH_DATA"] = str(TEST_ROOT / "data")
sys.path.insert(0, str(Path(__file__).resolve().parent))
import server  # noqa: E402


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(TEST_ROOT / "data", ignore_errors=True)
        server.DATA = TEST_ROOT / "data"
        server.DB = server.DATA / "vesperdash.sqlite3"
        server._DB_INITIALIZED.clear()
        self.client = server.app.test_client()
        self.admin_patch = patch.object(server, "ADMIN_TOKEN", "release-policy-test-token")
        self.admin_patch.start()
        self.addCleanup(self.admin_patch.stop)
        self.headers = {"X-Admin-Token": "release-policy-test-token"}

    def test_policy_is_public_read_only_and_admin_route_requires_auth(self):
        public = self.client.get("/api/release-policy")
        self.assertEqual(public.status_code, 200)
        self.assertEqual(public.get_json()["minimum_build"], 0)
        self.assertEqual(self.client.get("/api/admin/release-policy").status_code, 401)

    def test_admin_can_save_policy_and_public_endpoint_reads_it(self):
        policy = {
            "latest_build": 44,
            "minimum_build": 40,
            "download_url": "https://example.com/app.ipa",
            "update_message": "Please update to continue.",
        }
        response = self.client.post("/api/admin/release-policy", json=policy, headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), policy)
        self.assertEqual(self.client.get("/api/release-policy").get_json(), policy)

    def test_invalid_build_ranges_and_non_https_url_are_rejected(self):
        invalid = [
            {"latest_build": 0, "minimum_build": 0, "download_url": "https://example.com/a.ipa"},
            {"latest_build": 2, "minimum_build": 3, "download_url": "https://example.com/a.ipa"},
            {"latest_build": 2, "minimum_build": 0, "download_url": "http://example.com/a.ipa"},
        ]
        for payload in invalid:
            with self.subTest(payload=payload):
                response = self.client.post("/api/admin/release-policy", json=payload, headers=self.headers)
                self.assertEqual(response.status_code, 400)

    def test_policy_is_scoped_by_tenant(self):
        policy = {
            "latest_build": 9,
            "minimum_build": 7,
            "download_url": "https://example.com/jefry.ipa",
            "update_message": "Jefry update",
        }
        response = self.client.post("/api/admin/release-policy?tenant=jefry", json=policy, headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.get("/api/release-policy?tenant=jefry").get_json(), policy)
        self.assertNotEqual(self.client.get("/api/release-policy").get_json()["latest_build"], 9)


if __name__ == "__main__":
    unittest.main()
