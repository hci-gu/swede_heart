#!/usr/bin/env python3
"""Compatibility entrypoint for the daily deduped health-record transform.

This script used to write a lossless row-per-raw-record CSV, which is not the
analysis dataset we want. It now delegates to transform_daily_health_records.py
so existing commands using this filename produce compact daily rows instead.
"""

from __future__ import annotations

import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from transform_daily_health_records import main  # noqa: E402


if __name__ == "__main__":
    sys.exit(main())
