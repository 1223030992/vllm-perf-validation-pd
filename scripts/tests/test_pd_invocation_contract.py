import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OPS = ROOT / "ops"
SPEC = importlib.util.spec_from_file_location(
    "pd_invocation_contract", OPS / "pd_invocation_contract.py"
)
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)


class PdInvocationContractTest(unittest.TestCase):
    def run_contract(self, *args):
        return subprocess.run(
            [sys.executable, str(OPS / "pd_invocation_contract.py"), *args],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_known_command_is_accepted(self):
        result = self.run_contract(
            "--profile", "glm51-w4a8-vllm018-mooncake",
            "--deployment", "/public/home/tester/.config/pd/lab.yaml",
            "--test-preset", "glm51-w4a8-smoke",
            "--image", "registry.example/vllm:0.18.1",
            "--mooncake-wheel", "https://example.invalid/mooncake.whl",
            "--user", "tester", "--abbr", "tst", "--assume-yes",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_observed_wrong_options_have_specific_hints(self):
        expected = {
            "--prefill-host-ip": "--prefill-service-ip and --prefill-vllm-host-ip",
            "--decode-host-ip": "--decode-service-ip and --decode-vllm-host-ip",
            "--nic": "--network-ifname",
            "--hca": "--nccl-ib-hca",
            "--input-length": "--input-lens",
            "--output-length": "--output-len",
            "--concurrency": "--concurrencies",
            "--test-mode": "selected by --test-preset",
            "--num-prompts": "--num-prompts-mult",
        }
        for option, hint in expected.items():
            with self.subTest(option=option):
                result = self.run_contract(option, "value")
                self.assertEqual(result.returncode, 2)
                self.assertIn("PD_INVOCATION_REJECTED=1", result.stdout)
                self.assertIn("TASK_STARTED=0", result.stdout)
                self.assertIn("FAILURE_STAGE=parse_arguments", result.stdout)
                self.assertIn("ARGUMENT_ERROR={}".format(option), result.stdout)
                self.assertIn(hint, result.stdout)

    def test_missing_value_is_rejected_before_task_start(self):
        result = self.run_contract("--profile")
        self.assertEqual(result.returncode, 2)
        self.assertIn("PD_INVOCATION_REJECTED=1", result.stdout)
        self.assertIn("ARGUMENT_ERROR=--profile", result.stdout)
        self.assertIn("requires one value", result.stdout)

    def test_validator_runs_before_state_initialization(self):
        script = (OPS / "run_pd_task.sh").read_text(encoding="utf-8")
        validator = script.index("pd_invocation_contract.py")
        initialize_state = script.index("run_stage initialize_state")
        ensure_workspace = script.index("run_stage ensure_workspace")
        self.assertLess(validator, initialize_state)
        self.assertLess(validator, ensure_workspace)

    def test_contract_matches_shell_parser_options(self):
        script = (OPS / "run_pd_task.sh").read_text(encoding="utf-8")
        loop = script.split("while [[ $# -gt 0 ]]; do", 1)[1].split("\ndone", 1)[0]
        runtime = (OPS / "runtime_config.sh").read_text(encoding="utf-8")
        common = runtime.split("runtime_config_parse_common_arg()", 1)[1].split("\n}", 1)[0]
        parsed = set(re.findall(r"--[a-z0-9-]+", loop + common))
        contracted = CONTRACT.VALUE_OPTIONS | CONTRACT.FLAG_OPTIONS
        self.assertEqual(parsed, contracted)


if __name__ == "__main__":
    unittest.main()
