"""Regression tests that ensure the legacy public client API stays disabled."""

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

    def test_patch_manifest_is_not_public(self):
        response = self.client.get("/api/patches")
        self.assertEqual(response.status_code, 401)
        self.assertNotIn(b"test-package-password", response.data)

    def test_download_route_requires_a_client_session(self):
        response = self.client.get("/api/patches/legacy-public-probe/download")
        self.assertEqual(response.status_code, 401)


def tearDownModule():
    shutil.rmtree(TEST_ROOT, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
