#!/usr/bin/env python3
"""Download raw health data for Swedeheart users.

The script discovers PocketBase users with admin credentials, downloads each
user's raw health payload through GET /data/:personalId, and writes one JSON
file per user.

Quick smoke-test knob:
    Pass --limit 1-5 while testing, or omit --limit / pass --limit 0 for all users.

Resume:
    Re-run with the same --output-dir. Existing user JSON files listed in
    manifest.json are skipped with a cheap file-exists check by default. Pass
    --verify-existing to fully parse existing JSON files before skipping.
    Pass --refresh-user-list to discover users again and append newly registered
    users to personal_ids.json.
    Pass --start-at N to begin processing at a 1-based position in
    personal_ids.json without checking earlier entries.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Deque, Dict, Iterable, List, Optional, Tuple


DEFAULT_BASE_URL = "https://swedeheart-api.prod.appadem.in"
DEFAULT_OUTPUT_ROOT = Path("/Volumes/T7/Sebastians data/sahlgrenska-apps/swedeheart")
DEFAULT_DISCOVERY_PAGE_SIZE = 25
DEFAULT_TIMEOUT_SECONDS = 120.0
ETA_SAMPLE_SIZE = 5
DEFAULT_MANIFEST_SAVE_INTERVAL = 50
# Set to 1-5 for smoke tests. Set to None or 0 to download every user.
DEFAULT_USER_LIMIT: Optional[int] = None
PERSONAL_ID_RE = re.compile(r"^[A-Za-z0-9-]+$")


class RequestError(Exception):
    """Raised when an HTTP request does not return usable JSON."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download raw health records for all Swedeheart users."
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("SWEDEHEART_API_BASE_URL", DEFAULT_BASE_URL),
        help=f"API/PocketBase base URL. Defaults to {DEFAULT_BASE_URL}.",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        help="Output directory. Defaults to prod-data/raw-data/<timestamp>.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_USER_LIMIT,
        help=(
            "Maximum users to download. Use 1-5 for smoke tests, or omit/0 for all. "
            f"Defaults to DEFAULT_USER_LIMIT={DEFAULT_USER_LIMIT!r} in this script."
        ),
    )
    parser.add_argument(
        "--personal-ids",
        type=Path,
        help=(
            "Optional newline-delimited personalId file. When set, user discovery "
            "through PocketBase admin credentials is skipped."
        ),
    )
    parser.add_argument(
        "--refresh-user-list",
        action="store_true",
        help=(
            "Refresh personal_ids.json instead of reusing the existing snapshot. "
            "Existing IDs keep their order and newly discovered IDs are appended."
        ),
    )
    parser.add_argument(
        "--start-at",
        type=int,
        default=1,
        help=(
            "Begin processing at this 1-based index in personal_ids.json. Earlier "
            "entries are left as-is from manifest.json and are not checked. Use "
            "3835 to skip the first 3834 entries."
        ),
    )
    parser.add_argument(
        "--admin-identity",
        default=env_first(
            "SWEDEHEART_POCKETBASE_ADMIN_IDENTITY",
            "POCKETBASE_ADMIN_IDENTITY",
            "PB_ADMIN_IDENTITY",
        ),
        help=(
            "PocketBase admin identity/email. Defaults to "
            "SWEDEHEART_POCKETBASE_ADMIN_IDENTITY, POCKETBASE_ADMIN_IDENTITY, "
            "or PB_ADMIN_IDENTITY."
        ),
    )
    parser.add_argument(
        "--admin-password",
        default=env_first(
            "SWEDEHEART_POCKETBASE_ADMIN_PASSWORD",
            "POCKETBASE_ADMIN_PASSWORD",
            "PB_ADMIN_PASSWORD",
        ),
        help=(
            "PocketBase admin password. Defaults to "
            "SWEDEHEART_POCKETBASE_ADMIN_PASSWORD, POCKETBASE_ADMIN_PASSWORD, "
            "or PB_ADMIN_PASSWORD."
        ),
    )
    parser.add_argument(
        "--page-size",
        type=int,
        default=DEFAULT_DISCOVERY_PAGE_SIZE,
        help=(
            "PocketBase user metadata discovery page size. Raw data is still "
            f"downloaded one user at a time. Defaults to {DEFAULT_DISCOVERY_PAGE_SIZE}."
        ),
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"HTTP timeout in seconds. Defaults to {DEFAULT_TIMEOUT_SECONDS}.",
    )
    parser.add_argument(
        "--verify-existing",
        action="store_true",
        help=(
            "Fully parse existing user JSON files before skipping them. "
            "By default resume trusts manifest.json entries and only checks that "
            "the file exists and is non-empty, which is much faster for large "
            "downloads."
        ),
    )
    parser.add_argument(
        "--manifest-save-interval",
        type=int,
        default=DEFAULT_MANIFEST_SAVE_INTERVAL,
        help=(
            "Save manifest after this many newly validated skipped files. "
            "Downloaded and failed users are still saved immediately. Defaults to "
            f"{DEFAULT_MANIFEST_SAVE_INTERVAL}."
        ),
    )
    return parser.parse_args()


