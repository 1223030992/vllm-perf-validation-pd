import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OPS = ROOT / "scripts" / "ops"
sys.path.insert(0, str(OPS))


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, OPS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PD_CONFIG = load_module("pd_config")
STANDARDIZE = load_module("standardize_pd_server_scripts")


class Glm51AssetsTest(unittest.TestCase):
    def test_generated_profile_and_role_scripts_match_verified_sources(self):
        profile = PD_CONFIG.load_yaml(
            ROOT / "references" / "pd-profiles" / "glm51-w4a8-vllm018-mooncake.yaml"
        )
        model = profile["model"]
        defaults = profile["pd"]["service_defaults"]
        self.assertEqual(model["name"], "GLM-5.1-W4A8-V2_6")
        self.assertNotIn("host_model_path", model)
        self.assertEqual(model["container_model_path"], "/model/GLM-5.1-W4A8-V2_6")
        self.assertEqual(defaults["tp"], 8)
        self.assertEqual(defaults["gpu_range"], "0,1,2,3,4,5,6,7")
        self.assertEqual(defaults["dtype"], "bfloat16")
        self.assertEqual(defaults["max_model_len"], 67000)
        self.assertEqual(defaults["gpu_memory_utilization"], 0.92)
        self.assertIn("deepseek_mtp", defaults["speculative_config"])
        self.assertIn("--kv-cache-dtype fp8_ds_mla", defaults["prefill_extra_args"])

        server_dir = ROOT / "scripts" / "pd-server" / "glm51-w4a8"
        prefill = STANDARDIZE.parse_role_script(server_dir / "p_server.sh")
        decode = STANDARDIZE.parse_role_script(server_dir / "d_server.sh")
        self.assertEqual(prefill["kv_role"], "kv_producer")
        self.assertEqual(decode["kv_role"], "kv_consumer")
        for export in (
            "VLLM_USE_MODELSCOPE", "VLLM_HCU_USE_FLASHMLA",
            "LMSLIM_USE_GLOBAL_MOE_CACHE", "VLLM_ROCM_USE_AITER_MOE",
        ):
            self.assertTrue(any(export in line for line in prefill["exports"]))
            self.assertTrue(any(export in line for line in decode["exports"]))

    def test_deployment_supplies_glm51_host_model_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            deployment = Path(tmp) / "lab-glm51.yaml"
            deployment.write_text(
                "model:\n  host_model_path: /public4/opendas/DL_DATA/llm-models/GLM-5.1-W4A8-V2_6\n",
                encoding="utf-8",
            )
            composed = PD_CONFIG.compose_config(
                profile="glm51-w4a8-vllm018-mooncake", deployment=deployment
            )
            self.assertEqual(
                composed["model"]["host_model_path"],
                "/public4/opendas/DL_DATA/llm-models/GLM-5.1-W4A8-V2_6",
            )


if __name__ == "__main__":
    unittest.main()
