"""Regression tests for the explicitly restored public legacy API."""

import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

TEST_ROOT = Path(tempfile.mkdtemp(prefix="vesperdash-legacy-test-"))
os.environ["VESPERDASH_DATA"] = str(TEST_ROOT / "data")
os.environ["VESPERDASH_PACKAGE_PASSWORDS"] = json.dumps([
    "test-package-password-00000001",
    "test-package-password-00000002",
])
sys.path.insert(0, str(Path(__file__).resolve().parent))
import server  # noqa: E402

server.app.config.update(TESTING=True)


class LegacyPublicAPITests(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(TEST_ROOT / "data", ignore_errors=True)
        self.client = server.app.test_client()

    def test_patch_manifest_is_public_and_includes_package_passwords(self):
        response = self.client.get("/api/patches")
        self.assertEqual(response.status_code, 200)
        manifest = response.get_json()
        self.assertEqual(
            manifest["package_passwords"],
            ["test-package-password-00000001", "test-package-password-00000002"],
        )
        self.assertIn("no-store", response.headers.get("Cache-Control", ""))

    def test_download_route_does_not_require_a_client_session(self):
        response = self.client.get("/api/patches/legacy-public-probe/download")
        self.assertEqual(response.status_code, 404)


def tearDownModule():
    shutil.rmtree(TEST_ROOT, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
