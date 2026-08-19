#!/usr/bin/env python3
"""Replay downloaded health data as concurrent fake users."""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import math
import os
import re
import secrets
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


DEFAULT_BASE_URL = "http://127.0.0.1:8080"
PROD_HOST = "swedeheart-api.prod.appadem.in"
PERSONAL_ID_RE = re.compile(r"^[A-Za-z0-9-]+$")


@dataclass
class RequestResult:
    status: int
    seconds: float
    request_bytes: int
    compressed_bytes: int
    error: str = ""


@dataclass
class ChunkResult:
    level: int
    personal_id: str
    chunk_index: int
    records: int
    status: int
    seconds: float
    request_bytes: int
    compressed_bytes: int
    error: str


@dataclass
class UserResult:
    personal_id: str
    seconds: float
    chunks: List[ChunkResult]

    @property
    def ok(self) -> bool:
        return all(not chunk.error and 200 <= chunk.status < 300 for chunk in self.chunks)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stress-test /users and /data by replaying one downloaded JSON dataset."
    )
    parser.add_argument("data", type=Path, help="Downloaded JSON data file to replay.")
    parser.add_argument(
        "--base-url",
        default=os.environ.get("SWEDEHEART_STRESS_BASE_URL", DEFAULT_BASE_URL),
        help=f"API base URL. Defaults to {DEFAULT_BASE_URL}.",
    )
    parser.add_argument(
        "--concurrency",
        default="1,5,10",
        help="Comma-separated concurrent user counts. Defaults to 1,5,10.",
    )
    parser.add_argument(
        "--chunks",
        type=int,
        default=10,
        help="Chunks per fake user upload. Defaults to 10, matching the app.",
    )
    parser.add_argument(
        "--prefix",
        help="Fake personalId prefix. Defaults to stress-<timestamp>.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="CSV output path. Defaults to stress-results/upload-<timestamp>.csv.",
    )
    parser.add_argument("--timeout", type=float, default=120, help="HTTP timeout seconds.")
    parser.add_argument(
        "--allow-production",
        action="store_true",
        help="Required when --base-url points at the known production host.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Load and chunk the data, then print the plan without uploading.",
    )
    return parser.parse_args()


def parse_levels(raw: str) -> List[int]:
    levels = []
    for value in raw.split(","):
        value = value.strip()
        if not value:
            continue
        level = int(value)
        if level < 1:
            raise ValueError("concurrency values must be >= 1")
        levels.append(level)
    if not levels:
        raise ValueError("at least one concurrency value is required")
    return levels


def timestamp() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def default_output_path() -> Path:
    return Path("stress-results") / f"upload-{timestamp()}.csv"


def require_safe_target(base_url: str, allow_production: bool) -> None:
    host = urllib.parse.urlparse(base_url).hostname or ""
    if host == PROD_HOST and not allow_production:
        raise SystemExit(
            f"Refusing to stress test {PROD_HOST} without --allow-production."
        )


def load_data(path: Path) -> List[Dict[str, Any]]:
    with path.open("r", encoding="utf-8") as file:
        data = json.load(file)
    if not isinstance(data, list):
        raise SystemExit("Expected the downloaded data file to contain a JSON array.")
    return data


def split_chunks(data: List[Dict[str, Any]], chunk_count: int) -> List[List[Dict[str, Any]]]:
    if chunk_count < 1:
        raise SystemExit("--chunks must be at least 1")
    if not data:
        raise SystemExit("The downloaded data file is empty.")
    chunk_size = max(1, math.ceil(len(data) / chunk_count))
    return [data[i : i + chunk_size] for i in range(0, len(data), chunk_size)]


def post_json(
    base_url: str,
    path: str,
    payload: Dict[str, Any],
    timeout: float,
    compress: bool = False,
) -> RequestResult:
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    body = gzip.compress(raw) if compress else raw
    headers = {"Content-Type": "application/json; charset=UTF-8"}
    if compress:
        headers["Content-Encoding"] = "gzip"

    url = f"{base_url.rstrip('/')}{path}"
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")

    started = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response.read()
            seconds = time.perf_counter() - started
            return RequestResult(response.status, seconds, len(raw), len(body))
    except urllib.error.HTTPError as err:
        err.read()
        seconds = time.perf_counter() - started
        return RequestResult(err.code, seconds, len(raw), len(body), f"HTTP {err.code}")
    except urllib.error.URLError as err:
        seconds = time.perf_counter() - started
        return RequestResult(0, seconds, len(raw), len(body), str(err.reason))


def register_user(base_url: str, personal_id: str, timeout: float) -> RequestResult:
    return post_json(
        base_url,
        "/users",
        {
            "personalId": personal_id,
            "password": secrets.token_urlsafe(24),
            "consent": True,
        },
        timeout,
    )


