import csv
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OPS = ROOT / "ops"


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, OPS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PD_CONFIG = load_module("pd_config")
RENDER_REPORT = load_module("render_report")
RECORD_FAILURE = load_module("record_failure")
RUN_IDENTITY = load_module("run_identity")


class ConfigStateReportTest(unittest.TestCase):
    def test_deployment_configurator_writes_user_layer_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "lab.yaml"
            result = subprocess.run(
                [
                    sys.executable, str(OPS / "configure_pd_deployment.py"),
                    "--deployment-id", "lab", "--prefill-node", "192.0.2.10",
                    "--prefill-service-ip", "198.51.100.10", "--decode-node", "192.0.2.20",
                    "--decode-service-ip", "198.51.100.20", "--network-ifname", "test0",
                    "--user", "tester", "--abbr", "tst", "--output", str(output),
                ],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = PD_CONFIG.load_yaml(output)
            self.assertEqual(data["pd"]["roles"]["prefill"]["node"], "192.0.2.10")
            self.assertNotIn("model", data)
            self.assertNotIn("test", data)

    def test_layered_config_keeps_model_deployment_and_preset_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            profile = tmp / "profile.yaml"
            deployment = tmp / "deployment.yaml"
            preset = tmp / "preset.yaml"
            profile.write_text("model:\n  name: Test\npd:\n  service_defaults:\n    tp: 8\n", encoding="utf-8")
            deployment.write_text("pd:\n  roles:\n    prefill:\n      node: 192.0.2.10\n", encoding="utf-8")
            preset.write_text("test:\n  mode: custom\n  params:\n    input_lens: [512]\n", encoding="utf-8")
            data = PD_CONFIG.compose_config(profile=profile, deployment=deployment, test_preset=preset)
            self.assertEqual(data["model"]["name"], "Test")
            self.assertEqual(data["pd"]["roles"]["prefill"]["node"], "192.0.2.10")
            self.assertEqual(data["test"]["params"]["input_lens"], [512])

    def test_state_reset_removes_historical_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.json"
            state.write_text(json.dumps({"failure": {"reason": "old"}, "cleanup": {"status": "old"}}), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(OPS / "update_state.py"), "--state", str(state), "--reset", "--set", "status=INITIALIZED"],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(data["status"], "INITIALIZED")
            self.assertNotIn("failure", data)
            self.assertNotIn("cleanup", data)

    def test_preflight_failure_categories(self):
        cases = {
            "NODE_UNREACHABLE": "node_unreachable",
            "SSH_AUTH_FAILED": "ssh_auth_failed",
            "DOCKER_UNAVAILABLE": "docker_unavailable",
            "DOCKER_PERMISSION_DENIED": "docker_permission_denied",
            "DOCKER_IMAGE_MISSING": "docker_image_missing",
        }
        for output, expected in cases.items():
            self.assertEqual(RECORD_FAILURE.classify("preflight_pd", output), expected)

    def test_run_identity_is_unique_and_rejects_path_traversal(self):
        first, first_run = RUN_IDENTITY.resolve_run_id("model", "custom")
        second, second_run = RUN_IDENTITY.resolve_run_id("model", "custom")
        self.assertNotEqual(first, second)
        self.assertNotEqual(first_run, second_run)
        with self.assertRaises(ValueError):
            RUN_IDENTITY.resolve_run_id("model", "custom", "../shared")

    def test_pchit_execution_pass_and_sla_partial(self):
        rows = [
            {"status": "PASS", "sla_pass": "true", "concurrency": "5", "completed_requests": "5", "failed_requests": "0"},
            {"status": "FAIL", "sla_pass": "false", "concurrency": "6", "completed_requests": "6", "failed_requests": "0"},
        ]
        summary = RENDER_REPORT.summarize(rows, "pchit")
        self.assertEqual(summary["execution_status"], "PASS")
        self.assertEqual(summary["benchmark_status"], "PASS")
        self.assertEqual(summary["sla_status"], "PARTIAL")
        self.assertEqual(summary["best_sla_concurrency"], 5)


if __name__ == "__main__":
    unittest.main()
