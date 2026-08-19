#!/usr/bin/env python3
"""Transform downloaded raw health data into daily step totals.

Input is a raw download directory produced by download_all_raw_data.py:

    prod-data/raw-data/<download>/users/<personalId>.json

Output is written to a separate derived dataset directory, leaving raw files
untouched. By default, STEPS records are deduplicated in 10-minute windows:
records from multiple sources in the same user/window keep the highest count.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import sys
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


DEFAULT_BUCKET_MINUTES = 10


@dataclass
class Bucket:
    day: str
    bucket_start: str
    steps: Decimal
    source_records: int = 1
    discarded_records: int = 0


@dataclass
class UserSummary:
    personal_id: str
    source_file: str
    raw_records: int
    step_records: int
    invalid_step_records: int
    duplicate_step_records: int
    bucket_count: int
    day_count: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create daily step totals from downloaded raw Swedeheart data."
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
        "-o",
        "--output-dir",
        type=Path,
        help=(
            "Derived output directory. Defaults to "
            "<raw_data_dir>/derived/daily-steps."
        ),
    )
    parser.add_argument(
        "--bucket-minutes",
        type=int,
        default=DEFAULT_BUCKET_MINUTES,
        help=(
            "Dedupe window size based on date_from. Defaults to 10. "
            "Use --exact-interval to dedupe only identical intervals."
        ),
    )
    parser.add_argument(
        "--exact-interval",
        action="store_true",
        help="Dedupe by exact date_from/date_to instead of bucketed date_from windows.",
    )
    return parser.parse_args()


def resolve_users_dir(raw_data_dir: Path) -> Path:
    if raw_data_dir.name == "users":
        return raw_data_dir

    users_dir = raw_data_dir / "users"
    if users_dir.is_dir():
        return users_dir

    raise SystemExit(f"Could not find users/ under {raw_data_dir}")


def default_output_dir(raw_data_dir: Path, users_dir: Path) -> Path:
    if raw_data_dir.name == "users":
        return users_dir.parent / "derived" / "daily-steps"
    return raw_data_dir / "derived" / "daily-steps"


def user_files(users_dir: Path) -> List[Path]:
    files = sorted(path for path in users_dir.glob("*.json") if path.is_file())
    if not files:
        raise SystemExit(f"No user JSON files found in {users_dir}")
    return files


def parse_timestamp(raw: Any) -> Optional[dt.datetime]:
    if not isinstance(raw, str) or not raw:
        return None

    value = raw
    if value.endswith("Z"):
        value = f"{value[:-1]}+00:00"

    try:
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def parse_steps(record: Dict[str, Any]) -> Optional[Decimal]:
    value = record.get("value")
    if not isinstance(value, dict):
        return None

    numeric_value = value.get("numericValue")
    if numeric_value is None:
        return None

    try:
        steps = Decimal(str(numeric_value))
    except InvalidOperation:
        return None

    if steps < 0:
        return None
    return steps


def floor_to_bucket(timestamp: dt.datetime, bucket_minutes: int) -> dt.datetime:
    minute = (timestamp.minute // bucket_minutes) * bucket_minutes
    return timestamp.replace(minute=minute, second=0, microsecond=0)


def iso_no_timezone_suffix(timestamp: dt.datetime) -> str:
    return timestamp.isoformat(timespec="seconds")


def bucket_key(
    record: Dict[str, Any],
    bucket_minutes: int,
    exact_interval: bool,
) -> Optional[Tuple[str, str]]:
    date_from = parse_timestamp(record.get("date_from"))
    if date_from is None:
        return None

    if exact_interval:
        date_to = parse_timestamp(record.get("date_to"))
        if date_to is None:
            return None
        return (iso_no_timezone_suffix(date_from), iso_no_timezone_suffix(date_to))

    bucket_start = floor_to_bucket(date_from, bucket_minutes)
    return (iso_no_timezone_suffix(bucket_start), "")


def load_json_array(path: Path) -> List[Dict[str, Any]]:
    with path.open("r", encoding="utf-8") as file:
        data = json.load(file)

    if not isinstance(data, list):
        raise SystemExit(f"Expected {path} to contain a JSON array.")

    records = []
    for item in data:
        if isinstance(item, dict):
            records.append(item)
    return records


def transform_user(
    path: Path,
    output_dir: Path,
    users_dir: Path,
    bucket_minutes: int,
    exact_interval: bool,
) -> Tuple[List[Dict[str, Any]], UserSummary]:
    records = load_json_array(path)
    buckets: Dict[Tuple[str, str], Bucket] = {}
    step_records = 0
    invalid_step_records = 0
    duplicate_step_records = 0

    for record in records:
        if str(record.get("data_type", "")).upper() != "STEPS":
            continue

        step_records += 1
        steps = parse_steps(record)
        key = bucket_key(record, bucket_minutes, exact_interval)
        if steps is None or key is None:
            invalid_step_records += 1
            continue

        bucket_start = key[0]
        day = bucket_start[:10]
        existing = buckets.get(key)
        if existing is None:
            buckets[key] = Bucket(day=day, bucket_start=bucket_start, steps=steps)
            continue

        duplicate_step_records += 1
        existing.source_records += 1
        existing.discarded_records += 1
        if steps > existing.steps:
            existing.steps = steps

    daily: Dict[str, Dict[str, Any]] = {}
    for bucket in buckets.values():
        row = daily.setdefault(
            bucket.day,
            {
                "personalId": path.stem,
                "date": bucket.day,
                "steps": Decimal("0"),
                "buckets": 0,
                "sourceRecords": 0,
                "discardedDuplicateRecords": 0,
            },
        )
        row["steps"] += bucket.steps
        row["buckets"] += 1
        row["sourceRecords"] += bucket.source_records
        row["discardedDuplicateRecords"] += bucket.discarded_records

    rows = []
    for day in sorted(daily):
        row = daily[day]
        row["steps"] = decimal_to_json_value(row["steps"])
        rows.append(row)

    per_user_path = output_dir / "users" / f"{path.stem}.daily_steps.json"
    write_private_json(per_user_path, rows)

    summary = UserSummary(
        personal_id=path.stem,
        source_file=str(path.relative_to(users_dir.parent)),
        raw_records=len(records),
        step_records=step_records,
        invalid_step_records=invalid_step_records,
        duplicate_step_records=duplicate_step_records,
        bucket_count=len(buckets),
        day_count=len(rows),
    )
    return rows, summary


def decimal_to_json_value(value: Decimal) -> int | float:
    if value == value.to_integral_value():
        return int(value)
    return float(value)


def write_private_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(data, file, indent=2, ensure_ascii=False)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        os.replace(temp_path, path)
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def write_csv(path: Path, rows: Iterable[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp_path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(
            file,
            fieldnames=[
                "personalId",
                "date",
                "steps",
                "buckets",
                "sourceRecords",
                "discardedDuplicateRecords",
            ],
        )
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temp_path, path)


def build_manifest(
    raw_data_dir: Path,
    users_dir: Path,
    output_dir: Path,
    bucket_minutes: int,
    exact_interval: bool,
    summaries: List[UserSummary],
) -> Dict[str, Any]:
    return {
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "rawDataDir": str(raw_data_dir),
        "usersDir": str(users_dir),
        "outputDir": str(output_dir),
        "dataType": "STEPS",
        "dedupeMode": "exact_interval" if exact_interval else "date_from_bucket",
        "bucketMinutes": None if exact_interval else bucket_minutes,
        "userCount": len(summaries),
        "dayCount": sum(summary.day_count for summary in summaries),
        "rawRecords": sum(summary.raw_records for summary in summaries),
        "stepRecords": sum(summary.step_records for summary in summaries),
        "invalidStepRecords": sum(
            summary.invalid_step_records for summary in summaries
        ),
        "duplicateStepRecords": sum(
            summary.duplicate_step_records for summary in summaries
        ),
        "bucketCount": sum(summary.bucket_count for summary in summaries),
        "users": [summary.__dict__ for summary in summaries],
    }


def main() -> int:
    args = parse_args()
    if args.bucket_minutes < 1:
        raise SystemExit("--bucket-minutes must be at least 1")
    if 60 % args.bucket_minutes != 0:
        raise SystemExit("--bucket-minutes must divide evenly into 60")

    raw_data_dir = args.raw_data_dir
    users_dir = resolve_users_dir(raw_data_dir)
    output_dir = args.output_dir or default_output_dir(raw_data_dir, users_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(output_dir, 0o700)

    all_rows: List[Dict[str, Any]] = []
    summaries: List[UserSummary] = []

    files = user_files(users_dir)
    for index, path in enumerate(files, start=1):
        print(f"[{index}/{len(files)}] Transforming {path.name}", flush=True)
        rows, summary = transform_user(
            path,
            output_dir,
            users_dir,
            args.bucket_minutes,
            args.exact_interval,
        )
        all_rows.extend(rows)
        summaries.append(summary)

    all_rows.sort(key=lambda row: (row["personalId"], row["date"]))
    write_csv(output_dir / "daily_steps.csv", all_rows)
    write_private_json(output_dir / "daily_steps.json", all_rows)

    manifest = build_manifest(
        raw_data_dir,
        users_dir,
        output_dir,
        args.bucket_minutes,
        args.exact_interval,
        summaries,
    )
    write_private_json(output_dir / "manifest.json", manifest)

    print(
        f"Wrote {len(all_rows)} daily step rows for {len(summaries)} users to "
        f"{output_dir}"
    )
    print(
        "Collapsed "
        f"{manifest['duplicateStepRecords']} duplicate step records across "
        f"{manifest['bucketCount']} kept buckets."
    )
    if manifest["invalidStepRecords"]:
        print(
            f"Skipped {manifest['invalidStepRecords']} malformed step records.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
