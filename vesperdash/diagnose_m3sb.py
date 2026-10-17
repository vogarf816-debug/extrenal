#!/usr/bin/env python3
"""Safely classify M3SB verification failures without printing credentials or raw bodies."""

import io
import json
import os
import re
import shlex
import sys
import urllib.error
from pathlib import Path

ENV_FILE = Path("/etc/vesperdash.env")
SERVER_DIR = Path("/opt/vesperdash/app")
WANTED = {
    "VESPERDASH_M3SB_API_BASE_URL",
    "VESPERDASH_M3SB_PACKAGE_TOKEN",
    "VESPERDASH_M3SB_HMAC_SECRET",
}


def safe_label(value, limit=48):
    return re.sub(r"[^A-Za-z0-9_-]", "", str(value))[:limit] or "missing"


def load_env_file():
    if not ENV_FILE.is_file():
        print("diagnostic_error=env_file_missing")
        raise SystemExit(2)
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        if name not in WANTED:
            continue
        try:
            parts = shlex.split(value.strip(), posix=True)
        except ValueError:
            parts = []
        if len(parts) == 1:
            os.environ[name] = parts[0]
    missing = sorted(name for name in WANTED if not os.environ.get(name))
    if missing:
        print("diagnostic_error=required_env_missing")
        print("missing_names=" + ",".join(missing))
        raise SystemExit(2)


def classify_reason(payload):
    text = " ".join(
        str(payload.get(key, ""))
        for key in ("status", "message", "error", "detail", "code")
    ).lower()
    if any(word in text for word in ("signature", "token", "auth", "credential", "forbidden")):
        return "auth_or_signature"
    if any(word in text for word in ("license", "key", "expired", "device", "invalid")):
        return "license_or_device"
    return "unspecified"


def main():
    load_env_file()
    sys.path.insert(0, str(SERVER_DIR))
    import server

    original_urlopen = server.urllib.request.urlopen

    def inspected_urlopen(req, *args, **kwargs):
        try:
            return original_urlopen(req, *args, **kwargs)
        except urllib.error.HTTPError as exc:
            body = exc.read(1024 * 1024)
            content_type = exc.headers.get("Content-Type", "") if exc.headers else ""
            print("provider_http_status=" + str(exc.code))
            print("provider_content_type=" + content_type.split(";")[0])
            try:
                payload = json.loads(body)
            except Exception:
                print("provider_json=no")
            else:
                if isinstance(payload, dict):
                    print("provider_fields=" + ",".join(sorted(payload.keys())[:12]))
                    print("provider_status=" + safe_label(payload.get("status", "missing")))
                    valid = payload.get("valid")
                    print("provider_valid=" + (str(valid).lower() if isinstance(valid, bool) else "missing"))
                    print("provider_reason_category=" + classify_reason(payload))
                else:
                    print("provider_json=non_object")
            raise urllib.error.HTTPError(
                exc.url, exc.code, str(exc.reason), exc.headers, io.BytesIO(body)
            )

    server.urllib.request.urlopen = inspected_urlopen
    try:
        result = server._verify_license_with_m3sb(
            "DIAGNOSTIC-INVALID-KEY-000000000000",
            "00000000-0000-4000-8000-000000000001",
            {"dylibs": 0, "device_name": "diagnostic", "system_info": "iOS", "os_info": "iOS"},
        )
        print("helper_result=json")
        print("helper_valid=" + str(bool(result.get("valid")).lower()))
        print("helper_status=" + safe_label(result.get("status", "missing")))
        print("helper_reason_category=" + classify_reason(result))
    except server.LicenseProviderHTTPError as exc:
        print("helper_result=provider_rejected")
        print("helper_http_status=" + str(exc.status_code))
    except Exception as exc:
        print("helper_result=error")
        print("helper_error_type=" + type(exc).__name__)


if __name__ == "__main__":
    main()