def env_first(*names: str) -> Optional[str]:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def get_api_key() -> str:
    api_key = os.environ.get("SWEDEHEART_API_KEY") or os.environ.get("API_KEY")
    if not api_key:
        raise SystemExit(
            "Missing API key. Set SWEDEHEART_API_KEY or API_KEY in your environment."
        )
    return api_key


def normalize_limit(value: Optional[int]) -> Optional[int]:
    if value is None or value == 0:
        return None
    if value < 0:
        raise SystemExit("--limit must be >= 0")
    return value


def timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def format_duration(seconds: float) -> str:
    seconds = max(0, int(round(seconds)))
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)

    if hours:
        return f"{hours}h {minutes}m"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def time_left_text(recent_download_seconds: Deque[float], remaining_users: int) -> str:
    if remaining_users <= 0:
        return "time left: 0s"
    if not recent_download_seconds:
        return "time left: unknown"

    average_seconds = sum(recent_download_seconds) / len(recent_download_seconds)
    estimate = average_seconds * remaining_users
    sample_count = len(recent_download_seconds)
    suffix = "download" if sample_count == 1 else "downloads"
    return (
        f"time left: ~{format_duration(estimate)} "
        f"based on last {sample_count} {suffix}"
    )


def default_output_dir() -> Path:
    return DEFAULT_OUTPUT_ROOT / timestamp()


