#!/usr/bin/env python3
"""Regression tests for transform_daily_health_records.py."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import transform_daily_health_records as transform


class TransformDailyHealthRecordsTest(unittest.TestCase):
    def test_dedupes_steps_and_averages_other_numeric_types(self) -> None:
        records = [
            {
                "data_type": "STEPS",
                "unit": "COUNT",
                "date_from": "2026-01-01T10:01:00",
                "date_to": "2026-01-01T10:02:00",
                "value": {"numericValue": "100"},
            },
            {
                "data_type": "STEPS",
                "unit": "COUNT",
                "date_from": "2026-01-01T10:02:00",
                "date_to": "2026-01-01T10:03:00",
                "value": {"numericValue": "150"},
            },
            {
                "data_type": "STEPS",
                "unit": "COUNT",
                "date_from": "2026-01-01T10:11:00",
                "date_to": "2026-01-01T10:12:00",
                "value": {"numericValue": "200"},
            },
            {
                "data_type": "WALKING_SPEED",
                "unit": "METERS_PER_SECOND",
                "date_from": "2026-01-01T10:01:00",
                "date_to": "2026-01-01T10:02:00",
                "value": {"numericValue": "1.0"},
            },
            {
                "data_type": "WALKING_SPEED",
                "unit": "METERS_PER_SECOND",
                "date_from": "2026-01-01T10:02:00",
                "date_to": "2026-01-01T10:03:00",
                "value": {"numericValue": "2.0"},
            },
            {
                "data_type": "WALKING_SPEED",
                "unit": "METERS_PER_SECOND",
                "date_from": "2026-01-01T10:11:00",
                "date_to": "2026-01-01T10:12:00",
                "value": {"numericValue": "3.0"},
            },
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            users_dir = Path(temp_dir) / "users"
            users_dir.mkdir()
            user_path = users_dir / "user-1.json"
            user_path.write_text(json.dumps(records), encoding="utf-8")

            rows, summary = transform.transform_user(
                user_path,
                users_dir,
                bucket_minutes=10,
                exact_interval=False,
                data_type_filter=None,
                decimal_places=6,
            )

        by_type = {row["dataType"]: row for row in rows}
        self.assertEqual(by_type["STEPS"]["value"], "350")
        self.assertEqual(by_type["STEPS"]["aggregation"], "sum")
        self.assertEqual(by_type["STEPS"]["buckets"], 2)
        self.assertEqual(by_type["STEPS"]["sourceRecords"], 3)
        self.assertEqual(by_type["STEPS"]["collapsedDuplicateRecords"], 1)

        self.assertEqual(by_type["WALKING_SPEED"]["value"], "2.25")
        self.assertEqual(by_type["WALKING_SPEED"]["aggregation"], "mean")
        self.assertEqual(by_type["WALKING_SPEED"]["buckets"], 2)
        self.assertEqual(by_type["WALKING_SPEED"]["sourceRecords"], 3)
        self.assertEqual(by_type["WALKING_SPEED"]["collapsedDuplicateRecords"], 1)

        self.assertEqual(summary.raw_records, 6)
        self.assertEqual(summary.numeric_records, 6)
        self.assertEqual(summary.exported_rows, 2)
        self.assertEqual(summary.bucket_count, 4)
        self.assertEqual(summary.collapsed_duplicate_records, 2)


if __name__ == "__main__":
    unittest.main()
