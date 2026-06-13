import argparse
import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
ONBOARD = ROOT / "ops" / "onboard_pd_model.py"
sys.path.insert(0, str(ROOT / "ops"))
SPEC = importlib.util.spec_from_file_location("onboard_pd_model", ONBOARD)
ONBOARD_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ONBOARD_MODULE)

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
            self.assertIn("STAGING_VALIDATED=1", dry.stdout)
            self.assertIn("PREFILL_SOURCE_SHA256=", dry.stdout)
            self.assertIn("PREFILL_KV_ROLE=kv_producer", dry.stdout)
            self.assertFalse((root / "scripts" / "pd-server" / "fictional-bf16").exists())
            self.assertFalse((root / ".onboard-staging").exists())
            result = self.run_cmd(args)
            self.assertEqual(result.returncode, 0, result.stderr)
            profile = root / "references" / "pd-profiles" / "fictional-bf16-vllm018-mooncake.yaml"
            text = profile.read_text(encoding="utf-8")
            self.assertIn("tp: 2", text)
            self.assertIn("gpu_range: '0,1'", text)
            self.assertNotIn("slimquant_marlin", text)
            self.assertNotIn("num_speculative_tokens", text)
            self.assertTrue((root / "references" / "test-presets" / "fictional-bf16-smoke.yaml").is_file())

    def test_host_model_path_can_be_supplied_by_deployment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefill = root / "p.sh"
            decode = root / "d.sh"
            prefill.write_text(ROLE.format(role="kv_producer", eager="--enforce-eager ", port=9348), encoding="utf-8")
            decode.write_text(ROLE.format(role="kv_consumer", eager="", port=9349), encoding="utf-8")
            result = self.run_cmd([
                "--skill-root", root, "--model-name", "Portable-W4A8",
                "--model-short", "portable-w4a8",
                "--container-model-path", "/model/Portable-W4A8",
                "--prefill-source", prefill, "--decode-source", decode, "--dry-run",
            ])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("HOST_MODEL_PATH=deployment_required", result.stdout)
            profile = result.stdout.split("PROFILE_CONTENT_BEGIN\n", 1)[1].split("PROFILE_CONTENT_END", 1)[0]
            self.assertNotIn("host_model_path", profile)
            self.assertIn("container_model_path: /model/Portable-W4A8", profile)

    def test_unknown_argument_is_reported_structurally(self):
        result = self.run_cmd(["--image-prefix", "TEST"])
        self.assertEqual(result.returncode, 2)
        self.assertIn("PD_MODEL_ONBOARD_FAILED=1", result.stdout)
        self.assertIn("FAILURE_STAGE=parse_arguments", result.stdout)
        self.assertIn("FAILURE_REASON=invalid_arguments", result.stdout)
        self.assertIn("ROLLBACK_COMPLETED=1", result.stdout)

    def test_source_summary_uses_lexical_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            actual = Path(tmp) / "source.sh"
            actual.write_text(ROLE.format(role="kv_producer", eager="--enforce-eager ", port=9348), encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                ONBOARD_MODULE.source_summary(
                    "prefill", Path("/public/home/test/source.sh"), actual,
                    {"kv_role": "kv_producer", "exports": [], "extras": []},
                )
            self.assertIn("PREFILL_SOURCE=/public/home/test/source.sh", output.getvalue())
            self.assertNotIn(str(actual), output.getvalue())

    def test_failure_leaves_no_registered_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            missing = root / "missing.sh"
            result = self.run_cmd([
                "--skill-root", root, "--model-name", "Bad", "--model-short", "bad",
                "--host-model-path", "/models/Bad", "--prefill-source", missing, "--decode-source", missing,
            ])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("PD_MODEL_ONBOARD_FAILED=1", result.stdout)
            self.assertIn("FAILURE_REASON=prefill_source_missing", result.stdout)
            self.assertIn("ROLLBACK_COMPLETED=1", result.stdout)
            self.assertFalse((root / "scripts" / "pd-server" / "bad").exists())

    def test_empty_source_has_role_aware_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefill = root / "p.sh"
            decode = root / "d.sh"
            prefill.write_text("", encoding="utf-8")
            decode.write_text(ROLE.format(role="kv_consumer", eager="", port=9349), encoding="utf-8")
            result = self.run_cmd([
                "--skill-root", root, "--model-name", "Bad", "--model-short", "bad",
                "--host-model-path", "/models/Bad", "--prefill-source", prefill, "--decode-source", decode,
            ])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAILURE_STAGE=validate_sources", result.stdout)
            self.assertIn("FAILURE_REASON=prefill_source_empty", result.stdout)

    def test_wrong_kv_role_is_rejected_before_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefill = root / "p.sh"
            decode = root / "d.sh"
            prefill.write_text(ROLE.format(role="kv_consumer", eager="--enforce-eager ", port=9348), encoding="utf-8")
            decode.write_text(ROLE.format(role="kv_consumer", eager="", port=9349), encoding="utf-8")
            result = self.run_cmd([
                "--skill-root", root, "--model-name", "Bad", "--model-short", "bad",
                "--host-model-path", "/models/Bad", "--prefill-source", prefill, "--decode-source", decode,
                "--dry-run",
            ])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAILURE_REASON=prefill_kv_role_mismatch", result.stdout)
            self.assertFalse((root / ".onboard-staging").exists())

    def test_missing_vllm_serve_and_dry_run_target_conflict_are_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prefill = root / "p.sh"
            decode = root / "d.sh"
            prefill.write_text("export MODEL_OPT=1\n", encoding="utf-8")
            decode.write_text(ROLE.format(role="kv_consumer", eager="", port=9349), encoding="utf-8")
            common = [
                "--skill-root", root, "--model-name", "Bad", "--model-short", "bad",
                "--host-model-path", "/models/Bad", "--prefill-source", prefill, "--decode-source", decode,
                "--dry-run",
            ]
            missing = self.run_cmd(common)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("FAILURE_REASON=prefill_vllm_serve_missing", missing.stdout)

            prefill.write_text(ROLE.format(role="kv_producer", eager="--enforce-eager ", port=9348), encoding="utf-8")
            target = root / "scripts" / "pd-server" / "bad"
            target.mkdir(parents=True)
            conflict = self.run_cmd(common)
            self.assertNotEqual(conflict.returncode, 0)
            self.assertIn("FAILURE_STAGE=check_targets", conflict.stdout)
            self.assertIn("FAILURE_REASON=onboard_target_exists", conflict.stdout)

    def test_commit_failure_rolls_back_first_committed_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            source.mkdir()
            prefill = source / "p.sh"
            decode = source / "d.sh"
            prefill.write_text(ROLE.format(role="kv_producer", eager="--enforce-eager ", port=9348), encoding="utf-8")
            decode.write_text(ROLE.format(role="kv_consumer", eager="", port=9349), encoding="utf-8")
            args = argparse.Namespace(
                model_name="Rollback-BF16", model_short="rollback-bf16",
                host_model_path="/models/Rollback-BF16", container_model_path=None,
                profile_id=None, precision=None, prefill_source=str(prefill),
                decode_source=str(decode), proxy_source=None, skill_root=str(root), dry_run=False,
            )
            real_replace = ONBOARD_MODULE.os.replace
            calls = {"count": 0}

            def fail_second_replace(source_path, target_path):
                calls["count"] += 1
                if calls["count"] == 2:
                    raise OSError("simulated commit failure")
                return real_replace(source_path, target_path)

            output = io.StringIO()
            with mock.patch.object(ONBOARD_MODULE.os, "replace", side_effect=fail_second_replace):
                with contextlib.redirect_stdout(output):
                    rc = ONBOARD_MODULE.onboard(args)
            self.assertEqual(rc, 1)
            self.assertIn("FAILURE_STAGE=commit_targets", output.getvalue())
            self.assertIn("ROLLBACK_COMPLETED=1", output.getvalue())
            self.assertFalse((root / "scripts" / "pd-server" / "rollback-bf16").exists())
            self.assertFalse((root / "references" / "pd-profiles" / "rollback-bf16-vllm018-mooncake.yaml").exists())

    def test_lexical_skill_root_does_not_resolve_symlink(self):
        with mock.patch.object(ONBOARD_MODULE.os.path, "abspath", return_value="/public/home/user/skill"):
            with mock.patch.object(ONBOARD_MODULE.Path, "resolve", side_effect=AssertionError("must not resolve")):
                path = ONBOARD_MODULE.lexical_absolute_path("/public/home/user/skill")
        self.assertEqual(path.as_posix(), "/public/home/user/skill")

    def test_default_skill_root_is_not_built_with_resolve(self):
        text = ONBOARD.read_text(encoding="utf-8")
        self.assertIn("DEFAULT_ROOT = Path(os.path.abspath(__file__)).parents[2]", text)
        self.assertNotIn("DEFAULT_ROOT = Path(__file__).resolve()", text)

    def test_production_scripts_do_not_pass_newline_to_path_write_text(self):
        for name in ("onboard_pd_model.py", "standardize_pd_server_scripts.py", "register_pd_model.py"):
            text = (ROOT / "ops" / name).read_text(encoding="utf-8")
            self.assertNotRegex(text, r"\.write_text\([^\n]*newline\s*=")


if __name__ == "__main__":
    unittest.main()
