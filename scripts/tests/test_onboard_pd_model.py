import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ONBOARD = ROOT / "ops" / "onboard_pd_model.py"

ROLE = """
export HIP_VISIBLE_DEVICES=0,1
export TEST_MODEL_OPT=1
vllm serve /model/Fictional-BF16 \\
  --kv-transfer-config '{{"kv_connector":"MooncakeConnector","kv_role":"{role}"}}' \\
  {eager}-tp 2 --port {port} --dtype bfloat16 --max_num_batched_tokens 4096
"""


class OnboardPdModelTest(unittest.TestCase):
    def run_cmd(self, args):
        return subprocess.run([sys.executable, str(ONBOARD)] + [str(value) for value in args], text=True, capture_output=True, check=False)

    def test_non_glm_model_is_onboarded_without_glm_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            source.mkdir()
            prefill = source / "p.sh"
            decode = source / "d.sh"
            prefill.write_text(ROLE.format(role="kv_producer", eager="--enforce-eager ", port=9348), encoding="utf-8")
            decode.write_text(ROLE.format(role="kv_consumer", eager="", port=9349), encoding="utf-8")
            args = [
                "--skill-root", root, "--model-name", "Fictional-BF16", "--model-short", "fictional-bf16",
                "--host-model-path", "/models/Fictional-BF16", "--prefill-source", prefill, "--decode-source", decode,
            ]
            dry = self.run_cmd(args + ["--dry-run"])
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertFalse((root / "scripts" / "pd-server" / "fictional-bf16").exists())
            result = self.run_cmd(args)
            self.assertEqual(result.returncode, 0, result.stderr)
            profile = root / "references" / "pd-profiles" / "fictional-bf16-vllm018-mooncake.yaml"
            text = profile.read_text(encoding="utf-8")
            self.assertIn("tp: 2", text)
            self.assertIn("gpu_range: '0,1'", text)
            self.assertNotIn("slimquant_marlin", text)
            self.assertNotIn("num_speculative_tokens", text)
            self.assertTrue((root / "references" / "test-presets" / "fictional-bf16-smoke.yaml").is_file())

    def test_failure_leaves_no_registered_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            missing = root / "missing.sh"
            result = self.run_cmd([
                "--skill-root", root, "--model-name", "Bad", "--model-short", "bad",
                "--host-model-path", "/models/Bad", "--prefill-source", missing, "--decode-source", missing,
            ])
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "scripts" / "pd-server" / "bad").exists())


if __name__ == "__main__":
    unittest.main()
