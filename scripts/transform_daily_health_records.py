#!/usr/bin/env python3
"""Transform downloaded raw health data into daily numeric health rows.

Input is a raw download directory produced by download_all_raw_data.py:

    prod-data/raw-data/<download>/users/<personalId>.json

Output is written to a separate derived dataset directory, leaving raw files
untouched. Numeric records are first collapsed into per-user/data-type/time
buckets so overlapping device/source records do not inflate daily values.

Aggregation policy:
    STEPS: keep the highest value in each bucket, then sum buckets per day.
    Other numeric data types: average values in each bucket, then average
    buckets per day.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import sys
from collections import Counter
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


DEFAULT_BUCKET_MINUTES = 10

CSV_FIELDS = [
    "personalId",
    "date",
    "dataType",
    "unit",
    "value",
    "aggregation",
    "buckets",
    "sourceRecords",
    "collapsedDuplicateRecords",
]


@dataclass
class Bucket:
    day: str
    data_type: str
    unit: str
    aggregation: str
    value: Decimal
    value_count: int = 1
    source_records: int = 1
    collapsed_duplicate_records: int = 0


@dataclass
class UserSummary:
    personal_id: str
    source_file: str
    raw_records: int
    numeric_records: int
    exported_rows: int
    non_object_records: int
    invalid_numeric_records: int
    invalid_timestamp_records: int
    collapsed_duplicate_records: int
    bucket_count: int
    data_types: Dict[str, int]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create daily numeric health rows from downloaded Swedeheart data."
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
        "-o",
        "--output-dir",
        type=Path,
        help=(
            "Derived output directory. Defaults to "
            "<raw_data_dir>/derived/daily-health-records."
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
    parser.add_argument(
        "--data-type",
        action="append",
        dest="data_types",
        help=(
            "Only include this data type. Can be passed multiple times. "
            "Defaults to all numeric data types."
        ),
    )
    parser.add_argument(
        "--limit",
        type=int,
        help="Only transform the first N user files. Useful for smoke tests.",
    )
    parser.add_argument(
        "--decimal-places",
        type=int,
        default=6,
        help="Decimal places for non-integer daily values. Defaults to 6.",
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
        return users_dir.parent / "derived" / "daily-health-records"
    return raw_data_dir / "derived" / "daily-health-records"


def user_files(users_dir: Path, limit: Optional[int]) -> List[Path]:
    if limit is not None and limit < 1:
        raise SystemExit("--limit must be at least 1")

    files = sorted(path for path in users_dir.glob("*.json") if path.is_file())
    if limit is not None:
        files = files[:limit]

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


def parse_numeric_value(record: Dict[str, Any]) -> Optional[Decimal]:
    value = record.get("value")
    if not isinstance(value, dict):
        return None

    numeric_value = value.get("numericValue")
    if numeric_value is None or isinstance(numeric_value, bool):
        return None

    try:
        return Decimal(str(numeric_value))
    except InvalidOperation:
        return None


def floor_to_bucket(timestamp: dt.datetime, bucket_minutes: int) -> dt.datetime:
    minute = (timestamp.minute // bucket_minutes) * bucket_minutes
    return timestamp.replace(minute=minute, second=0, microsecond=0)


def iso_no_timezone_suffix(timestamp: dt.datetime) -> str:
    return timestamp.isoformat(timespec="seconds")


def aggregation_for(data_type: str) -> str:
    if data_type == "STEPS":
        return "sum"
    return "mean"


def bucket_key(
    record: Dict[str, Any],
    data_type: str,
    unit: str,
    bucket_minutes: int,
    exact_interval: bool,
) -> Optional[Tuple[str, str, str, str]]:
    date_from = parse_timestamp(record.get("date_from"))
    if date_from is None:
        return None

    if exact_interval:
        date_to = parse_timestamp(record.get("date_to"))
        if date_to is None:
            return None
        return (
            data_type,
            unit,
            iso_no_timezone_suffix(date_from),
            iso_no_timezone_suffix(date_to),
        )

    bucket_start = floor_to_bucket(date_from, bucket_minutes)
    return (data_type, unit, iso_no_timezone_suffix(bucket_start), "")


def load_json_array(path: Path) -> List[Any]:
    with path.open("r", encoding="utf-8") as file:
        data = json.load(file)

    if not isinstance(data, list):
        raise SystemExit(f"Expected {path} to contain a JSON array.")

    return data


def bucket_value(bucket: Bucket) -> Decimal:
    if bucket.aggregation == "sum":
        return bucket.value
    return bucket.value / bucket.value_count


def decimal_to_text(value: Decimal, decimal_places: int) -> str:
    if value == value.to_integral_value():
        return str(int(value))

    quantizer = Decimal("1").scaleb(-decimal_places)
    text = format(value.quantize(quantizer), "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def daily_rows_from_buckets(
    personal_id: str,
    buckets: Iterable[Bucket],
    decimal_places: int,
) -> List[Dict[str, Any]]:
    daily: Dict[Tuple[str, str, str], Dict[str, Any]] = {}

    for bucket in buckets:
        key = (bucket.day, bucket.data_type, bucket.unit)
        row = daily.setdefault(
            key,
            {
                "personalId": personal_id,
                "date": bucket.day,
                "dataType": bucket.data_type,
                "unit": bucket.unit,
                "value": Decimal("0"),
                "aggregation": bucket.aggregation,
                "buckets": 0,
                "sourceRecords": 0,
                "collapsedDuplicateRecords": 0,
            },
        )
        row["value"] += bucket_value(bucket)
        row["buckets"] += 1
        row["sourceRecords"] += bucket.source_records
        row["collapsedDuplicateRecords"] += bucket.collapsed_duplicate_records

    rows: List[Dict[str, Any]] = []
    for key in sorted(daily):
        row = daily[key]
        if row["aggregation"] == "mean" and row["buckets"]:
            row["value"] = row["value"] / row["buckets"]
        row["value"] = decimal_to_text(row["value"], decimal_places)
        rows.append(row)

    return rows


def transform_user(
    path: Path,
    users_dir: Path,
    bucket_minutes: int,
    exact_interval: bool,
    data_type_filter: Optional[set[str]],
    decimal_places: int,
) -> Tuple[List[Dict[str, Any]], UserSummary]:
    records = load_json_array(path)
    buckets: Dict[Tuple[str, str, str, str], Bucket] = {}
    data_types: Counter[str] = Counter()
    numeric_records = 0
    non_object_records = 0
    invalid_numeric_records = 0
    invalid_timestamp_records = 0

    for record in records:
        if not isinstance(record, dict):
            non_object_records += 1
            continue

        data_type = str(record.get("data_type") or "").upper()
        if not data_type:
            continue
        if data_type_filter is not None and data_type not in data_type_filter:
            continue

        numeric_value = parse_numeric_value(record)
        if numeric_value is None:
            invalid_numeric_records += 1
            continue

        key = bucket_key(
            record,
            data_type,
            str(record.get("unit") or ""),
            bucket_minutes,
            exact_interval,
        )
        if key is None:
            invalid_timestamp_records += 1
            continue

        numeric_records += 1
        data_types[data_type] += 1
        day = key[2][:10]
        aggregation = aggregation_for(data_type)
        existing = buckets.get(key)
        if existing is None:
            buckets[key] = Bucket(
                day=day,
                data_type=data_type,
                unit=key[1],
                aggregation=aggregation,
                value=numeric_value,
            )
            continue

        existing.source_records += 1
        existing.collapsed_duplicate_records += 1
        if aggregation == "sum":
            if numeric_value > existing.value:
                existing.value = numeric_value
        else:
            existing.value += numeric_value
            existing.value_count += 1

    rows = daily_rows_from_buckets(path.stem, buckets.values(), decimal_places)
    summary = UserSummary(
        personal_id=path.stem,
        source_file=str(path.relative_to(users_dir.parent)),
        raw_records=len(records),
        numeric_records=numeric_records,
        exported_rows=len(rows),
        non_object_records=non_object_records,
        invalid_numeric_records=invalid_numeric_records,
        invalid_timestamp_records=invalid_timestamp_records,
        collapsed_duplicate_records=sum(
            bucket.collapsed_duplicate_records for bucket in buckets.values()
        ),
        bucket_count=len(buckets),
        data_types=dict(sorted(data_types.items())),
    )
    return rows, summary


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


def build_manifest(
    raw_data_dir: Path,
    users_dir: Path,
    output_dir: Path,
    bucket_minutes: int,
    exact_interval: bool,
    summaries: List[UserSummary],
    decimal_places: int,
) -> Dict[str, Any]:
    data_types: Counter[str] = Counter()
    for summary in summaries:
        data_types.update(summary.data_types)

    return {
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "rawDataDir": str(raw_data_dir),
        "usersDir": str(users_dir),
        "outputDir": str(output_dir),
        "dedupeMode": "exact_interval" if exact_interval else "date_from_bucket",
        "bucketMinutes": None if exact_interval else bucket_minutes,
        "decimalPlaces": decimal_places,
        "aggregationPolicy": {
            "STEPS": "max per bucket, then daily sum",
            "otherNumericDataTypes": "mean per bucket, then daily mean",
        },
        "userCount": len(summaries),
        "dailyRows": sum(summary.exported_rows for summary in summaries),
        "rawRecords": sum(summary.raw_records for summary in summaries),
        "numericRecords": sum(summary.numeric_records for summary in summaries),
        "bucketCount": sum(summary.bucket_count for summary in summaries),
        "collapsedDuplicateRecords": sum(
            summary.collapsed_duplicate_records for summary in summaries
        ),
        "nonObjectRecords": sum(summary.non_object_records for summary in summaries),
        "invalidNumericRecords": sum(
            summary.invalid_numeric_records for summary in summaries
        ),
        "invalidTimestampRecords": sum(
            summary.invalid_timestamp_records for summary in summaries
        ),
        "dataTypes": dict(sorted(data_types.items())),
        "users": [summary.__dict__ for summary in summaries],
    }


def write_csv_and_manifest(
    raw_data_dir: Path,
    users_dir: Path,
    output_dir: Path,
    files: List[Path],
    bucket_minutes: int,
    exact_interval: bool,
    data_type_filter: Optional[set[str]],
    decimal_places: int,
) -> Dict[str, Any]:
    csv_path = output_dir / "daily_health_records.csv"
    temp_path = csv_path.with_name(f".{csv_path.name}.{os.getpid()}.tmp")
    summaries: List[UserSummary] = []

    with temp_path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=CSV_FIELDS)
        writer.writeheader()

        for index, path in enumerate(files, start=1):
            print(f"[{index}/{len(files)}] Transforming {path.name}", flush=True)
            rows, summary = transform_user(
                path,
                users_dir,
                bucket_minutes,
                exact_interval,
                data_type_filter,
                decimal_places,
            )
            writer.writerows(rows)
            summaries.append(summary)

        file.flush()
        os.fsync(file.fileno())

    os.replace(temp_path, csv_path)

    manifest = build_manifest(
        raw_data_dir,
        users_dir,
        output_dir,
        bucket_minutes,
        exact_interval,
        summaries,
        decimal_places,
    )
    write_private_json(output_dir / "manifest.json", manifest)
    return manifest


def main() -> int:
    args = parse_args()
    if args.bucket_minutes < 1:
        raise SystemExit("--bucket-minutes must be at least 1")
    if 60 % args.bucket_minutes != 0:
        raise SystemExit("--bucket-minutes must divide evenly into 60")
    if args.decimal_places < 0:
        raise SystemExit("--decimal-places must be >= 0")

    raw_data_dir = args.raw_data_dir
    users_dir = resolve_users_dir(raw_data_dir)
    output_dir = args.output_dir or default_output_dir(raw_data_dir, users_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(output_dir, 0o700)

    data_type_filter = None
    if args.data_types:
        data_type_filter = {data_type.upper() for data_type in args.data_types}

    files = user_files(users_dir, args.limit)
    manifest = write_csv_and_manifest(
        raw_data_dir,
        users_dir,
        output_dir,
        files,
        args.bucket_minutes,
        args.exact_interval,
        data_type_filter,
        args.decimal_places,
    )

    print(
        f"Wrote {manifest['dailyRows']} daily health rows for "
        f"{manifest['userCount']} users to {output_dir / 'daily_health_records.csv'}"
    )
    print(
        "Collapsed "
        f"{manifest['collapsedDuplicateRecords']} duplicate source/device records "
        f"across {manifest['bucketCount']} kept buckets."
    )
    if manifest["invalidNumericRecords"]:
        print(
            f"Skipped {manifest['invalidNumericRecords']} non-numeric records.",
            file=sys.stderr,
        )
    if manifest["invalidTimestampRecords"]:
        print(
            f"Skipped {manifest['invalidTimestampRecords']} records with malformed timestamps.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
