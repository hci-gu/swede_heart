#!/usr/bin/env python3
"""Export PocketBase metadata collections for a Swedeheart handoff.

This script contacts the configured PocketBase instance. It is intentionally
separate from build_full_export.py so the full export can be built and tested
from local raw downloads without touching production.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


DEFAULT_BASE_URL = "https://swedeheart-api.prod.appadem.in"
DEFAULT_COLLECTIONS = [
    "users",
    "dataUploads",
    "info",
    "questionnaires",
    "questions",
    "questionOptions",
    "answers",
]
DEFAULT_USER_FIELDS = "id,username,created,updated,app_type,consent"


class RequestError(Exception):
    pass


def env_first(*names: str) -> Optional[str]:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export PocketBase records as JSONL and flattened CSV files."
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        required=True,
        help="Directory for exported collection files.",
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("SWEDEHEART_API_BASE_URL", DEFAULT_BASE_URL),
    )
    parser.add_argument(
        "--admin-identity",
        default=env_first(
            "SWEDEHEART_POCKETBASE_ADMIN_IDENTITY",
            "POCKETBASE_ADMIN_IDENTITY",
            "PB_ADMIN_IDENTITY",
        ),
    )
    parser.add_argument(
        "--admin-password",
        default=env_first(
            "SWEDEHEART_POCKETBASE_ADMIN_PASSWORD",
            "POCKETBASE_ADMIN_PASSWORD",
            "PB_ADMIN_PASSWORD",
        ),
    )
    parser.add_argument(
        "--collection",
        action="append",
        dest="collections",
        help="Collection to export. Can be passed multiple times.",
    )
    parser.add_argument("--page-size", type=int, default=200)
    parser.add_argument(
        "--users-fields",
        default=DEFAULT_USER_FIELDS,
        help="Field list for users export. Defaults to non-password metadata fields.",
    )
    return parser.parse_args()


def request_json(
    url: str,
    *,
    method: str = "GET",
    body: Optional[Dict[str, Any]] = None,
    headers: Optional[Dict[str, str]] = None,
) -> Any:
    request_headers = dict(headers or {})
    request_body = None
    if body is not None:
        request_body = json.dumps(body, separators=(",", ":")).encode("utf-8")
        request_headers["Content-Type"] = "application/json"

    request = urllib.request.Request(
        url,
        data=request_body,
        headers=request_headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            raw = response.read()
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", errors="replace").strip()
        raise RequestError(f"HTTP {err.code}: {url}: {detail}") from err
    except urllib.error.URLError as err:
        raise RequestError(f"{url}: {err.reason}") from err

    try:
        return json.loads(raw)
    except json.JSONDecodeError as err:
        raise RequestError(f"Invalid JSON from {url}: {err}") from err


def authenticate(base_url: str, identity: str, password: str) -> str:
    data = request_json(
        f"{base_url.rstrip('/')}/api/admins/auth-with-password",
        method="POST",
        body={"identity": identity, "password": password},
    )
    token = data.get("token") if isinstance(data, dict) else None
    if not token:
        raise SystemExit("PocketBase admin authentication did not return a token.")
    return str(token)


def fetch_collection(
    *,
    base_url: str,
    token: str,
    collection: str,
    page_size: int,
    fields: Optional[str],
) -> List[Dict[str, Any]]:
    if page_size < 1:
        raise SystemExit("--page-size must be at least 1")

    records: List[Dict[str, Any]] = []
    page = 1
    while True:
        params = {
            "page": str(page),
            "perPage": str(page_size),
            "sort": "created",
        }
        if fields:
            params["fields"] = fields
        query = urllib.parse.urlencode(params)
        url = f"{base_url.rstrip('/')}/api/collections/{urllib.parse.quote(collection)}/records?{query}"
        response = request_json(
            url,
            headers={"Authorization": f"Bearer {token}"},
        )
        items = response.get("items") if isinstance(response, dict) else None
        if not isinstance(items, list):
            raise RequestError(f"{collection} response did not contain items.")
        records.extend(item for item in items if isinstance(item, dict))
        total_pages = int(response.get("totalPages") or 1)
        if page >= total_pages:
            break
        page += 1
    return records


def csv_value(value: Any) -> str:
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    if value is None:
        return ""
    return str(value)


def fieldnames(records: Iterable[Dict[str, Any]]) -> List[str]:
    seen = []
    known = set()
    for record in records:
        for key in record:
            if key not in known:
                known.add(key)
                seen.append(key)
    for preferred in reversed(["id", "created", "updated"]):
        if preferred in known:
            seen.remove(preferred)
            seen.insert(0, preferred)
    return seen


def write_collection(output_dir: Path, collection: str, records: List[Dict[str, Any]]) -> Dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    jsonl_path = output_dir / f"{collection}.jsonl"
    csv_path = output_dir / f"{collection}.csv"

    with jsonl_path.open("w", encoding="utf-8") as file:
        for record in records:
            file.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")

    fields = fieldnames(records)
    with csv_path.open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for record in records:
            writer.writerow({field: csv_value(record.get(field)) for field in fields})

    return {
        "collection": collection,
        "records": len(records),
        "jsonl": str(jsonl_path.relative_to(output_dir)),
        "csv": str(csv_path.relative_to(output_dir)),
        "fields": fields,
    }


def main() -> int:
    args = parse_args()
    if not args.admin_identity or not args.admin_password:
        raise SystemExit(
            "Missing PocketBase admin credentials. Set "
            "SWEDEHEART_POCKETBASE_ADMIN_IDENTITY and "
            "SWEDEHEART_POCKETBASE_ADMIN_PASSWORD or pass --admin-identity and "
            "--admin-password."
        )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(args.output_dir, 0o700)
    token = authenticate(args.base_url, args.admin_identity, args.admin_password)
    collections = args.collections or DEFAULT_COLLECTIONS
    summaries = []
    for collection in collections:
        fields = args.users_fields if collection == "users" else None
        records = fetch_collection(
            base_url=args.base_url,
            token=token,
            collection=collection,
            page_size=args.page_size,
            fields=fields,
        )
        summaries.append(write_collection(args.output_dir, collection, records))
        print(f"Exported {len(records)} {collection} records")

    manifest = {
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "baseUrl": args.base_url.rstrip("/"),
        "collections": summaries,
    }
    (args.output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
