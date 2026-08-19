#!/usr/bin/env python3
"""Count users whose raw health data includes both iPhone and Apple Watch sources.

Input is a raw download directory produced by download_all_raw_data.py:

    prod-data/raw-data/<download>/users/<personalId>.json

The script accepts either the download root containing users/ or the users/
directory itself, matching the transform scripts. Device class detection is
based on source_name because device_id is an opaque UUID in the raw data.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, List, Tuple


@dataclass
class UserDeviceSummary:
    personal_id: str
    source_file: str
    raw_records: int
    has_iphone: bool
    has_apple_watch: bool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Count users with both iPhone and Apple Watch sources in downloaded "
            "Swedeheart raw health data."
        )
    )
    parser.add_argument(
        "raw_data_dir",
        type=Path,
        help=(
            "Raw download directory. Accepts either the download root containing "
            "users/ or the users/ directory itself."
        ),
    )
    parser.add_argument(
        "--list-users",
        action="store_true",
        help="Print matching personal IDs after the aggregate counts.",
    )
    return parser.parse_args()


def resolve_users_dir(raw_data_dir: Path) -> Path:
    if raw_data_dir.name == "users":
        return raw_data_dir

    users_dir = raw_data_dir / "users"
    if users_dir.is_dir():
        return users_dir

    raise SystemExit(f"Could not find users/ under {raw_data_dir}")


def user_files(users_dir: Path) -> List[Path]:
    files = sorted(path for path in users_dir.glob("*.json") if path.is_file())
    if not files:
        raise SystemExit(f"No user JSON files found in {users_dir}")
    return files


def load_json_array(path: Path) -> List[Any]:
    with path.open("r", encoding="utf-8") as file:
        data = json.load(file)

    if not isinstance(data, list):
        raise SystemExit(f"Expected {path} to contain a JSON array.")

    return data


def normalized_source_name(value: Any) -> str:
    if not isinstance(value, str):
        return ""

    normalized = unicodedata.normalize("NFKC", value).casefold()
    return re.sub(r"[^a-z0-9]+", "", normalized)


def source_device_flags(source_name: Any) -> Tuple[bool, bool]:
    normalized = normalized_source_name(source_name)
    return "iphone" in normalized, "applewatch" in normalized


def scan_user(path: Path, users_dir: Path) -> UserDeviceSummary:
    records = load_json_array(path)
    has_iphone = False
    has_apple_watch = False

    for record in records:
        if not isinstance(record, dict):
            continue

        record_has_iphone, record_has_apple_watch = source_device_flags(
            record.get("source_name")
        )
        has_iphone = has_iphone or record_has_iphone
        has_apple_watch = has_apple_watch or record_has_apple_watch

        if has_iphone and has_apple_watch:
            break

    return UserDeviceSummary(
        personal_id=path.stem,
        source_file=str(path.relative_to(users_dir.parent)),
        raw_records=len(records),
        has_iphone=has_iphone,
        has_apple_watch=has_apple_watch,
    )


def main() -> int:
    args = parse_args()
    raw_data_dir = args.raw_data_dir
    users_dir = resolve_users_dir(raw_data_dir)
    files = user_files(users_dir)

    summaries: List[UserDeviceSummary] = []
    for index, path in enumerate(files, start=1):
        print(f"[{index}/{len(files)}] Scanning user file", flush=True)
        summaries.append(scan_user(path, users_dir))

    matching_users = [
        summary
        for summary in summaries
        if summary.has_iphone and summary.has_apple_watch
    ]
    iphone_users = [summary for summary in summaries if summary.has_iphone]
    apple_watch_users = [summary for summary in summaries if summary.has_apple_watch]

    print(f"Users scanned: {len(summaries)}")
    print(f"Users with iPhone source: {len(iphone_users)}")
    print(f"Users with Apple Watch source: {len(apple_watch_users)}")
    print(f"Users with both iPhone and Apple Watch sources: {len(matching_users)}")

    if args.list_users:
        print("Matching users:")
        for summary in matching_users:
            print(summary.personal_id)

    return 0


if __name__ == "__main__":
    sys.exit(main())
