import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STANDARDIZE = ROOT / "ops" / "standardize_pd_server_scripts.py"
REGISTER = ROOT / "ops" / "register_pd_model.py"


ROLE_TEMPLATE = """
export VLLM_USE_MODELSCOPE=1
export VLLM_HCU_USE_CUSTOM_FLASH_ATTN=1
export VLLM_HOST_IP=198.51.100.10
vllm serve /model/Test-W8A8 \\
  --kv-transfer-config '{{"kv_connector":"MooncakeConnector","kv_role":"{role}"}}' \\
  {eager}-tp 8 -q test_quant --disable-cascade-attn --port {port} \\
  --dtype bfloat16 --max_num_batched_tokens 8192
"""


class PdModelOnboardingTest(unittest.TestCase):
    def run_cmd(self, args):
        return subprocess.run([sys.executable] + [str(arg) for arg in args], text=True, capture_output=True, check=False)

    def prepare_sources(self, directory):
        source = Path(directory) / "source"
        source.mkdir()
        prefill = source / "p.sh"
        decode = source / "d.sh"
        proxy = source / "proxy.sh"
        prefill.write_text(ROLE_TEMPLATE.format(role="kv_producer", eager="--enforce-eager ", port=9348), encoding="utf-8")
        decode.write_text(ROLE_TEMPLATE.format(role="kv_consumer", eager="", port=9349), encoding="utf-8")
        proxy.write_text("python3 proxy.py --prefill http://p:1 8998 --decode http://d:2 --port 8000\n", encoding="utf-8")
        return prefill, decode, proxy

    def standardize_args(self, root, sources, dry_run=False):
        args = [STANDARDIZE, "--skill-root", root, "--model-short", "testw8a8", "--prefill-source", sources[0], "--decode-source", sources[1], "--proxy-source", sources[2]]
        if dry_run:
            args.append("--dry-run")
        return args

    def test_standardize_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            sources = self.prepare_sources(tmp)
            result = self.run_cmd(self.standardize_args(tmp, sources, True))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PD_SERVER_STANDARDIZE_DRY_RUN_DONE=1", result.stdout)
            self.assertFalse((Path(tmp) / "scripts" / "pd-server" / "testw8a8").exists())

    def test_parser_supports_multiline_json_and_infers_gpu_range_from_tp(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "role.sh"
            script.write_text(textwrap.dedent("""
                export MODEL_OPT=1
                vllm serve /model/Test-W4A8 \\
                  -tp 4 --dtype bfloat16 \\
                  --speculative_config '{
                    "method":"deepseek_mtp",
                    "num_speculative_tokens":2}' \\
                  --kv-cache-dtype fp8_ds_mla \\
                  --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_consumer"}'
            """).strip() + "\n", encoding="utf-8")
            sys.path.insert(0, str(ROOT / "ops"))
            from standardize_pd_server_scripts import parse_role_script
            parsed = parse_role_script(script)
            self.assertEqual(parsed["gpu_range"], "0,1,2,3")
            self.assertIn('"method":"deepseek_mtp"', parsed["speculative_config"])
            self.assertEqual(parsed["extras"], ["--kv-cache-dtype", "fp8_ds_mla"])

    def test_register_generates_profile_and_smoke_preset_without_deployment(self):
        with tempfile.TemporaryDirectory() as tmp:
            sources = self.prepare_sources(tmp)
            result = self.run_cmd(self.standardize_args(tmp, sources))
            self.assertEqual(result.returncode, 0, result.stderr)
            base = Path(tmp) / "base.yaml"
            base.write_text(textwrap.dedent("""
                mode: pd
                pd:
                  backend: mooncake_vllm018
                  topology: 1p1d
                  runtime:
                    mooncake_wheel: null
                    mooncake_dest_device_affinity: true
                  service_defaults:
                    max_num_batched_tokens: 16384
                  network:
                    ifname: test0
                  roles:
                    prefill:
                      node: 192.0.2.10
                      service_ip: 198.51.100.10
                      port: 9348
                      transfer_port: 8998
                    decode:
                      node: 192.0.2.20
                      service_ip: 198.51.100.20
                      port: 9349
                  proxy:
                    node_role: prefill
                    port: 8000
            """).strip() + "\n", encoding="utf-8")
            args = [REGISTER, "--skill-root", tmp, "--profile-id", "test-vllm018-mooncake", "--model-name", "Test-W8A8", "--model-short", "testw8a8", "--host-model-path", "/models/Test-W8A8", "--container-model-path", "/model/Test-W8A8", "--precision", "int8", "--tp", "8", "--gpu-range", "0,1,2,3,4,5,6,7", "--quantization", "test_quant", "--dtype", "bfloat16", "--base-config", base, "--user", "tester", "--abbr", "ts"]
            dry = self.run_cmd(args + ["--dry-run"])
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn("PD_MODEL_REGISTER_DRY_RUN_DONE=1", dry.stdout)
            real = self.run_cmd(args)
            self.assertEqual(real.returncode, 0, real.stderr)
            profile = Path(tmp) / "references" / "pd-profiles" / "test-vllm018-mooncake.yaml"
            preset = Path(tmp) / "references" / "test-presets" / "testw8a8-smoke.yaml"
            self.assertIn("model_short: testw8a8", profile.read_text(encoding="utf-8"))
            profile_text = profile.read_text(encoding="utf-8")
            preset_text = preset.read_text(encoding="utf-8")
            self.assertIn("input_lens: [512]", preset_text)
            self.assertNotIn("ifname: test0", profile_text)
            self.assertNotIn("node: 192.0.2.10", profile_text)


if __name__ == "__main__":
    unittest.main()
