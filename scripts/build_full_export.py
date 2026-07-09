#!/usr/bin/env python3
"""Build a statistician handoff export from downloaded Swedeheart data.

This script does not download production data. It expects a raw download
directory created by download_all_raw_data.py and produces an immutable export
folder with tidy raw health rows, daily derived rows, manifests, checksums, and
optional clinical alignment outputs.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import transform_daily_health_records as daily_transform  # noqa: E402


RAW_HEALTH_FIELDS = [
    "subject_id",
    "record_id",
    "record_index",
    "data_type",
    "unit",
    "numeric_value",
    "value_json",
    "date_from",
    "date_to",
    "date",
    "platform_type",
    "device_id",
    "source_id",
    "source_name",
    "source_file",
]

DEFAULT_PARQUET_MODE = "auto"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Build a full local export package from a downloaded Swedeheart raw "
            "data directory."
        )
    )
    parser.add_argument(
        "raw_data_dir",
        type=Path,
        help="Raw download directory containing users/ or the users/ directory itself.",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        required=True,
        help="Export root to create, for example swedeheart_full_export_20260706.",
    )
    parser.add_argument(
        "--allow-existing",
        action="store_true",
        help="Allow writing into an existing output directory if it is empty.",
    )
    parser.add_argument(
        "--include-personal-id-in-main",
        action="store_true",
        help=(
            "Keep personalId columns in main raw/derived exports. By default they "
            "are written only to keys_sensitive_separate/personal_id_map.csv."
        ),
    )
    parser.add_argument(
        "--include-original-json",
        action="store_true",
        help="Copy per-user raw JSON files into raw/original_user_json/.",
    )
    parser.add_argument(
        "--parquet",
        choices=("auto", "require", "skip"),
        default=DEFAULT_PARQUET_MODE,
        help=(
            "Parquet output mode. auto writes Parquet when pyarrow is installed, "
            "require fails if pyarrow is unavailable, skip disables Parquet."
        ),
    )
    parser.add_argument(
        "--bucket-minutes",
        type=int,
        default=daily_transform.DEFAULT_BUCKET_MINUTES,
        help="Daily transform dedupe bucket size. Defaults to 10.",
    )
    parser.add_argument(
        "--exact-interval",
        action="store_true",
        help="Use exact date_from/date_to intervals for daily transform dedupe.",
    )
    parser.add_argument(
        "--skip-daily-health-records",
        action="store_true",
        help="Skip daily_health_records.csv.gz generation.",
    )
    parser.add_argument(
        "--keys",
        type=Path,
        help="Optional key file for clinical alignment, passed to the R script.",
    )
    parser.add_argument(
        "--clinical",
        type=Path,
        help="Optional clinical file for clinical alignment, passed to the R script.",
    )
    parser.add_argument(
        "--skip-alignment",
        action="store_true",
        help="Skip the R clinical alignment step even if --keys and --clinical are set.",
    )
    parser.add_argument("--rscript", default="Rscript", help="Rscript executable.")
    parser.add_argument("--clinical-sheet", default="RiksHia")
    parser.add_argument("--clinical-key-col", default="pseudo_PNR")
    parser.add_argument("--clinical-heartattack-date-col", default="P")
    parser.add_argument("--clinical-heartattack-type-col", default="GJ")
    parser.add_argument("--clinical-physio-sheet", default="Physio")
    parser.add_argument("--clinical-physio-key-col", default="")
    parser.add_argument("--clinical-physio-value-cols", default="E,F,G")
    parser.add_argument("--window-before", type=int)
    parser.add_argument("--window-after", type=int)
    parser.add_argument(
        "--metadata-dir",
        type=Path,
        help=(
            "Optional directory produced by export_pocketbase_collections.py. It "
            "will be copied into metadata/pocketbase_collections/."
        ),
    )
    return parser.parse_args()


def normalize_paths(args: argparse.Namespace) -> None:
    args.raw_data_dir = args.raw_data_dir.expanduser().resolve()
    args.output_dir = args.output_dir.expanduser().resolve()
    if args.keys is not None:
        args.keys = args.keys.expanduser().resolve()
    if args.clinical is not None:
        args.clinical = args.clinical.expanduser().resolve()
    if args.metadata_dir is not None:
        args.metadata_dir = args.metadata_dir.expanduser().resolve()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def resolve_users_dir(raw_data_dir: Path) -> Path:
    if raw_data_dir.name == "users":
        users_dir = raw_data_dir
    else:
        users_dir = raw_data_dir / "users"

    if not users_dir.is_dir():
        raise SystemExit(f"Could not find users/ under {raw_data_dir}")
    return users_dir


def ensure_output_root(path: Path, allow_existing: bool) -> None:
    if path.exists():
        if not path.is_dir():
            raise SystemExit(f"Output path exists and is not a directory: {path}")
        if any(path.iterdir()):
            raise SystemExit(
                f"Output directory is not empty: {path}. Use a fresh directory."
            )
        if not allow_existing:
            raise SystemExit(
                f"Output directory already exists: {path}. Pass --allow-existing "
                "only for an existing empty directory."
            )
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


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


def build_subject_map(files: Iterable[Path]) -> Dict[str, str]:
    personal_ids = sorted(path.stem for path in files)
    return {
        personal_id: f"S{index:06d}"
        for index, personal_id in enumerate(personal_ids, start=1)
    }


def open_csv_gz(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    return gzip.open(path, "wt", encoding="utf-8", newline="")


def write_personal_id_map(
    path: Path,
    files: Iterable[Path],
    subject_map: Dict[str, str],
    users_dir: Path,
) -> None:
    with path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(
            file, fieldnames=["subject_id", "personalId", "source_file"]
        )
        writer.writeheader()
        for user_file in sorted(files):
            personal_id = user_file.stem
            writer.writerow(
                {
                    "subject_id": subject_map[personal_id],
                    "personalId": personal_id,
                    "source_file": str(user_file.relative_to(users_dir.parent)),
                }
            )


def flatten_record(
    *,
    personal_id: str,
    subject_id: str,
    record_index: int,
    record: Any,
    source_file: str,
    include_personal_id: bool,
) -> Tuple[Dict[str, Any], Dict[str, int]]:
    stats = {
        "nonObjectRecords": 0,
        "numericRecords": 0,
        "nonNumericRecords": 0,
        "recordsWithDateFrom": 0,
    }

    if not isinstance(record, dict):
        stats["nonObjectRecords"] = 1
        row = {
            field: "" for field in RAW_HEALTH_FIELDS
        }
        row.update(
            {
                "subject_id": subject_id,
                "record_id": f"{subject_id}:{record_index:08d}",
                "record_index": record_index,
                "source_file": source_file,
                "value_json": json.dumps(record, ensure_ascii=False, sort_keys=True),
            }
        )
        return row, stats

    value = record.get("value")
    numeric_value = ""
    if isinstance(value, dict) and not isinstance(value.get("numericValue"), bool):
        raw_numeric = value.get("numericValue")
        if raw_numeric is not None:
            numeric_value = str(raw_numeric)
            stats["numericRecords"] = 1

    if numeric_value == "":
        stats["nonNumericRecords"] = 1

    date_from = str(record.get("date_from") or "")
    if date_from:
        stats["recordsWithDateFrom"] = 1

    row = {
        "subject_id": subject_id,
        "record_id": f"{subject_id}:{record_index:08d}",
        "record_index": record_index,
        "data_type": str(record.get("data_type") or ""),
        "unit": str(record.get("unit") or ""),
        "numeric_value": numeric_value,
        "value_json": json.dumps(value, ensure_ascii=False, sort_keys=True),
        "date_from": date_from,
        "date_to": str(record.get("date_to") or ""),
        "date": date_from[:10] if len(date_from) >= 10 else "",
        "platform_type": str(record.get("platform_type") or ""),
        "device_id": str(record.get("device_id") or ""),
        "source_id": str(record.get("source_id") or ""),
        "source_name": str(record.get("source_name") or ""),
        "source_file": source_file,
    }
    if include_personal_id:
        row["personalId"] = personal_id
    return row, stats


def write_raw_health_records(
    *,
    output_path: Path,
    files: List[Path],
    users_dir: Path,
    subject_map: Dict[str, str],
    include_personal_id: bool,
) -> Dict[str, Any]:
    fields = list(RAW_HEALTH_FIELDS)
    if include_personal_id:
        fields.insert(1, "personalId")

    totals: Dict[str, Any] = {
        "userCount": len(files),
        "rawRecords": 0,
        "nonObjectRecords": 0,
        "numericRecords": 0,
        "nonNumericRecords": 0,
        "recordsWithDateFrom": 0,
        "dataTypes": {},
        "users": [],
    }

    with open_csv_gz(output_path) as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for user_file in files:
            personal_id = user_file.stem
            subject_id = subject_map[personal_id]
            records = load_json_array(user_file)
            user_data_types: Dict[str, int] = {}
            source_file = str(user_file.relative_to(users_dir.parent))

            for index, record in enumerate(records, start=1):
                row, stats = flatten_record(
                    personal_id=personal_id,
                    subject_id=subject_id,
                    record_index=index,
                    record=record,
                    source_file=source_file,
                    include_personal_id=include_personal_id,
                )
                writer.writerow(row)
                totals["rawRecords"] += 1
                for key in (
                    "nonObjectRecords",
                    "numericRecords",
                    "nonNumericRecords",
                    "recordsWithDateFrom",
                ):
                    totals[key] += stats[key]
                data_type = row.get("data_type") or ""
                if data_type:
                    totals["dataTypes"][data_type] = totals["dataTypes"].get(data_type, 0) + 1
                    user_data_types[data_type] = user_data_types.get(data_type, 0) + 1

            totals["users"].append(
                {
                    "subject_id": subject_id,
                    "source_file": source_file,
                    "rawRecords": len(records),
                    "dataTypes": dict(sorted(user_data_types.items())),
                }
            )

    totals["dataTypes"] = dict(sorted(totals["dataTypes"].items()))
    return totals


def parquet_available() -> bool:
    try:
        import pyarrow  # noqa: F401
    except ImportError:
        return False
    return True


def write_parquet_from_csv_gz(
    csv_path: Path,
    parquet_path: Path,
    parquet_mode: str,
    warnings: List[str],
) -> Optional[Path]:
    if parquet_mode == "skip":
        return None
    if not parquet_available():
        message = (
            f"Skipped Parquet for {csv_path.name}: pyarrow is not installed. "
            "Install pyarrow or rerun with --parquet skip."
        )
        if parquet_mode == "require":
            raise SystemExit(message)
        warnings.append(message)
        return None

    import pyarrow as pa
    import pyarrow.csv as pa_csv
    import pyarrow.parquet as pq

    parquet_path.parent.mkdir(parents=True, exist_ok=True)
    with pa.input_stream(str(csv_path), compression="gzip") as source:
        reader = pa_csv.open_csv(source, read_options=pa_csv.ReadOptions(block_size=1 << 20))
        writer = None
        try:
            for batch in reader:
                table = pa.Table.from_batches([batch])
                if writer is None:
                    writer = pq.ParquetWriter(parquet_path, table.schema)
                writer.write_table(table)
        finally:
            if writer is not None:
                writer.close()
    return parquet_path


def rewrite_csv_with_subjects(
    *,
    input_csv: Path,
    output_csv_gz: Path,
    subject_map: Dict[str, str],
    include_personal_id: bool,
    personal_id_col: str = "personalId",
    sensitive_copy: Optional[Path] = None,
) -> Dict[str, int]:
    rows = 0
    missing_subjects = 0

    with input_csv.open("r", encoding="utf-8", newline="") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames is None:
            raise SystemExit(f"{input_csv} has no header row.")

        original_fields = list(reader.fieldnames)
        if sensitive_copy is not None:
            sensitive_copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(input_csv, sensitive_copy)

        output_fields = ["subject_id"]
        for field in original_fields:
            if field == "subject_id":
                continue
            if field == personal_id_col and not include_personal_id:
                continue
            output_fields.append(field)

        with open_csv_gz(output_csv_gz) as destination:
            writer = csv.DictWriter(destination, fieldnames=output_fields)
            writer.writeheader()
            for row in reader:
                personal_id = row.get(personal_id_col, "")
                subject_id = subject_map.get(personal_id)
                if subject_id is None:
                    missing_subjects += 1
                    subject_id = row.get("subject_id", "")

                output_row: Dict[str, Any] = {"subject_id": subject_id}
                for field in original_fields:
                    if field == "subject_id":
                        continue
                    if field == personal_id_col and not include_personal_id:
                        continue
                    output_row[field] = row.get(field, "")
                writer.writerow(output_row)
                rows += 1

    return {"rows": rows, "missingSubjectMappings": missing_subjects}


def run_daily_health_transform(
    *,
    raw_data_dir: Path,
    users_dir: Path,
    output_root: Path,
    subject_map: Dict[str, str],
    bucket_minutes: int,
    exact_interval: bool,
    include_personal_id: bool,
    parquet_mode: str,
    warnings: List[str],
) -> Dict[str, Any]:
    transform_dir = output_root / "export_logs" / "daily_health_records_transform"
    transform_dir.mkdir(parents=True, exist_ok=True)
    files = daily_transform.user_files(users_dir, limit=None)
    manifest = daily_transform.write_csv_and_manifest(
        raw_data_dir,
        users_dir,
        transform_dir,
        files,
        bucket_minutes,
        exact_interval,
        data_type_filter=None,
        decimal_places=6,
    )

    output_csv_gz = output_root / "derived" / "daily_health_records.csv.gz"
    rewrite_stats = rewrite_csv_with_subjects(
        input_csv=transform_dir / "daily_health_records.csv",
        output_csv_gz=output_csv_gz,
        subject_map=subject_map,
        include_personal_id=include_personal_id,
    )
    parquet_path = write_parquet_from_csv_gz(
        output_csv_gz,
        output_root / "derived" / "daily_health_records.parquet",
        parquet_mode,
        warnings,
    )
    return {
        "csv": str(output_csv_gz.relative_to(output_root)),
        "parquet": str(parquet_path.relative_to(output_root)) if parquet_path else None,
        "transformManifest": str((transform_dir / "manifest.json").relative_to(output_root)),
        "rewrite": rewrite_stats,
        "sourceManifest": manifest,
    }


def run_alignment(
    *,
    args: argparse.Namespace,
    output_root: Path,
    subject_map: Dict[str, str],
    include_personal_id: bool,
    parquet_mode: str,
    warnings: List[str],
) -> Optional[Dict[str, Any]]:
    if args.skip_alignment:
        warnings.append("Skipped clinical alignment because --skip-alignment was set.")
        return None
    if not args.keys or not args.clinical:
        warnings.append("Skipped clinical alignment because --keys and --clinical were not both provided.")
        return None

    aligned_dir = output_root / "export_logs" / "clinical_alignment_transform"
    aligned_dir.mkdir(parents=True, exist_ok=True)
    command = [
        args.rscript,
        str(Path("data_analysis/scripts/01_build_aligned_dataset.R")),
        "--health-records",
        str(output_root / "export_logs" / "daily_health_records_transform" / "daily_health_records.csv"),
        "--keys",
        str(args.keys),
        "--clinical",
        str(args.clinical),
        "--output-dir",
        str(aligned_dir),
        "--clinical-sheet",
        args.clinical_sheet,
        "--clinical-key-col",
        args.clinical_key_col,
        "--clinical-heartattack-date-col",
        args.clinical_heartattack_date_col,
        "--clinical-heartattack-type-col",
        args.clinical_heartattack_type_col,
        "--clinical-physio-sheet",
        args.clinical_physio_sheet,
        "--clinical-physio-key-col",
        args.clinical_physio_key_col,
        "--clinical-physio-value-cols",
        args.clinical_physio_value_cols,
    ]
    if args.window_before is not None:
        command.extend(["--window-before", str(args.window_before)])
    if args.window_after is not None:
        command.extend(["--window-after", str(args.window_after)])

    completed = subprocess.run(
        command,
        cwd=Path(__file__).resolve().parents[1],
        text=True,
        capture_output=True,
        check=False,
    )
    (aligned_dir / "alignment_stdout.log").write_text(completed.stdout, encoding="utf-8")
    (aligned_dir / "alignment_stderr.log").write_text(completed.stderr, encoding="utf-8")
    if completed.returncode != 0:
        raise SystemExit(
            "Clinical alignment failed. See "
            f"{aligned_dir / 'alignment_stderr.log'}"
        )

    outputs = {}
    for filename in (
        "subject_index.csv",
        "health_records_aligned.csv",
        "daily_features_aligned.csv",
    ):
        input_csv = aligned_dir / filename
        output_csv_gz = output_root / "derived" / f"{filename}.gz"
        sensitive_copy = None
        if filename == "subject_index.csv":
            sensitive_copy = output_root / "keys_sensitive_separate" / "clinical_subject_index.csv"
        stats = rewrite_csv_with_subjects(
            input_csv=input_csv,
            output_csv_gz=output_csv_gz,
            subject_map=subject_map,
            include_personal_id=include_personal_id,
            sensitive_copy=sensitive_copy,
        )
        parquet_path = write_parquet_from_csv_gz(
            output_csv_gz,
            output_root / "derived" / f"{filename.removesuffix('.csv')}.parquet",
            parquet_mode,
            warnings,
        )
        outputs[filename] = {
            "csv": str(output_csv_gz.relative_to(output_root)),
            "parquet": str(parquet_path.relative_to(output_root)) if parquet_path else None,
            "rewrite": stats,
        }

    return {
        "command": command,
        "outputDir": str(aligned_dir.relative_to(output_root)),
        "outputs": outputs,
    }


def write_data_dictionary(path: Path, include_personal_id: bool) -> None:
    rows = [
        ("raw/health_records", "subject_id", "Export pseudonym for the participant."),
        ("raw/health_records", "record_id", "Stable row id within this export."),
        ("raw/health_records", "record_index", "One-based index in the source user JSON file."),
        ("raw/health_records", "data_type", "HealthKit/health plugin data type."),
        ("raw/health_records", "unit", "Health value unit."),
        ("raw/health_records", "numeric_value", "Numeric value when value.numericValue exists."),
        ("raw/health_records", "value_json", "Original value object as compact JSON."),
        ("raw/health_records", "date_from", "Source interval start timestamp."),
        ("raw/health_records", "date_to", "Source interval end timestamp."),
        ("raw/health_records", "date", "Date component from date_from."),
        ("raw/health_records", "platform_type", "ios/android platform marker from the app payload."),
        ("raw/health_records", "device_id", "Source device id from the app payload."),
        ("raw/health_records", "source_id", "Source app id from the app payload."),
        ("raw/health_records", "source_name", "Source app/device name from the app payload."),
        ("raw/health_records", "source_file", "Relative source JSON file in the raw download."),
        ("derived/daily_health_records", "value", "Daily aggregated numeric health value."),
        ("derived/daily_health_records", "aggregation", "sum for STEPS, mean for other numeric types."),
        ("derived/daily_health_records", "buckets", "Number of deduped source buckets for the day."),
        ("derived/daily_health_records", "sourceRecords", "Raw source records contributing to the row."),
        ("derived/daily_health_records", "collapsedDuplicateRecords", "Records collapsed during source/device dedupe."),
        ("keys_sensitive_separate/personal_id_map", "personalId", "Direct participant identifier. Keep separate from main analysis files."),
    ]
    if include_personal_id:
        rows.append(("main exports", "personalId", "Direct participant identifier included by explicit request."))

    with path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=["file", "column", "description"])
        writer.writeheader()
        for file_name, column, description in rows:
            writer.writerow(
                {"file": file_name, "column": column, "description": description}
            )


def git_commit() -> Optional[str]:
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=Path(__file__).resolve().parents[1],
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError:
        return None
    return completed.stdout.strip() if completed.returncode == 0 else None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_checksums(output_root: Path) -> None:
    checksum_path = output_root / "checksums.sha256"
    files = sorted(
        path
        for path in output_root.rglob("*")
        if path.is_file() and path != checksum_path
    )
    with checksum_path.open("w", encoding="utf-8") as file:
        for path in files:
            file.write(f"{file_sha256(path)}  {path.relative_to(output_root)}\n")


def write_readme(path: Path, manifest: Dict[str, Any]) -> None:
    lines = [
        "# Swedeheart Full Export",
        "",
        f"Created: {manifest['createdAt']}",
        f"Git commit: {manifest.get('gitCommit') or 'unknown'}",
        "",
        "## Main Files",
        "",
        "- `raw/health_records.csv.gz`: one row per raw health record in tidy long format.",
        "- `derived/daily_health_records.csv.gz`: one row per subject/date/data type after dedupe and daily aggregation.",
        "- `derived/*_aligned.csv.gz`: optional clinical-aligned files when key and clinical files were provided.",
        "- `keys_sensitive_separate/personal_id_map.csv`: direct identifier mapping. Keep separate from statistician-facing analysis data unless explicitly approved.",
        "- `manifest.json`: export provenance, counts, warnings, and generated file references.",
        "- `checksums.sha256`: file integrity hashes.",
        "- `data_dictionary.csv`: column-level descriptions.",
        "",
        "## Privacy",
        "",
        "Main exports use `subject_id` by default. Direct identifiers are isolated in `keys_sensitive_separate/` unless the export was run with `--include-personal-id-in-main`.",
        "",
        "## Notes",
        "",
        "Parquet files are generated only when `pyarrow` is available or when `--parquet require` is used.",
        "",
        "## Remote Clinical Alignment",
        "",
        "If key and clinical files only exist on a secure R-only analysis machine, prepare this export locally with `--skip-alignment`, copy the export folder to the remote machine, then run:",
        "",
        "```sh",
        "Rscript /path/to/this/export/remote_scripts/02_align_full_export.R \\",
        "  --export-dir /path/to/this/export \\",
        "  --keys /path/to/pnrkey_DAT-1261.xlsx \\",
        "  --clinical /path/to/health_information.xlsx \\",
        "  --window-before 365 \\",
        "  --window-after 365",
        "```",
    ]
    if manifest.get("warnings"):
        lines.extend(["", "## Warnings", ""])
        lines.extend(f"- {warning}" for warning in manifest["warnings"])
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def copy_metadata_dir(source: Optional[Path], output_root: Path) -> Optional[str]:
    if source is None:
        return None
    if not source.is_dir():
        raise SystemExit(f"--metadata-dir is not a directory: {source}")
    destination = output_root / "metadata" / "pocketbase_collections"
    shutil.copytree(source, destination)
    return str(destination.relative_to(output_root))


def copy_original_json(files: List[Path], output_root: Path) -> Optional[str]:
    destination = output_root / "raw" / "original_user_json"
    destination.mkdir(parents=True, exist_ok=True)
    for path in files:
        shutil.copy2(path, destination / path.name)
    return str(destination.relative_to(output_root))


def copy_remote_alignment_scripts(output_root: Path) -> List[str]:
    repo_root = Path(__file__).resolve().parents[1]
    source_paths = [
        repo_root / "data_analysis" / "scripts" / "01_build_aligned_dataset.R",
        repo_root / "data_analysis" / "scripts" / "02_align_full_export.R",
    ]
    destination = output_root / "remote_scripts"
    destination.mkdir(parents=True, exist_ok=True)

    copied = []
    for source_path in source_paths:
        if not source_path.is_file():
            raise SystemExit(f"Missing remote alignment script: {source_path}")
        target_path = destination / source_path.name
        shutil.copy2(source_path, target_path)
        copied.append(str(target_path.relative_to(output_root)))
    return copied


def main() -> int:
    args = parse_args()
    normalize_paths(args)
    users_dir = resolve_users_dir(args.raw_data_dir)
    files = user_files(users_dir)
    ensure_output_root(args.output_dir, args.allow_existing)

    for dirname in ("raw", "derived", "metadata", "keys_sensitive_separate", "export_logs"):
        (args.output_dir / dirname).mkdir(parents=True, exist_ok=True)

    warnings: List[str] = []
    subject_map = build_subject_map(files)
    write_personal_id_map(
        args.output_dir / "keys_sensitive_separate" / "personal_id_map.csv",
        files,
        subject_map,
        users_dir,
    )

    raw_csv_gz = args.output_dir / "raw" / "health_records.csv.gz"
    raw_summary = write_raw_health_records(
        output_path=raw_csv_gz,
        files=files,
        users_dir=users_dir,
        subject_map=subject_map,
        include_personal_id=args.include_personal_id_in_main,
    )
    raw_parquet = write_parquet_from_csv_gz(
        raw_csv_gz,
        args.output_dir / "raw" / "health_records.parquet",
        args.parquet,
        warnings,
    )

    daily_summary = None
    if args.skip_daily_health_records:
        warnings.append("Skipped daily_health_records because --skip-daily-health-records was set.")
    else:
        daily_summary = run_daily_health_transform(
            raw_data_dir=args.raw_data_dir,
            users_dir=users_dir,
            output_root=args.output_dir,
            subject_map=subject_map,
            bucket_minutes=args.bucket_minutes,
            exact_interval=args.exact_interval,
            include_personal_id=args.include_personal_id_in_main,
            parquet_mode=args.parquet,
            warnings=warnings,
        )

    alignment_summary = None
    if args.keys or args.clinical or not args.skip_alignment:
        if daily_summary is None and not args.skip_alignment:
            warnings.append("Skipped clinical alignment because daily_health_records was not generated.")
        else:
            alignment_summary = run_alignment(
                args=args,
                output_root=args.output_dir,
                subject_map=subject_map,
                include_personal_id=args.include_personal_id_in_main,
                parquet_mode=args.parquet,
                warnings=warnings,
            )

    metadata_copy = copy_metadata_dir(args.metadata_dir, args.output_dir)
    original_json_copy = copy_original_json(files, args.output_dir) if args.include_original_json else None
    remote_alignment_scripts = copy_remote_alignment_scripts(args.output_dir)
    write_data_dictionary(
        args.output_dir / "data_dictionary.csv",
        include_personal_id=args.include_personal_id_in_main,
    )

    manifest = {
        "createdAt": utc_now(),
        "gitCommit": git_commit(),
        "rawDataDir": str(args.raw_data_dir),
        "usersDir": str(users_dir),
        "outputDir": str(args.output_dir),
        "includePersonalIdInMain": args.include_personal_id_in_main,
        "parquetMode": args.parquet,
        "warnings": warnings,
        "rawHealthRecords": {
            "csv": str(raw_csv_gz.relative_to(args.output_dir)),
            "parquet": str(raw_parquet.relative_to(args.output_dir)) if raw_parquet else None,
            "summary": raw_summary,
        },
        "dailyHealthRecords": daily_summary,
        "clinicalAlignment": alignment_summary,
        "metadataCopy": metadata_copy,
        "originalUserJsonCopy": original_json_copy,
        "remoteAlignmentScripts": remote_alignment_scripts,
    }

    (args.output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    write_readme(args.output_dir / "README.md", manifest)
    write_checksums(args.output_dir)

    print(f"Wrote full export to {args.output_dir}")
    print(f"Raw records: {raw_summary['rawRecords']} across {raw_summary['userCount']} users")
    if warnings:
        print("Warnings:")
        for warning in warnings:
            print(f"  - {warning}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
