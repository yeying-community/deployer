import json
import os
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import config_core as c

KEY = "test-only-not-a-real-key"


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yeying-config-test-")
        self.root = Path(self.temp.name) / "中文 用户 with spaces"
        self.root.mkdir()
        self.path = self.root / "config.toml"

    def tearDown(self):
        self.temp.cleanup()

    def save(self, text="", key=KEY):
        self.path.write_text(text, encoding="utf-8")
        plan = c.prepare(self.path, key)
        c.apply(plan)
        return plan

    def test_first_run_and_restore_removes_only_created_files(self):
        (self.root / "sessions").mkdir()
        session = self.root / "sessions" / "keep.json"
        session.write_text("keep")
        self.assertTrue(c.apply(c.prepare(self.path, KEY)))
        data = tomllib.loads(self.path.read_text("utf-8"))
        self.assertEqual(data["model_provider"], "yeying")
        self.assertEqual(json.loads((self.root / "auth.json").read_text())["OPENAI_API_KEY"], KEY)
        c.restore(self.path)
        self.assertFalse(self.path.exists())
        self.assertFalse((self.root / "auth.json").exists())
        self.assertEqual(session.read_text(), "keep")

    def test_retains_settings_comments_and_existing_auth(self):
        auth = self.root / "auth.json"
        auth.write_bytes(b'{"auth_mode":"chatgpt","tokens":{"test":"keep"}}')
        before_auth = auth.read_bytes()
        text = '# user comment\n[desktop]\nfoo = true\n[mcp_servers.demo]\ncommand = "demo"\n[model_providers.other]\nname="Other"\n'
        self.save(text)
        result = tomllib.loads(self.path.read_text("utf-8"))
        self.assertEqual(result["desktop"], {"foo": True})
        self.assertEqual(result["mcp_servers"]["demo"]["command"], "demo")
        self.assertIn("other", result["model_providers"])
        self.assertIn("# user comment", self.path.read_text("utf-8"))
        self.assertEqual(auth.read_bytes(), before_auth)
        c.restore(self.path)
        self.assertEqual(self.path.read_text("utf-8"), text)

    def test_idempotent_and_keep_original_recovery_point(self):
        self.save("# original\n")
        marker = (c.backup_root(self.path) / "latest.json").read_bytes()
        self.assertFalse(c.apply(c.prepare(self.path, KEY)))
        self.assertEqual(marker, (c.backup_root(self.path) / "latest.json").read_bytes())
        self.assertEqual(len(list(c.backup_root(self.path).glob("*.dpapi"))), 1)
        c.restore(self.path)
        self.assertEqual(self.path.read_text(), "# original\n")

    def test_invalid_toml_is_preserved_and_does_not_echo_key(self):
        self.path.write_text('secret = "sensitive-test-sentinel\n')
        before = self.path.read_bytes()
        with self.assertRaises(c.ConfigError) as raised:
            c.prepare(self.path, KEY)
        self.assertNotIn("sensitive-test-sentinel", str(raised.exception))
        self.assertEqual(before, self.path.read_bytes())
        self.assertFalse(c.backup_root(self.path).exists())

    def test_malformed_provider_preserved(self):
        self.path.write_text('model_providers = "invalid"\n')
        with self.assertRaises(c.ConfigError):
            c.prepare(self.path, KEY)
        self.assertEqual(self.path.read_text(), 'model_providers = "invalid"\n')

    def test_old_auth_sources_and_authorization_header_removed(self):
        self.save('[model_providers.yeying]\nname="old"\nenv_key="OLD"\nrequires_openai_auth=true\nhttp_headers={Authorization="old",X-Trace="keep"}\n[model_providers.yeying.auth]\ncommand="old.exe"\n')
        provider = tomllib.loads(self.path.read_text())["model_providers"]["yeying"]
        self.assertNotIn("env_key", provider)
        self.assertNotIn("auth", provider)
        self.assertFalse(provider["requires_openai_auth"])
        self.assertEqual(provider["http_headers"], {"X-Trace": "keep"})

    def test_inline_active_profile_updates_only_routing(self):
        self.save('profile="work"\n[profiles.work]\nmodel="old"\nmodel_provider="other"\nsandbox_mode="read-only"\n[profiles.personal]\nmodel="personal"\n')
        data = tomllib.loads(self.path.read_text())
        self.assertEqual(data["profiles"]["work"]["model"], c.MODEL)
        self.assertEqual(data["profiles"]["work"]["sandbox_mode"], "read-only")
        self.assertEqual(data["profiles"]["personal"]["model"], "personal")

    def test_external_profile_conflict_rejected(self):
        self.path.write_text('profile="work"\n')
        (self.root / "work.config.toml").write_text('model="old"\n')
        with self.assertRaises(c.ConfigError):
            c.prepare(self.path, KEY)
        self.assertEqual(self.path.read_text(), 'profile="work"\n')

    def test_config_changed_between_prepare_and_write(self):
        self.path.write_text("# before\n")
        plan = c.prepare(self.path, KEY)
        self.path.write_text("# changed elsewhere\n")
        with self.assertRaises(c.ConfigError):
            c.apply(plan)
        self.assertEqual(self.path.read_text(), "# changed elsewhere\n")

    def test_auth_created_elsewhere_before_save_rejected(self):
        plan = c.prepare(self.path, KEY)
        auth = self.root / "auth.json"
        auth.write_text("new login")
        with self.assertRaises(c.ConfigError):
            c.apply(plan)
        self.assertEqual(auth.read_text(), "new login")
        self.assertFalse(self.path.exists())

    def test_restore_conflict_preserves_later_user_changes(self):
        self.save("# original\n")
        content = self.path.read_bytes() + b'\n# later change\n'
        self.path.write_bytes(content)
        with self.assertRaises(c.ConfigError):
            c.restore(self.path)
        self.assertEqual(self.path.read_bytes(), content)

    def test_second_file_failure_rolls_back_first_file(self):
        self.path.write_text("# original\n")
        before = self.path.read_bytes()
        plan = c.prepare(self.path, KEY)
        original = c.atomic_write
        def failing(path, data, expected):
            if path.name == "auth.json":
                raise PermissionError("synthetic")
            return original(path, data, expected)
        with patch.object(c, "atomic_write", side_effect=failing):
            with self.assertRaises(c.ConfigError):
                c.apply(plan)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse((self.root / "auth.json").exists())

    def test_backup_failure_does_not_change_config(self):
        self.path.write_text("# original\n")
        plan = c.prepare(self.path, KEY)
        with patch.object(c, "protect", side_effect=c.ConfigError("test")):
            with self.assertRaises(c.ConfigError):
                c.apply(plan)
        self.assertEqual(self.path.read_text(), "# original\n")

    def test_bom_and_crlf_retained(self):
        self.path.write_bytes(b'\xef\xbb\xbf# original\r\n[desktop]\r\nfoo=true\r\n')
        before = self.path.read_bytes()
        c.apply(c.prepare(self.path, KEY))
        self.assertTrue(self.path.read_bytes().startswith(b'\xef\xbb\xbf'))
        self.assertIn(b'foo=true\r\n', self.path.read_bytes())
        c.restore(self.path)
        self.assertEqual(self.path.read_bytes(), before)

    def test_escaped_key_and_no_fixed_prefix(self):
        value = 'custom-"-\\-key'
        self.save(key=value)
        parsed = tomllib.loads(self.path.read_text())
        self.assertEqual(parsed["model_providers"]["yeying"]["experimental_bearer_token"], value)

    def test_invalid_key_rejected(self):
        for key in ("", "a\nb", "a b", "a\x00b"):
            with self.subTest(key=repr(key)), self.assertRaises(c.ConfigError):
                c.prepare(self.path, key)
        self.assertFalse(self.path.exists())

    def test_keyring_not_overwritten(self):
        self.save('cli_auth_credentials_store="keyring"\n')
        self.assertFalse((self.root / "auth.json").exists())

    def test_backup_encrypted_and_round_trip(self):
        self.save('test_private_marker="original-sensitive-marker"\n')
        encrypted = next(c.backup_root(self.path).glob("*.dpapi")).read_bytes()
        self.assertNotIn(b"original-sensitive-marker", encrypted)
        self.assertNotIn(KEY.encode(), encrypted)
        c.restore(self.path)
        self.assertIn("original-sensitive-marker", self.path.read_text())

    def test_path_uses_codex_home(self):
        with patch.dict(os.environ, {"CODEX_HOME": str(self.root)}):
            self.assertEqual(c.config_path(), self.path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
