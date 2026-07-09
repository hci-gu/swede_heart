#!/usr/bin/env python3
"""Tests for fast resume behavior in download_all_raw_data.py."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import download_all_raw_data as download


class DownloadAllRawDataResumeTest(unittest.TestCase):
    def test_manifest_user_complete_uses_existing_non_empty_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            users_dir = output_dir / "users"
            users_dir.mkdir()
            user_file = users_dir / "19500101-1234.json"
            user_file.write_text("[{}]\n", encoding="utf-8")

            count = download.manifest_user_complete(
                output_dir,
                {
                    "personalId": "19500101-1234",
                    "rawRecords": 1,
                    "file": "users/19500101-1234.json",
                    "status": "downloaded",
                },
            )

        self.assertEqual(count, 1)

    def test_manifest_user_complete_rejects_missing_or_failed_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)

            self.assertIsNone(download.manifest_user_complete(output_dir, None))
            self.assertIsNone(
                download.manifest_user_complete(
                    output_dir,
                    {
                        "personalId": "19500101-1234",
                        "rawRecords": 0,
                        "file": None,
                        "error": "failed",
                    },
                )
            )

    def test_merge_personal_ids_preserves_existing_order_and_appends_new(self) -> None:
        merged = download.merge_personal_ids(
            ["19500101-1234", "19500202-1234"],
            ["19500202-1234", "19500303-1234", "19500101-1234"],
        )

        self.assertEqual(
            merged,
            ["19500101-1234", "19500202-1234", "19500303-1234"],
        )

    def test_validate_start_at_allows_one_past_end_for_noop_resume(self) -> None:
        download.validate_start_at(1, 3)
        download.validate_start_at(4, 3)

        with self.assertRaises(SystemExit):
            download.validate_start_at(0, 3)
        with self.assertRaises(SystemExit):
            download.validate_start_at(5, 3)


if __name__ == "__main__":
    unittest.main()
