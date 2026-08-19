#!/usr/bin/env python3
"""Download one user's raw health data from the production API."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


DEFAULT_BASE_URL = "https://swedeheart-api.prod.appadem.in"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download raw health data from the Swedeheart production API."
    )
    parser.add_argument("personal_id", help="Personal ID to download data for")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output JSON path. Defaults to prod-data/download-<timestamp>.json",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("SWEDEHEART_API_BASE_URL", DEFAULT_BASE_URL),
        help=f"API base URL. Defaults to {DEFAULT_BASE_URL}",
    )
    return parser.parse_args()


def get_api_key() -> str:
    api_key = os.environ.get("SWEDEHEART_API_KEY") or os.environ.get("API_KEY")
    if not api_key:
        raise SystemExit(
            "Missing API key. Set SWEDEHEART_API_KEY or API_KEY in your environment."
        )
    return api_key


def default_output_path() -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return Path("prod-data") / f"download-{timestamp}.json"


def download_data(base_url: str, personal_id: str, api_key: str) -> bytes:
    encoded_id = urllib.parse.quote(personal_id, safe="")
    url = f"{base_url.rstrip('/')}/data/{encoded_id}"
    request = urllib.request.Request(url, headers={"X-API-Key": api_key})

    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", errors="replace").strip()
        detail = f": {body}" if body else ""
        raise SystemExit(f"Download failed with HTTP {err.code}{detail}") from err
    except urllib.error.URLError as err:
        raise SystemExit(f"Download failed: {err.reason}") from err


def write_private_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        json.dump(data, file, indent=2, ensure_ascii=False)
        file.write("\n")


def main() -> int:
    args = parse_args()
    output_path = args.output or default_output_path()
    raw = download_data(args.base_url, args.personal_id, get_api_key())

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as err:
        raise SystemExit(f"API returned invalid JSON: {err}") from err

    write_private_json(output_path, data)
    count = len(data) if isinstance(data, list) else "unknown"
    print(f"Downloaded {count} records to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
