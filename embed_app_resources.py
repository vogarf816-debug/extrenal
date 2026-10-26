#!/usr/bin/env python3
"""Embed audio and reference app icons in the SAK executable.

The two audio files are read from the executable trailer at runtime and are
removed from the app bundle. Info.plist and Assets.car stay at their standard
iOS-required paths; PkgInfo and the two standard icon PNGs are also retained.
At startup, the app checks only its display/bundle identity and the two app-icon
files. It does not hash unrelated app files.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

RESOURCE_NAMES = (
    "ACTIVADA.m4a",
    "DESACTIVADA.m4a",
    "Assets.car",
    "PkgInfo",
    "Info.plist",
    "AppIcon60x60@2x.png",
    "AppIcon76x76@2x~ipad.png",
)
AUDIO_NAMES = ("ACTIVADA.m4a", "DESACTIVADA.m4a")
PAYLOAD_NAMES = RESOURCE_NAMES
PAYLOAD_MAGIC = b"VSPRPAY1"
FOOTER_MAGIC = b"VSPRFTR1"
FOOTER_SIZE = len(FOOTER_MAGIC) + 16


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
    raise ValueError("SAK executable has no valid embedded-resource footer")


def encode_payload(resources: dict[str, bytes]) -> bytes:
    chunks = [PAYLOAD_MAGIC, struct.pack(">I", len(PAYLOAD_NAMES))]
    for name in PAYLOAD_NAMES:
        encoded_name = name.encode("utf-8")
        content = resources[name]
        chunks.extend((struct.pack(">H", len(encoded_name)), struct.pack(">Q", len(content)), encoded_name, content))
    return b"".join(chunks)


def embed(app_dir: Path) -> None:
    executable = app_dir / "SAK"
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
    try:
        existing = read_embedded(executable)
    except ValueError:
        pass
    else:
        if existing != resources:
            raise ValueError("SAK already has a different embedded-resource payload")
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
    print("Embedded and verified only the audio, required resources, and app icons: " + ", ".join(RESOURCE_NAMES))
    print(f"Payload bytes appended: {len(payload):,}")


def strip_audio(app_dir: Path) -> None:
    executable = app_dir / "SAK"
    embedded = read_embedded(executable)
    for name in AUDIO_NAMES:
        path = app_dir / name
        if not path.is_file():
            raise ValueError(f"Audio file expected before stripping: {path}")
        if path.read_bytes() != embedded[name]:
            raise ValueError(f"Embedded audio does not match bundle resource: {name}")
    for name in AUDIO_NAMES:
        (app_dir / name).unlink()
    print("Removed audio bundle copies after verifying both sounds are embedded in SAK.")


def verify(app_dir: Path) -> None:
    embedded = read_embedded(app_dir / "SAK")
    for name in RESOURCE_NAMES:
        path = app_dir / name
        if name in AUDIO_NAMES:
            if path.exists():
                raise ValueError(f"Audio bundle copy should be removed: {name}")
        elif name == "Info.plist":
            if not path.is_file():
                raise ValueError("Required Info.plist is missing from the app bundle")
        elif not path.is_file() or path.read_bytes() != embedded[name]:
            raise ValueError(f"Embedded copy does not match required bundle resource: {name}")
    print("Verified embedded audio and required resources; icon files are ready for runtime identity checks.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_dir", type=Path, help="path to SAKK EXTERNAL.app")
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
