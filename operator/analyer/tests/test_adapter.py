import importlib.util
import json
import os
import subprocess
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

    def test_run_wrapper_skips_dry_run_notifications_and_uses_requested_date(self):
        adapter_dir = Path(__file__).parents[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            skill = root / "skill"
            (skill / "scripts").mkdir(parents=True)
            workflow = skill / "scripts" / "ops_workflow.py"
            workflow.write_text(
                "import json, sys\n"
                "from datetime import date\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "config_path = Path(args[args.index('--config') + 1])\n"
                "config = json.loads(config_path.read_text())\n"
                "target = args[args.index('--date') + 1] if '--date' in args else date.today().isoformat()\n"
                "results = Path(config['results_dir'])\n"
                "results = results if results.is_absolute() else config_path.parent / results\n"
                "out = results / target\n"
                "out.mkdir(parents=True, exist_ok=True)\n"
                "(out / 'summary.json').write_text(json.dumps([{'status':'success','category':'likely','severity':'P2','confidence':0.6,'occurrences':2,'summary':'test finding'}]))\n"
                "print('{}')\n",
                encoding="utf-8",
            )
            fake_bash = root / "fake-bash"
            fake_bash.write_text(
                "#!/bin/sh\nshift 2\npython=$1\nworkflow=$2\nconfig=$3\nshift 3\nexec \"$python\" -B \"$workflow\" run --config \"$config\" \"$@\"\n",
                encoding="utf-8",
            )
            fake_bash.chmod(0o755)
            config = root / "config.json"
            config.write_text(json.dumps({"timezone": "Asia/Shanghai", "results_dir": "results"}), encoding="utf-8")
            notifier = root / "notifier.py"
            notifier.write_text(
                "import os, sys\nfrom pathlib import Path\nPath(os.environ['NOTIFY_MARKER']).write_text(' '.join(sys.argv[1:]))\n",
                encoding="utf-8",
            )
            marker = root / "notification.txt"
            environment = {
                **os.environ,
                "YEYING_OPS_HOME": str(skill),
                "ANALYZER_CONFIG": str(config),
                "BASH_COMMAND_PATH": str(fake_bash),
                "YEYING_OPS_NOTIFY_SCRIPT": str(notifier),
                "NOTIFY_MARKER": str(marker),
            }
            caller_dir = root / "caller"
            caller_dir.mkdir()
            rehearsal = subprocess.run([str(adapter_dir / "run_analyzer.sh"), "--dry-run", "--date", "2026-10-22"], cwd=caller_dir, env=environment, capture_output=True, text=True, check=False)
            self.assertEqual(rehearsal.returncode, 0, rehearsal.stderr)
            self.assertFalse(marker.exists())
            run = subprocess.run([str(adapter_dir / "run_analyzer.sh"), "--date", "2026-10-22"], cwd=caller_dir, env=environment, capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue(marker.exists())
            self.assertIn("日期：2026-10-22", marker.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
