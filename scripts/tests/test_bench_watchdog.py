import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path


SCRIPTS_ROOT = Path(__file__).resolve().parents[1]
WATCHDOG = SCRIPTS_ROOT / "ops" / "bench_watchdog.py"
RECORD_FAILURE = SCRIPTS_ROOT / "ops" / "record_failure.py"


class BenchWatchdogTest(unittest.TestCase):
    def run_watchdog(self, command, timeout=5, append_role=None, append_text=""):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = root / "state.json"
            state.write_text("{}\n", encoding="utf-8")
            prefill = root / "prefill.log"
            decode = root / "decode.log"
            prefill.write_text("ready\n", encoding="utf-8")
            decode.write_text("ready\n", encoding="utf-8")
            result = root / "result.json"
            output = root / "bench.log"

            if append_role:
                target = prefill if append_role == "prefill" else decode

                def append_failure():
                    time.sleep(0.3)
                    with target.open("a", encoding="utf-8") as handle:
                        handle.write(append_text + "\n")

                thread = threading.Thread(target=append_failure)
                thread.start()
            else:
                thread = None

            args = [
                sys.executable,
                str(WATCHDOG),
                "--state",
                str(state),
                "--log-file",
                str(output),
                "--result-file",
                str(result),
                "--prefill-log",
                str(prefill),
                "--decode-log",
                str(decode),
                "--timeout",
                str(timeout),
                "--heartbeat-interval",
                "1",
                "--input-len",
                "512",
                "--output-len",
                "32",
                "--concurrency",
                "1",
                "--num-prompts",
                "1",
                "--",
            ] + command
            completed = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if thread:
                thread.join()
            return completed, json.loads(state.read_text(encoding="utf-8")), json.loads(result.read_text(encoding="utf-8"))

    def test_success_updates_heartbeat(self):
        completed, state, result = self.run_watchdog([sys.executable, "-c", "print('done')"])
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(result["reason"], "")
        self.assertEqual(state["pd"]["transfer"]["status"], "READY")
        self.assertIn("heartbeat_at", state["test"])

    def test_rdma_timeout_signal_terminates_benchmark(self):
        completed, state, result = self.run_watchdog(
            [sys.executable, "-c", "import time; time.sleep(20)"],
            append_role="prefill",
            append_text="transport retry counter exceeded",
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(result["reason"], "mooncake_rdma_transfer_timeout")
        self.assertEqual(state["failure"]["reason"], "mooncake_rdma_transfer_timeout")

    def test_kv_pull_failure_is_classified(self):
        completed, state, result = self.run_watchdog(
            [sys.executable, "-c", "import time; time.sleep(20)"],
            append_role="decode",
            append_text="pulling kv_caches failed: Mooncake transfer engine returned -1",
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(result["reason"], "mooncake_kv_pull_failed")
        self.assertEqual(state["pd"]["transfer"]["status"], "FAILED")

    def test_timeout_is_classified(self):
        completed, state, result = self.run_watchdog(
            [sys.executable, "-c", "import time; time.sleep(20)"], timeout=1
        )
        self.assertEqual(completed.returncode, 124)
        self.assertEqual(result["reason"], "bench_timeout")
        self.assertEqual(state["failure"]["reason"], "bench_timeout")

    def test_nonzero_exit_is_classified(self):
        completed, state, result = self.run_watchdog([sys.executable, "-c", "raise SystemExit(3)"])
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(result["reason"], "bench_exit_nonzero")
        self.assertEqual(state["failure"]["reason"], "bench_exit_nonzero")

    def test_stage_failure_preserves_watchdog_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            output = Path(tmp) / "stage.out"
            state.write_text(
                json.dumps({"failure": {"reason": "mooncake_kv_pull_failed", "detail": "decode"}}),
                encoding="utf-8",
            )
            output.write_text("generic run_bench failure\n", encoding="utf-8")
            subprocess.check_call(
                [
                    sys.executable,
                    str(RECORD_FAILURE),
                    "--state",
                    str(state),
                    "--stage",
                    "run_bench",
                    "--exit-code",
                    "1",
                    "--output-file",
                    str(output),
                ]
            )
            data = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(data["failure"]["reason"], "mooncake_kv_pull_failed")
            self.assertEqual(data["failure"]["stage"], "run_bench")


if __name__ == "__main__":
    unittest.main()