def request_json(
    url: str,
    headers: Optional[Dict[str, str]] = None,
    method: str = "GET",
    body: Optional[Dict[str, Any]] = None,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> Any:
    request_body = None
    request_headers = dict(headers or {})

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
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as err:
        detail = read_error_body(err)
        raise RequestError(f"HTTP {err.code}: {url}{detail}") from err
    except urllib.error.URLError as err:
        raise RequestError(f"{url}: {err.reason}") from err

    try:
        return json.loads(raw)
    except json.JSONDecodeError as err:
        raise RequestError(f"Invalid JSON from {url}: {err}") from err


def read_error_body(err: urllib.error.HTTPError) -> str:
    raw = err.read().decode("utf-8", errors="replace").strip()
    if not raw:
        return ""

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return f": {raw}"

    message = data.get("message") if isinstance(data, dict) else None
    return f": {message or raw}"


def authenticate_admin(base_url: str, identity: str, password: str, timeout: float) -> str:
    url = f"{base_url.rstrip('/')}/api/admins/auth-with-password"
    data = request_json(
        url,
        method="POST",
        body={"identity": identity, "password": password},
        timeout=timeout,
    )

    token = data.get("token") if isinstance(data, dict) else None
    if not token:
        raise SystemExit("PocketBase admin authentication did not return a token.")
    return str(token)


def fetch_user_records(
    base_url: str,
    token: str,
    limit: Optional[int],
    page_size: int,
    timeout: float,
) -> List[Dict[str, Any]]:
    if page_size < 1:
        raise SystemExit("--page-size must be at least 1")

    users: List[Dict[str, Any]] = []
    page = 1

    while True:
        remaining = None if limit is None else limit - len(users)
        if remaining is not None and remaining <= 0:
            break

        per_page = page_size if remaining is None else min(page_size, remaining)
        params = urllib.parse.urlencode(
            {
                "fields": "id,username,created,updated,app_type",
                "page": str(page),
                "perPage": str(per_page),
                "sort": "created",
            }
        )
        url = f"{base_url.rstrip('/')}/api/collections/users/records?{params}"
        response = request_json(
            url,
            headers={"Authorization": f"Bearer {token}"},
            timeout=timeout,
        )

        items = response.get("items") if isinstance(response, dict) else None
        if not isinstance(items, list):
            raise SystemExit("PocketBase users response did not contain an items array.")

        users.extend(items)

        total_pages = int(response.get("totalPages") or 1)
        if page >= total_pages:
            break
        page += 1

    return users


def read_personal_ids(path: Path) -> List[str]:
    personal_ids: List[str] = []
    seen = set()

    with path.open("r", encoding="utf-8") as file:
        for line in file:
            personal_id = line.strip()
            if not personal_id or personal_id.startswith("#"):
                continue
            validate_personal_id(personal_id)
            if personal_id not in seen:
                personal_ids.append(personal_id)
                seen.add(personal_id)

    return personal_ids


def personal_ids_from_records(records: Iterable[Dict[str, Any]]) -> List[str]:
    personal_ids: List[str] = []

    for record in records:
        personal_id = record.get("username")
        if not personal_id:
            continue
        personal_id = str(personal_id)
        validate_personal_id(personal_id)
        personal_ids.append(personal_id)

    return personal_ids


def validate_personal_id(personal_id: str) -> None:
    if not PERSONAL_ID_RE.match(personal_id):
        raise SystemExit(f"Invalid personalId from source data: {personal_id!r}")


def discover_personal_ids(args: argparse.Namespace, limit: Optional[int]) -> List[str]:
    if args.personal_ids:
        personal_ids = read_personal_ids(args.personal_ids)
        return personal_ids[:limit] if limit is not None else personal_ids

    if not args.admin_identity or not args.admin_password:
        raise SystemExit(
            "Missing PocketBase admin credentials. Set "
            "SWEDEHEART_POCKETBASE_ADMIN_IDENTITY and "
            "SWEDEHEART_POCKETBASE_ADMIN_PASSWORD, pass --admin-identity and "
            "--admin-password, or provide --personal-ids."
        )

    token = authenticate_admin(
        args.base_url,
        args.admin_identity,
        args.admin_password,
        args.timeout,
    )
    records = fetch_user_records(
        args.base_url,
        token,
        limit,
        args.page_size,
        args.timeout,
    )
    return personal_ids_from_records(records)


def download_raw_data(
    base_url: str,
    personal_id: str,
    api_key: str,
    timeout: float,
) -> List[Dict[str, Any]]:
    encoded_id = urllib.parse.quote(personal_id, safe="")
    url = f"{base_url.rstrip('/')}/data/{encoded_id}"
    data = request_json(
        url,
        headers={"X-API-Key": api_key},
        timeout=timeout,
    )

    if not isinstance(data, list):
        raise RequestError(f"Expected /data/{personal_id} to return a JSON array.")

    return data


def safe_output_name(personal_id: str) -> str:
    validate_personal_id(personal_id)
    return f"{personal_id}.json"


def make_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


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


def read_complete_user_file(path: Path) -> Optional[int]:
    try:
        with path.open("r", encoding="utf-8") as file:
            data = json.load(file)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None

    if not isinstance(data, list):
        return None
    return len(data)


def load_existing_manifest(path: Path) -> Tuple[Optional[str], Dict[str, Dict[str, Any]]]:
    try:
        with path.open("r", encoding="utf-8") as file:
            data = json.load(file)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None, {}

    if not isinstance(data, dict):
        return None, {}

    downloaded_at = data.get("downloadedAt")
    raw_users = data.get("users")
    if not isinstance(raw_users, list):
        return str(downloaded_at) if downloaded_at else None, {}

    users: Dict[str, Dict[str, Any]] = {}
    for raw_user in raw_users:
        if not isinstance(raw_user, dict):
            continue
        personal_id = raw_user.get("personalId")
        if not isinstance(personal_id, str):
            continue
        validate_personal_id(personal_id)
        users[personal_id] = dict(raw_user)

    return str(downloaded_at) if downloaded_at else None, users


def manifest_user_complete(
    output_dir: Path,
    user: Optional[Dict[str, Any]],
) -> Optional[int]:
    if not user or user.get("error"):
        return None

    file_value = user.get("file")
    raw_records = user.get("rawRecords")
    if not file_value:
        return None

    try:
        count = int(raw_records)
    except (TypeError, ValueError):
        return None

    path = output_dir / str(file_value)
    try:
        if path.is_file() and path.stat().st_size > 0:
            return count
    except OSError:
        return None
    return None


def read_personal_id_snapshot(path: Path) -> List[str]:
    try:
        with path.open("r", encoding="utf-8") as file:
            data = json.load(file)
    except (FileNotFoundError, json.JSONDecodeError, OSError) as err:
        raise SystemExit(f"Could not read resume snapshot {path}: {err}") from err

    if not isinstance(data, list):
        raise SystemExit(f"Resume snapshot {path} must contain a JSON array.")

    personal_ids: List[str] = []
    seen = set()
    for value in data:
        personal_id = str(value)
        validate_personal_id(personal_id)
        if personal_id not in seen:
            personal_ids.append(personal_id)
            seen.add(personal_id)
    return personal_ids


def merge_personal_ids(existing: List[str], discovered: List[str]) -> List[str]:
    merged = list(existing)
    seen = set(existing)
    for personal_id in discovered:
        if personal_id not in seen:
            merged.append(personal_id)
            seen.add(personal_id)
    return merged


def validate_start_at(start_at: int, personal_id_count: int) -> None:
    if start_at < 1:
        raise SystemExit("--start-at must be at least 1")
    if start_at > personal_id_count + 1:
        raise SystemExit(
            f"--start-at {start_at} is past the end of the user list "
            f"({personal_id_count} users)."
        )


def build_manifest(
    *,
    downloaded_at: str,
    updated_at: str,
    base_url: str,
    limit: Optional[int],
    personal_ids: List[str],
    users: Dict[str, Dict[str, Any]],
    status: str,
) -> Dict[str, Any]:
    ordered_users = [
        users[personal_id] for personal_id in personal_ids if personal_id in users
    ]
    successful_users = [
        user for user in ordered_users if user.get("file") and not user.get("error")
    ]
    failed_users = [user for user in ordered_users if user.get("error")]

    return {
        "downloadedAt": downloaded_at,
        "updatedAt": updated_at,
        "status": status,
        "baseUrl": base_url.rstrip("/"),
        "userLimit": limit,
        "userCount": len(personal_ids),
        "successfulUsers": len(successful_users),
        "failedUsers": len(failed_users),
        "pendingUsers": len(personal_ids) - len(ordered_users),
        "totalRawRecords": sum(int(user["rawRecords"]) for user in successful_users),
        "users": ordered_users,
    }


def save_manifest(
    output_dir: Path,
    downloaded_at: str,
    base_url: str,
    limit: Optional[int],
    personal_ids: List[str],
    users: Dict[str, Dict[str, Any]],
    status: str,
) -> Dict[str, Any]:
    manifest = build_manifest(
        downloaded_at=downloaded_at,
        updated_at=dt.datetime.now(dt.timezone.utc).isoformat(),
        base_url=base_url,
        limit=limit,
        personal_ids=personal_ids,
        users=users,
        status=status,
    )
    write_private_json(output_dir / "manifest.json", manifest)
    return manifest


def main() -> int:
    args = parse_args()
    limit = normalize_limit(args.limit)
    if args.manifest_save_interval < 1:
        raise SystemExit("--manifest-save-interval must be at least 1")
    output_dir = args.output_dir or default_output_dir()
    users_dir = output_dir / "users"
    make_private_dir(output_dir)
    make_private_dir(users_dir)

    personal_ids_path = output_dir / "personal_ids.json"
    if personal_ids_path.exists() and not args.refresh_user_list:
        personal_ids = read_personal_id_snapshot(personal_ids_path)
        print(f"Resuming {len(personal_ids)} users from {personal_ids_path}", flush=True)
    else:
        existing_personal_ids: List[str] = []
        if personal_ids_path.exists():
            existing_personal_ids = read_personal_id_snapshot(personal_ids_path)
        try:
            discovered_personal_ids = discover_personal_ids(args, limit)
        except RequestError as err:
            raise SystemExit(f"Failed to discover users: {err}") from err
        personal_ids = merge_personal_ids(existing_personal_ids, discovered_personal_ids)
        if existing_personal_ids:
            added = len(personal_ids) - len(existing_personal_ids)
            print(
                f"Refreshed {personal_ids_path}: "
                f"{len(existing_personal_ids)} existing, {added} new, "
                f"{len(personal_ids)} total",
                flush=True,
            )
        write_private_json(personal_ids_path, personal_ids)

    if not personal_ids:
        raise SystemExit("No users found to download.")
    validate_start_at(args.start_at, len(personal_ids))

    manifest_path = output_dir / "manifest.json"
    existing_downloaded_at, users = load_existing_manifest(manifest_path)
    if existing_downloaded_at:
        downloaded_at = existing_downloaded_at
    else:
        downloaded_at = dt.datetime.now(dt.timezone.utc).isoformat()

    api_key: Optional[str] = None
    if not manifest_path.exists():
        save_manifest(
            output_dir,
            downloaded_at,
            args.base_url,
            limit,
            personal_ids,
            users,
            "running",
        )

    try:
        recent_download_seconds: Deque[float] = collections.deque(
            maxlen=ETA_SAMPLE_SIZE
        )
        validated_skips_since_save = 0
        if args.start_at > 1:
            print(
                f"Starting at user index {args.start_at}; "
                f"leaving first {args.start_at - 1} users unchanged from manifest.json",
                flush=True,
            )

        for index, personal_id in enumerate(
            personal_ids[args.start_at - 1 :],
            start=args.start_at,
        ):
            output_path = users_dir / safe_output_name(personal_id)
            if args.verify_existing:
                existing_count = read_complete_user_file(output_path)
            else:
                existing_count = manifest_user_complete(
                    output_dir,
                    users.get(personal_id),
                )
                if existing_count is None:
                    existing_count = read_complete_user_file(output_path)
                    if existing_count is not None:
                        validated_skips_since_save += 1
            remaining_users = len(personal_ids) - index
            if existing_count is not None:
                users[personal_id] = {
                    "personalId": personal_id,
                    "rawRecords": existing_count,
                    "file": str(output_path.relative_to(output_dir)),
                    "status": "skipped",
                }
                eta = time_left_text(recent_download_seconds, remaining_users)
                print(
                    f"[{index}/{len(personal_ids)}] Skipping {personal_id}; "
                    f"already downloaded ({eta})",
                    flush=True,
                )
                if (
                    args.verify_existing
                    or validated_skips_since_save >= args.manifest_save_interval
                ):
                    save_manifest(
                        output_dir,
                        downloaded_at,
                        args.base_url,
                        limit,
                        personal_ids,
                        users,
                        "running",
                    )
                    validated_skips_since_save = 0
                continue

            print(
                f"[{index}/{len(personal_ids)}] Downloading {personal_id} "
                f"({time_left_text(recent_download_seconds, remaining_users + 1)})",
                flush=True,
            )
            if api_key is None:
                api_key = get_api_key()
            started_at = time.monotonic()
            try:
                raw_records = download_raw_data(
                    args.base_url,
                    personal_id,
                    api_key,
                    args.timeout,
                )
            except RequestError as err:
                users[personal_id] = {
                    "personalId": personal_id,
                    "rawRecords": 0,
                    "file": None,
                    "error": str(err),
                    "status": "failed",
                }
                elapsed_seconds = time.monotonic() - started_at
                recent_download_seconds.append(elapsed_seconds)
                print(
                    "  failed "
                    f"after {format_duration(elapsed_seconds)} "
                    f"({time_left_text(recent_download_seconds, remaining_users)}): "
                    f"{err}",
                    file=sys.stderr,
                    flush=True,
                )
                save_manifest(
                    output_dir,
                    downloaded_at,
                    args.base_url,
                    limit,
                    personal_ids,
                    users,
                    "running",
                )
                continue

            write_private_json(output_path, raw_records)
            elapsed_seconds = time.monotonic() - started_at
            recent_download_seconds.append(elapsed_seconds)
            users[personal_id] = {
                "personalId": personal_id,
                "rawRecords": len(raw_records),
                "file": str(output_path.relative_to(output_dir)),
                "status": "downloaded",
            }
            print(
                "  done "
                f"in {format_duration(elapsed_seconds)}; "
                f"{len(raw_records)} records "
                f"({time_left_text(recent_download_seconds, remaining_users)})",
                flush=True,
            )
            save_manifest(
                output_dir,
                downloaded_at,
                args.base_url,
                limit,
                personal_ids,
                users,
                "running",
            )
    except KeyboardInterrupt:
        manifest = save_manifest(
            output_dir,
            downloaded_at,
            args.base_url,
            limit,
            personal_ids,
            users,
            "interrupted",
        )
        print(
            "\nInterrupted. Re-run with the same --output-dir to continue: "
            f"{output_dir}",
            file=sys.stderr,
            flush=True,
        )
        return 130

    manifest = save_manifest(
        output_dir,
        downloaded_at,
        args.base_url,
        limit,
        personal_ids,
        users,
        "complete",
    )
    print(
        "Downloaded "
        f"{manifest['totalRawRecords']} raw records for {len(personal_ids)} users "
        f"to {output_dir} "
        f"({manifest['successfulUsers']} succeeded, {manifest['failedUsers']} failed)"
    )
    if manifest["successfulUsers"] == 0:
        return 1
    if manifest["failedUsers"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