def upload_user(
    level: int,
    base_url: str,
    personal_id: str,
    chunks: List[List[Dict[str, Any]]],
    timeout: float,
) -> UserResult:
    started = time.perf_counter()
    chunk_results = []

    for index, chunk in enumerate(chunks):
        result = post_json(
            base_url,
            "/data",
            {"personalId": personal_id, "chunkIndex": index, "data": chunk},
            timeout,
            compress=True,
        )
        chunk_results.append(
            ChunkResult(
                level=level,
                personal_id=personal_id,
                chunk_index=index,
                records=len(chunk),
                status=result.status,
                seconds=result.seconds,
                request_bytes=result.request_bytes,
                compressed_bytes=result.compressed_bytes,
                error=result.error,
            )
        )
        if result.error:
            break

    return UserResult(personal_id, time.perf_counter() - started, chunk_results)


def percentile(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((p / 100) * len(ordered)) - 1))
    return ordered[index]


def print_summary(level: int, wall_seconds: float, results: List[UserResult]) -> None:
    chunk_seconds = [chunk.seconds for user in results for chunk in user.chunks]
    user_seconds = [user.seconds for user in results]
    uploaded_records = sum(chunk.records for user in results for chunk in user.chunks)
    ok_users = sum(1 for user in results if user.ok)

    print(
        f"{level:>3} users | wall {wall_seconds:>7.2f}s | "
        f"ok {ok_users}/{len(results)} | "
        f"user avg/max {statistics.mean(user_seconds):.2f}/{max(user_seconds):.2f}s | "
        f"chunk p50/p95/max {percentile(chunk_seconds, 50):.2f}/"
        f"{percentile(chunk_seconds, 95):.2f}/{max(chunk_seconds):.2f}s | "
        f"{uploaded_records / wall_seconds:.0f} records/s"
    )

    failures = [
        chunk
        for user in results
        for chunk in user.chunks
        if chunk.error or not (200 <= chunk.status < 300)
    ]
    if failures:
        first = failures[0]
        print(
            f"    first failure: {first.personal_id} chunk {first.chunk_index} "
            f"status={first.status} error={first.error}"
        )


def write_csv(path: Path, rows: Iterable[ChunkResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(
            [
                "level",
                "personal_id",
                "chunk_index",
                "records",
                "status",
                "seconds",
                "request_bytes",
                "compressed_bytes",
                "error",
            ]
        )
        for row in rows:
            writer.writerow(
                [
                    row.level,
                    row.personal_id,
                    row.chunk_index,
                    row.records,
                    row.status,
                    f"{row.seconds:.6f}",
                    row.request_bytes,
                    row.compressed_bytes,
                    row.error,
                ]
            )


def make_personal_ids(prefix: str, level: int) -> List[str]:
    personal_ids = [
        f"{prefix}-{level:03d}-{index:03d}" for index in range(1, level + 1)
    ]
    invalid = [personal_id for personal_id in personal_ids if not PERSONAL_ID_RE.match(personal_id)]
    if invalid:
        raise SystemExit(
            "Fake personalIds may only contain letters, numbers, and hyphens. "
            f"Invalid example: {invalid[0]}"
        )
    return personal_ids


def run_level(
    level: int,
    base_url: str,
    prefix: str,
    chunks: List[List[Dict[str, Any]]],
    timeout: float,
) -> Tuple[float, List[UserResult]]:
    personal_ids = make_personal_ids(prefix, level)

    for personal_id in personal_ids:
        result = register_user(base_url, personal_id, timeout)
        if result.error or not (200 <= result.status < 300):
            raise SystemExit(
                f"Failed to register {personal_id}: status={result.status} {result.error}"
            )

    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=level) as executor:
        futures = [
            executor.submit(upload_user, level, base_url, personal_id, chunks, timeout)
            for personal_id in personal_ids
        ]
        results = [future.result() for future in as_completed(futures)]
    return time.perf_counter() - started, sorted(results, key=lambda result: result.personal_id)


def main() -> int:
    args = parse_args()
    levels = parse_levels(args.concurrency)
    require_safe_target(args.base_url, args.allow_production)
    prefix = args.prefix or f"stress-{timestamp()}"
    for level in levels:
        make_personal_ids(prefix, level)

    data = load_data(args.data)
    chunks = split_chunks(data, args.chunks)
    output = args.output or default_output_path()

    print(
        f"Loaded {len(data)} records from {args.data}; "
        f"{len(chunks)} chunks/user; levels={','.join(map(str, levels))}; "
        f"target={args.base_url}"
    )

    if args.dry_run:
        print("Dry run only; no users registered and no data uploaded.")
        return 0

    all_chunks = []
    for level in levels:
        wall_seconds, results = run_level(level, args.base_url, prefix, chunks, args.timeout)
        print_summary(level, wall_seconds, results)
        all_chunks.extend(chunk for user in results for chunk in user.chunks)

    write_csv(output, all_chunks)
    print(f"Wrote detailed timings to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
