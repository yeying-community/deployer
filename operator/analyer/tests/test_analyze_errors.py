import datetime as dt
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo

import sys

sys.path.insert(0, str(Path(__file__).parents[1]))
import analyze_errors


class AnalyzerTests(unittest.TestCase):
    def test_normalize_redacts_ids_secrets_and_numbers(self):
        value = "2026-10-07 23:01:02 ERROR request_id=abc123 token=sk-secret user=42"
        normalized = analyze_errors.normalize_error(value)
        self.assertNotIn("sk-secret", normalized)
        self.assertNotIn("abc123", normalized)
        self.assertIn("[time]", normalized)
        self.assertIn("[n]", normalized)

    def test_read_groups_filters_date_and_deduplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "error.log"
            log.write_text(
                "2026-10-06 23:59:59 ERROR old failure 1\n"
                "2026-10-07 23:01:00 ERROR failure 42\n"
                "2026-10-07 23:02:00 ERROR failure 43\n",
                encoding="utf-8",
            )
            groups = analyze_errors.read_error_groups(
                "router", log, dt.date(2026, 10, 7), ZoneInfo("Asia/Shanghai"), 3, 4000
            )
            self.assertEqual(len(groups), 1)
            self.assertEqual(groups[0].occurrences, 2)

    def test_discover_active_or_highest_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "router-v0.0.9-aaaaaaa").mkdir()
            (root / "router-v0.0.10-bbbbbbb").mkdir()
            self.assertEqual(
                analyze_errors.discover_deploy_dir(root, "router").name,
                "router-v0.0.10-bbbbbbb",
            )
            (root / "router").symlink_to(root / "router-v0.0.9-aaaaaaa", target_is_directory=True)
            self.assertEqual(
                analyze_errors.discover_deploy_dir(root, "router").name,
                "router-v0.0.9-aaaaaaa",
            )

    def test_database_success_is_not_reanalyzed(self):
        with tempfile.TemporaryDirectory() as directory:
            connection = analyze_errors.open_database(Path(directory) / "state.db")
            group = analyze_errors.ErrorGroup("router", "abc", "error", ("error",), 1, "a", "b")
            analyze_errors.upsert_group(connection, group, "success")
            connection.commit()
            self.assertFalse(analyze_errors.should_analyze(connection, group, 0))

    def test_validate_result_adds_group_metadata(self):
        group = analyze_errors.ErrorGroup("router", "abc", "error", ("error",), 2, "a", "b")
        result = analyze_errors.validate_result(
            {
                "summary": "summary",
                "root_cause": {"category": "unknown", "explanation": "not enough evidence"},
                "confidence": 0.1,
                "evidence": [],
                "impact": [],
                "recommended_actions": [],
                "missing_information": ["more logs"],
            },
            group,
        )
        self.assertEqual(result["dedup_fingerprint"], "abc")
        self.assertEqual(result["occurrences"], 2)

    def test_validate_result_rejects_invalid_confidence(self):
        group = analyze_errors.ErrorGroup("router", "abc", "error", ("error",), 1, "a", "b")
        with self.assertRaises(ValueError):
            analyze_errors.validate_result(
                {
                    "summary": "summary",
                    "root_cause": {"category": "unknown", "explanation": "x"},
                    "confidence": 2,
                    "evidence": [],
                    "impact": [],
                    "recommended_actions": [],
                    "missing_information": [],
                },
                group,
            )


if __name__ == "__main__":
    unittest.main()
