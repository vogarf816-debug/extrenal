#!/usr/bin/env python3
"""Embed essential resources and an integrity manifest in the VESPER executable.

The two audio files are read from the executable trailer at runtime and are
removed from the app bundle. Info.plist and Assets.car stay at their standard
iOS-required paths; PkgInfo is also retained. A manifest covers every other
bundle file and is checked by the app at startup. Code-signing artifacts and
the executable itself are excluded from the manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

RESOURCE_NAMES = (
    "ACTIVADA.m4a",
    "DESACTIVADA.m4a",
    "Assets.car",
    "PkgInfo",
    "Info.plist",
)
AUDIO_NAMES = ("ACTIVADA.m4a", "DESACTIVADA.m4a")
MANIFEST_NAME = "__VESPER_BUNDLE_MANIFEST__.json"
PAYLOAD_NAMES = (*RESOURCE_NAMES, MANIFEST_NAME)
PAYLOAD_MAGIC = b"VSPRPAY1"
FOOTER_MAGIC = b"VSPRFTR1"
FOOTER_SIZE = len(FOOTER_MAGIC) + 16
SIGNATURE_DIR = "_CodeSignature"


def read_u64(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 8 > len(data):
        raise ValueError("Embedded resource index is truncated")
    return struct.unpack_from(">Q", data, offset)[0]


def _decode_payload(payload: bytes) -> dict[str, bytes]:
    if len(payload) < len(PAYLOAD_MAGIC) + 4 or payload[: len(PAYLOAD_MAGIC)] != PAYLOAD_MAGIC:
        raise ValueError("Embedded-resource payload is invalid")
    data = memoryview(payload)
    cursor = len(PAYLOAD_MAGIC)
    count = struct.unpack_from(">I", data, cursor)[0]
    cursor += 4
    found: dict[str, bytes] = {}
    for _ in range(count):
        if cursor + 10 > len(data):
            raise ValueError("Embedded-resource record is truncated")
        name_size = struct.unpack_from(">H", data, cursor)[0]
        content_size = struct.unpack_from(">Q", data, cursor + 2)[0]
        cursor += 10
        name_end = cursor + name_size
        content_end = name_end + content_size
        if name_size == 0 or content_end > len(data):
            raise ValueError("Embedded-resource record bounds are invalid")
        try:
            name = bytes(data[cursor:name_end]).decode("utf-8")
        except UnicodeDecodeError as error:
            raise ValueError("Embedded-resource filename is invalid UTF-8") from error
        if name in found:
            raise ValueError(f"Duplicate embedded resource: {name}")
        found[name] = bytes(data[name_end:content_end])
        cursor = content_end
    if cursor != len(data) or set(found) != set(PAYLOAD_NAMES):
        raise ValueError(f"Unexpected embedded-resource list: {sorted(found)}")
    return found


def read_embedded(executable: Path) -> dict[str, bytes]:
    with executable.open("rb") as stream:
        stream.seek(0, 2)
        file_size = stream.tell()
        scan_end = file_size
        block_size = 1024 * 1024
        while scan_end > 0:
            scan_start = max(0, scan_end - block_size)
            stream.seek(scan_start)
            block = stream.read(scan_end - scan_start)
            block_view = memoryview(block)
            if len(block) >= FOOTER_SIZE:
                for pos in range(len(block) - FOOTER_SIZE, -1, -1):
                    if block[pos : pos + len(FOOTER_MAGIC)] != FOOTER_MAGIC:
                        continue
                    footer_pos = scan_start + pos
                    payload_offset = read_u64(block, pos + len(FOOTER_MAGIC))
                    payload_size = read_u64(block, pos + len(FOOTER_MAGIC) + 8)
                    if payload_size == 0 or payload_offset + payload_size != footer_pos:
                        continue
                    stream.seek(payload_offset)
                    payload = stream.read(payload_size)
                    if len(payload) != payload_size:
                        continue
                    return _decode_payload(payload)
            if scan_start == 0:
                break
            scan_end = scan_start + FOOTER_SIZE - 1
    raise ValueError("VESPER executable has no valid embedded-resource footer")


def _excluded_from_manifest(relative: str) -> bool:
    parts = Path(relative).parts
    return (
        relative == "VESPER"
        or relative in AUDIO_NAMES
        or SIGNATURE_DIR in parts
        or relative == "embedded.mobileprovision"
    )


def bundle_manifest(app_dir: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(app_dir.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(app_dir).as_posix()
        if _excluded_from_manifest(relative):
            continue
        result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not result:
        raise ValueError("No app bundle files were found for the integrity manifest")
    return result


def encode_payload(resources: dict[str, bytes]) -> bytes:
    chunks = [PAYLOAD_MAGIC, struct.pack(">I", len(PAYLOAD_NAMES))]
    for name in PAYLOAD_NAMES:
        encoded_name = name.encode("utf-8")
        content = resources[name]
        chunks.extend((struct.pack(">H", len(encoded_name)), struct.pack(">Q", len(content)), encoded_name, content))
    return b"".join(chunks)


def embed(app_dir: Path) -> None:
    executable = app_dir / "VESPER"
    if not executable.is_file():
        raise ValueError(f"Missing executable: {executable}")
    resources: dict[str, bytes] = {}
    for name in RESOURCE_NAMES:
        path = app_dir / name
        if not path.is_file():
            raise ValueError(f"Required app resource is missing: {path}")
        resources[name] = path.read_bytes()
        if not resources[name]:
            raise ValueError(f"Required app resource is empty: {path}")
    manifest = bundle_manifest(app_dir)
    resources[MANIFEST_NAME] = json.dumps(
        {"version": 1, "files": manifest},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    try:
        existing = read_embedded(executable)
    except ValueError:
        pass
    else:
        if existing != resources:
            raise ValueError("VESPER already has a different embedded-resource payload")
        print("Embedded resource payload already exists and is verified.")
        return

    payload = encode_payload(resources)
    with executable.open("ab") as stream:
        payload_offset = stream.tell()
        stream.write(payload)
        stream.write(FOOTER_MAGIC)
        stream.write(struct.pack(">QQ", payload_offset, len(payload)))
        stream.flush()
    if read_embedded(executable) != resources:
        raise ValueError("Embedded-resource payload failed post-write verification")
    print("Embedded and verified: " + ", ".join(RESOURCE_NAMES) + " plus file-integrity manifest")
    print(f"Payload bytes appended: {len(payload):,}")


def strip_audio(app_dir: Path) -> None:
    executable = app_dir / "VESPER"
    embedded = read_embedded(executable)
    for name in AUDIO_NAMES:
        path = app_dir / name
        if not path.is_file():
            raise ValueError(f"Audio file expected before stripping: {path}")
        if path.read_bytes() != embedded[name]:
            raise ValueError(f"Embedded audio does not match bundle resource: {name}")
    for name in AUDIO_NAMES:
        (app_dir / name).unlink()
    print("Removed audio bundle copies after verifying both sounds are embedded in VESPER.")


def verify(app_dir: Path) -> None:
    embedded = read_embedded(app_dir / "VESPER")
    for name in RESOURCE_NAMES:
        path = app_dir / name
        if name in AUDIO_NAMES:
            if path.exists():
                raise ValueError(f"Audio bundle copy should be removed: {name}")
        elif not path.is_file() or path.read_bytes() != embedded[name]:
            raise ValueError(f"Embedded copy does not match required bundle resource: {name}")
    try:
        parsed = json.loads(embedded[MANIFEST_NAME])
    except (KeyError, json.JSONDecodeError) as error:
        raise ValueError("Embedded app integrity manifest is invalid") from error
    if parsed.get("version") != 1 or parsed.get("files") != bundle_manifest(app_dir):
        raise ValueError("App bundle files do not match the embedded integrity manifest")
    print("Verified embedded resources, stripped audio, and app bundle integrity manifest.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_dir", type=Path, help="path to VESPER.app")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--strip-audio", action="store_true", help="remove audio files after checking embedded copies")
    mode.add_argument("--verify", action="store_true", help="verify the embedded payload and bundle state")
    args = parser.parse_args()
    action = verify if args.verify else strip_audio if args.strip_audio else embed
    try:
        action(args.app_dir)
    except (OSError, ValueError, struct.error) as error:
        print(f"Embedded app resources: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
