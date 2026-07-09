#!/usr/bin/env python3
"""Mock-data tests for build_full_export.py."""

from __future__ import annotations

import csv
import gzip
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
BUILD_SCRIPT = SCRIPT_DIR / "build_full_export.py"


def read_csv_gz(path: Path) -> list[dict[str, str]]:
    with gzip.open(path, "rt", encoding="utf-8", newline="") as file:
        return list(csv.DictReader(file))


class BuildFullExportTest(unittest.TestCase):
    def test_builds_deidentified_mock_export(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            users_dir = root / "raw_download" / "users"
            users_dir.mkdir(parents=True)
            (users_dir / "19800101-1234.json").write_text(
                json.dumps(
                    [
                        {
                            "value": {"numericValue": "100"},
                            "data_type": "STEPS",
                            "unit": "COUNT",
                            "date_from": "2026-01-01T10:01:00",
                            "date_to": "2026-01-01T10:02:00",
                            "platform_type": "ios",
                            "device_id": "device-a",
                            "source_id": "source-a",
                            "source_name": "iPhone",
                        },
                        {
                            "value": {"numericValue": "150"},
                            "data_type": "STEPS",
                            "unit": "COUNT",
                            "date_from": "2026-01-01T10:02:00",
                            "date_to": "2026-01-01T10:03:00",
                            "platform_type": "ios",
                            "device_id": "device-b",
                            "source_id": "source-b",
                            "source_name": "Apple Watch",
                        },
                    ]
                ),
                encoding="utf-8",
            )

            output_dir = root / "export"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(BUILD_SCRIPT),
                    str(root / "raw_download"),
                    "--output-dir",
                    str(output_dir),
                    "--parquet",
                    "skip",
                    "--skip-alignment",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                completed.returncode,
                0,
                msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )
            self.assertTrue((output_dir / "manifest.json").is_file())
            self.assertTrue((output_dir / "checksums.sha256").is_file())
            self.assertTrue((output_dir / "data_dictionary.csv").is_file())
            self.assertTrue(
                (output_dir / "keys_sensitive_separate" / "personal_id_map.csv").is_file()
            )

            raw_rows = read_csv_gz(output_dir / "raw" / "health_records.csv.gz")
            self.assertEqual(len(raw_rows), 2)
            self.assertIn("subject_id", raw_rows[0])
            self.assertNotIn("personalId", raw_rows[0])
            self.assertEqual(raw_rows[0]["subject_id"], "S000001")
            self.assertEqual(raw_rows[0]["numeric_value"], "100")

            daily_rows = read_csv_gz(
                output_dir / "derived" / "daily_health_records.csv.gz"
            )
            self.assertEqual(len(daily_rows), 1)
            self.assertEqual(daily_rows[0]["subject_id"], "S000001")
            self.assertNotIn("personalId", daily_rows[0])
            self.assertEqual(daily_rows[0]["dataType"], "STEPS")
            self.assertEqual(daily_rows[0]["value"], "150")


if __name__ == "__main__":
    unittest.main()
