#!/usr/bin/env python3
"""Generate an API key and encode it for api/deploy/secret.yaml."""

from __future__ import annotations

import argparse
import base64
import secrets
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate or encode the API key used by the OpenShift Secret."
    )
    parser.add_argument(
        "--api-key",
        help="Encode this existing API key instead of generating a new one.",
    )
    parser.add_argument(
        "--bytes",
        type=int,
        default=32,
        help="Random bytes for generated keys. Defaults to 32.",
    )
    parser.add_argument(
        "--yaml",
        action="store_true",
        help="Print a complete Secret manifest instead of only the api-key line.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.api_key and args.bytes < 16:
        raise SystemExit("--bytes must be at least 16")

    api_key = args.api_key or secrets.token_urlsafe(args.bytes)
    encoded = base64.b64encode(api_key.encode("utf-8")).decode("ascii")

    if args.yaml:
        print("apiVersion: v1")
        print("kind: Secret")
        print("metadata:")
        print("    name: swedeheart-api-secret")
        print("type: Opaque")
        print("data:")
        print(f"    api-key: {encoded}")
    else:
        print(f"API key: {api_key}", file=sys.stderr)
        print(f"api-key: {encoded}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
