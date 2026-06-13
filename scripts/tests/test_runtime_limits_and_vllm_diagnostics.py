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


LIMITS = load_module("validate_runtime_limits")
DIAGNOSTICS = load_module("vllm_failure_diagnostics")


KV_CACHE_LOG = """
ValueError: To serve at least one request with the models's max seq len (202752),
(13.6 GiB KV cache is needed, which is larger than the available KV cache memory
(4.51 GiB). Based on the available memory, the estimated maximum model length is
67200. Try increasing gpu_memory_utilization or decreasing max_model_len.
Failed: Cuda error custom_all_reduce_hip.cuh:820 'invalid argument'
Worker proc VllmWorker-7 died unexpectedly.
"""


class RuntimeLimitsAndDiagnosticsTest(unittest.TestCase):
    def test_glm51_smoke_and_32k_fit_67000(self):
        smoke = LIMITS.validate("67000", "0.92", "custom", "512", "32")
        long_context = LIMITS.validate("67000", "0.92", "custom", "32768", "1024")
        self.assertEqual(smoke["required_sequence_length"], 544)
        self.assertEqual(long_context["required_sequence_length"], 33792)

    def test_invalid_memory_controls_are_rejected(self):
        for max_len in ("0", "-1", "invalid"):
            with self.subTest(max_len=max_len), self.assertRaises(ValueError):
                LIMITS.validate(max_len, "0.92", "custom", "512", "32")
        for utilization in ("0", "1.01", "nan", "invalid"):
            with self.subTest(utilization=utilization), self.assertRaises(ValueError):
                LIMITS.validate("67000", utilization, "custom", "512", "32")

    def test_test_length_above_max_model_len_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "requires 68000 tokens"):
            LIMITS.validate("67000", "0.92", "custom", "67000", "1000")

    def test_kv_cache_error_is_primary_cause(self):
        result = DIAGNOSTICS.analyze(KV_CACHE_LOG)
        self.assertEqual(result["reason"], "kv_cache_capacity_insufficient")
        self.assertEqual(result["model_max_sequence_length"], 202752)
        self.assertEqual(result["required_kv_cache_gib"], 13.6)
        self.assertEqual(result["available_kv_cache_gib"], 4.51)
        self.assertEqual(result["estimated_max_model_len"], 67200)

    def test_diagnostic_cli_persists_capacity_details(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            state = tmp / "state.json"
            log = tmp / "prefill.log"
            state.write_text("{}", encoding="utf-8")
            log.write_text(KV_CACHE_LOG, encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable, str(OPS / "vllm_failure_diagnostics.py"),
                    "--state", str(state), "--role", "prefill", "--log", str(log),
                ],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(data["failure"]["reason"], "kv_cache_capacity_insufficient")
            self.assertEqual(data["failure"]["diagnostics"]["estimated_max_model_len"], 67200)
            self.assertEqual(data["pd"]["roles"]["prefill"]["status"], "FAILED")

    def test_run_entrypoint_overrides_profile_and_forwards_to_both_roles(self):
        script = (OPS / "run_pd_task.sh").read_text(encoding="utf-8")
        self.assertIn(
            'MAX_MODEL_LEN="${MAX_MODEL_LEN_ARG:-${PD_SERVICE_DEFAULTS_MAX_MODEL_LEN:-}}"',
            script,
        )
        self.assertIn(
            'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION_ARG:-${PD_SERVICE_DEFAULTS_GPU_MEMORY_UTILIZATION:-}}"',
            script,
        )
        self.assertEqual(script.count('--max-model-len "$MAX_MODEL_LEN"'), 3)
        self.assertEqual(script.count('--gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"'), 3)
        readiness = (OPS / "wait_vllm_ready.sh").read_text(encoding="utf-8")
        self.assertIn("ValueError: To serve at least one request", readiness)

    def test_cli_node_overrides_deployment_and_are_reported_before_ssh(self):
        script = (OPS / "run_pd_task.sh").read_text(encoding="utf-8")
        expected_assignments = (
            'PREFILL_NODE="${PREFILL_NODE_ARG:-${PD_ROLES_PREFILL_NODE:-}}"',
            'PREFILL_SERVICE_IP="${PREFILL_SERVICE_IP_ARG:-${PD_ROLES_PREFILL_SERVICE_IP:-$PREFILL_NODE}}"',
            'PREFILL_VLLM_HOST_IP="${PREFILL_VLLM_HOST_IP_ARG:-${PD_ROLES_PREFILL_VLLM_HOST_IP:-$PREFILL_SERVICE_IP}}"',
            'DECODE_NODE="${DECODE_NODE_ARG:-${PD_ROLES_DECODE_NODE:-}}"',
            'DECODE_SERVICE_IP="${DECODE_SERVICE_IP_ARG:-${PD_ROLES_DECODE_SERVICE_IP:-$DECODE_NODE}}"',
            'DECODE_VLLM_HOST_IP="${DECODE_VLLM_HOST_IP_ARG:-${PD_ROLES_DECODE_VLLM_HOST_IP:-$DECODE_SERVICE_IP}}"',
        )
        for assignment in expected_assignments:
            self.assertIn(assignment, script)

        summary_start = script.index("EFFECTIVE_CONFIG_READY=1")
        first_remote_stage = script.index('run_stage ensure_workspace')
        self.assertLess(summary_start, first_remote_stage)
        for field in (
            "PREFILL_NODE=$PREFILL_NODE",
            "PREFILL_SERVICE_IP=$PREFILL_SERVICE_IP",
            "PREFILL_VLLM_HOST_IP=$PREFILL_VLLM_HOST_IP",
            "DECODE_NODE=$DECODE_NODE",
            "DECODE_SERVICE_IP=$DECODE_SERVICE_IP",
            "DECODE_VLLM_HOST_IP=$DECODE_VLLM_HOST_IP",
            "EFFECTIVE_CONFIG_END=1",
        ):
            self.assertIn(field, script[summary_start:first_remote_stage])


if __name__ == "__main__":
    unittest.main()
