import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "container_name", ROOT / "ops" / "container_name.py"
)
CONTAINER_NAME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTAINER_NAME)


class ContainerNameTest(unittest.TestCase):
    def test_pd_unique_names_are_valid(self):
        CONTAINER_NAME.validate_explicit_name(
            "lzh-agent-test-glm51-w4a8p-0181-190817-e5c52b84",
            "lzh-agent-test",
        )
        CONTAINER_NAME.validate_explicit_name(
            "lzh-agent-test-glm51-w4a8d-0181-190817-e5c52b84",
            "lzh-agent-test",
        )

    def test_legacy_name_remains_valid(self):
        CONTAINER_NAME.validate_legacy_name(
            "lzh-agent-test-0612-glm47-w8a8-0181",
            "lzh-agent-test",
            "0612",
            "glm47-w8a8",
            "0181",
        )

    def test_wrong_prefix_and_command_characters_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "prefix_mismatch"):
            CONTAINER_NAME.validate_explicit_name(
                "other-agent-test-glm51-w4a8p-0181-token", "lzh-agent-test"
            )
        with self.assertRaisesRegex(ValueError, "invalid_characters"):
            CONTAINER_NAME.validate_explicit_name(
                "lzh-agent-test-good;docker-stop", "lzh-agent-test"
            )


if __name__ == "__main__":
    unittest.main()
