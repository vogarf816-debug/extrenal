#!/usr/bin/env python3
"""Atomically merge allow-listed VesperDash runtime secrets from stdin."""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

ENV_FILE = Path("/etc/vesperdash.env")
MANAGED_KEYS = {
    "VESPERDASH_M3SB_API_BASE_URL",
    "VESPERDASH_M3SB_PACKAGE_TOKEN",
    "VESPERDASH_M3SB_HMAC_SECRET",
    "VESPERDASH_PACKAGE_PASSWORDS",
}


def validate(payload: object) -> dict[str, str]:
    if not isinstance(payload, dict) or set(payload) != MANAGED_KEYS:
        raise ValueError("payload must contain exactly the allow-listed environment keys")
    result: dict[str, str] = {}
    for key in MANAGED_KEYS:
        value = payload[key]
        if not isinstance(value, str) or not value or any(ch in value for ch in "\x00\r\n"):
            raise ValueError(f"invalid value for {key}")
        result[key] = value

    parsed = urlparse(result["VESPERDASH_M3SB_API_BASE_URL"])
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("M3SB API base URL must be HTTPS")

    try:
        passwords = json.loads(result["VESPERDASH_PACKAGE_PASSWORDS"])
    except json.JSONDecodeError as exc:
        raise ValueError("package password list is not valid JSON") from exc
    if not isinstance(passwords, list) or not passwords or any(
        not isinstance(item, str) or len(item.strip()) < 16 for item in passwords
    ):
        raise ValueError("package passwords must be a JSON list; each password must be at least 16 characters")
    return result


def systemd_quote(value: str) -> str:
    if any(ch in value for ch in "\x00\r\n"):
        raise ValueError("multiline environment values are not allowed")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def update_env_file(path: Path, values: dict[str, str]) -> None:
    if not path.is_file() or path.is_symlink():
        raise FileNotFoundError("existing environment file is required")
    current = path.read_text(encoding="utf-8").splitlines()
    kept: list[str] = []
    for line in current:
        key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else ""
        if key not in MANAGED_KEYS:
            kept.append(line)
    additions = [f"{key}={systemd_quote(values[key])}" for key in sorted(MANAGED_KEYS)]
    content = "\n".join(kept + additions).rstrip() + "\n"

    fd, temporary = tempfile.mkstemp(prefix=".vesperdash.env.", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        if os.geteuid() == 0:
            os.fchown(fd, 0, 0)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    os.chmod(path, 0o600)
    if os.geteuid() == 0:
        os.chown(path, 0, 0)


def main() -> int:
    if os.geteuid() != 0:
        print("ERROR: run this helper as root", file=sys.stderr)
        return 1
    try:
        payload = json.load(sys.stdin)
        values = validate(payload)
        update_env_file(ENV_FILE, values)
    except Exception as exc:
        # Deliberately avoid echoing payloads or secret values.
        print(f"ERROR: could not update VesperDash environment ({type(exc).__name__})", file=sys.stderr)
        return 1
    print("VesperDash environment updated atomically; secret values were not printed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
