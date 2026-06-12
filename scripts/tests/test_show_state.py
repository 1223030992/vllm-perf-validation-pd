import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("show_state", ROOT / "ops" / "show_state.py")
SHOW_STATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHOW_STATE)


class ShowStateTest(unittest.TestCase):
    def write_csv(self, directory, row):
        path = Path(directory) / "all.csv"
        with path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(row))
            writer.writeheader()
            writer.writerow(row)
        return path

    def test_custom_summary_does_not_emit_pchit_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_csv(tmp, {"concurrency": "1", "rps": "0.54", "effective_cache_hit_pct": "90"})
            summary = SHOW_STATE.csv_summary(path, "custom")
            self.assertEqual(summary["qps"], 0.54)
            self.assertNotIn("pchit_best_sla_concurrency", summary)
            self.assertNotIn("pchit_effective_pct", summary)

    def test_pchit_summary_emits_pchit_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_csv(tmp, {"concurrency": "4", "effective_cache_hit_pct": "87.5", "status": "PASS"})
            summary = SHOW_STATE.csv_summary(path, "pchit")
            self.assertEqual(summary["pchit_best_sla_concurrency"], 4.0)
            self.assertEqual(summary["pchit_effective_pct"], 87.5)

    def test_missing_csv_returns_empty_summary(self):
        self.assertEqual(SHOW_STATE.csv_summary("/missing/file.csv", "custom"), {})

    def test_absolute_state_path_is_readable(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            state.write_text(json.dumps({"status": "COMPLETED", "test": {"mode": "custom"}}), encoding="utf-8")
            self.assertTrue(state.is_absolute())
            self.assertEqual(json.loads(state.read_text(encoding="utf-8"))["status"], "COMPLETED")


if __name__ == "__main__":
    unittest.main()
