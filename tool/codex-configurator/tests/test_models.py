from pathlib import Path
import sys
import tempfile
import tomllib
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config_core as c

KEY = "test-only-model-list-key"


class ModelTests(unittest.TestCase):
    def test_chosen_model_saved_in_root_and_active_profile_and_restorable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            original = 'profile="work"\n[desktop]\nkeep=true\n[profiles.work]\nmodel="old"\nmodel_provider="other"\n'
            path.write_text(original, encoding="utf-8")
            chosen = "provider/my-authorized-model"
            self.assertTrue(c.apply(c.prepare(path, KEY, chosen)))
            parsed = tomllib.loads(path.read_text("utf-8"))
            self.assertEqual(parsed["model"], chosen)
            self.assertEqual(parsed["profiles"]["work"]["model"], chosen)
            self.assertEqual(c.configured_model(path), chosen)
            self.assertFalse(c.apply(c.prepare(path, KEY, chosen)))
            c.restore(path)
            self.assertEqual(path.read_text("utf-8"), original)

    def test_empty_or_multiline_model_never_changes_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            path.write_text("# original\n")
            for value in ("", " ", "two models", "name\n[table]", None):
                with self.subTest(value=value), self.assertRaises(c.ConfigError):
                    c.prepare(path, KEY, value)
            self.assertEqual(path.read_text(), "# original\n")

    def test_initial_model_reads_active_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.toml"
            self.assertEqual(c.configured_model(path), c.MODEL)
            path.write_text('model="base"\nprofile="work"\n[profiles.work]\nmodel="profile-model"\n')
            self.assertEqual(c.configured_model(path), "profile-model")


if __name__ == "__main__":
    unittest.main(verbosity=2)
