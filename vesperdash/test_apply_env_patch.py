import json
import stat
import tempfile
import unittest
from pathlib import Path

from vesperdash.apply_env_patch import MANAGED_KEYS, systemd_quote, update_env_file, validate


class EnvPatchTests(unittest.TestCase):
    def payload(self):
        return {
            "VESPERDASH_M3SB_API_BASE_URL": "https://api.m3sbapi.shop",
            "VESPERDASH_M3SB_PACKAGE_TOKEN": "fresh-package-token-value",
            "VESPERDASH_M3SB_HMAC_SECRET": "fresh-hmac-secret-value",
            "VESPERDASH_PACKAGE_PASSWORDS": json.dumps(["a" * 32]),
        }

    def test_validate_accepts_secure_payload(self):
        values = validate(self.payload())
        self.assertEqual(set(values), MANAGED_KEYS)

    def test_validate_rejects_short_package_password(self):
        payload = self.payload()
        payload["VESPERDASH_PACKAGE_PASSWORDS"] = json.dumps(["short"])
        with self.assertRaises(ValueError):
            validate(payload)

    def test_validate_requires_https(self):
        payload = self.payload()
        payload["VESPERDASH_M3SB_API_BASE_URL"] = "http://example.invalid"
        with self.assertRaises(ValueError):
            validate(payload)

    def test_systemd_quote_escapes_quotes_and_backslashes(self):
        self.assertEqual(systemd_quote('abc\\def"ghi'), '"abc\\\\def\\"ghi"')

    def test_update_preserves_unmanaged_settings_and_replaces_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "vesperdash.env"
            path.write_text(
                "VESPERDASH_ADMIN_USERNAME=admin\n"
                "VESPERDASH_M3SB_PACKAGE_TOKEN=old-value\n"
                "VESPERDASH_M3SB_PACKAGE_TOKEN=duplicate-old-value\n"
                "# VESPERDASH_M3SB_HMAC_SECRET=commented\n",
                encoding="utf-8",
            )
            update_env_file(path, validate(self.payload()))
            result = path.read_text(encoding="utf-8")
            self.assertIn("VESPERDASH_ADMIN_USERNAME=admin", result)
            self.assertEqual(result.count("VESPERDASH_M3SB_PACKAGE_TOKEN="), 1)
            self.assertNotIn("old-value", result)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
