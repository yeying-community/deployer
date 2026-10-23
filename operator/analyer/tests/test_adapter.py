import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "analyze_errors.py"
SPEC = importlib.util.spec_from_file_location("deployer_error_analyzer", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AdapterTests(unittest.TestCase):
    def test_resolves_configured_skill(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflow = root / "scripts" / "ops_workflow.py"
            workflow.parent.mkdir()
            workflow.write_text("# test\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {"YEYING_OPS_HOME": str(root)}):
                self.assertEqual(MODULE.workflow_path(), workflow.resolve())

    def test_missing_skill_has_actionable_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(os.environ, {"YEYING_OPS_HOME": directory, "HOME": directory}, clear=True):
                with self.assertRaisesRegex(RuntimeError, "installed yeying-ops Skill not found"):
                    MODULE.workflow_path()


if __name__ == "__main__":
    unittest.main()
