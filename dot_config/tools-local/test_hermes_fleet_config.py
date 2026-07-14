#!/usr/bin/env python3
import base64
import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
from pathlib import Path

SCRIPT = Path(__file__).with_name("hermes-fleet-config")

EXPECTED_REASONING = {
    "skills_hub": "none",
    "title_generation": "none",
    "tts_audio_tags": "none",
    "profile_describer": "none",
    "monitor": "none",
    "curator": "none",
    "compression": "low",
    "web_extract": "low",
    "vision": "low",
    "approval": "low",
    "triage_specifier": "low",
    "mcp": "medium",
    "kanban_decomposer": "medium",
    "moa_reference": "high",
    "moa_aggregator": "high",
}


def load_module():
    loader = importlib.machinery.SourceFileLoader("hermes_fleet_config", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class ReconcilerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = load_module()
        cls.policy = cls.m.load_policy(Path(__file__).with_name("hermes-fleet-policy.json"))

    def sample(self):
        return {
            "_config_version": 33,
            "model": {"provider": "openai-codex", "default": "gpt-5.6-sol"},
            "gateway": {"platforms": {"telegram": {"bot_token": "keep-me"}}},
            "auxiliary": {
                "compression": {"provider": "auto", "model": "", "timeout": 999},
                "curator": {"provider": "auto", "model": "", "extra_body": {"old": True}},
                "background_review": {"provider": "auto", "model": "", "timeout": 77, "reasoning_effort": "medium"},
                "session_search": {"provider": "auto", "model": ""},
            },
            "delegation": {"provider": "", "model": "", "max_iterations": 88},
            "fallback_providers": ["nous", "custom:tokenrouter"],
            "fallback_model": {"provider": "nous", "model": "legacy"},
            "custom_providers": [
                {"name": "nim", "base_url": "https://integrate.api.nvidia.com/v1", "key_env": "NVIDIA_API_KEY"},
                {"name": "tokenrouter", "base_url": "https://example.invalid/v1", "key_env": "TOKENROUTER_MAIN"},
            ],
            "secrets": {"onepassword": {"env": {"NVIDIA_API_KEY": "op://hidden", "TOKENROUTER_MAIN": "op://hidden2"}}},
        }

    def target_data(self):
        return {
            "docker": {
                "ssh_host": "docker.example",
                "identity_file": "/tmp/fleet-test-key",
                "compose_dir": "/srv/agent",
                "service": "agent",
                "container_user": "12345",
                "python": "/app/venv/bin/python3",
            },
            "macos": {
                "ssh_host": "operator@mac.example",
                "python": "/srv/agent/venv/bin/python3",
            },
        }

    def write_auth(self, home, *, nous=1, codex=1, opencode=1):
        (home / "auth.json").write_text(json.dumps({
            "credential_pool": {
                "nous": [{}] * nous,
                "openai-codex": [{}] * codex,
                "opencode-go": [{}] * opencode,
            }
        }), encoding="utf-8")

    def test_reconcile_sets_policy_and_preserves_unmanaged_values(self):
        before = self.sample()
        after = self.m.reconcile_config(before, self.policy, supported_slots=set(self.policy["auxiliary"]["slots"]), prune_retired=False)
        self.assertEqual(after["model"], before["model"])
        self.assertEqual(after["gateway"], before["gateway"])
        self.assertEqual(after["auxiliary"]["compression"]["timeout"], 999)
        self.assertEqual(after["auxiliary"]["compression"]["provider"], "opencode-go")
        self.assertEqual(after["auxiliary"]["compression"]["model"], "deepseek-v4-pro")
        self.assertEqual(after["auxiliary"]["compression"]["fallback_chain"], [{"provider": "nous", "model": "deepseek/deepseek-v4-pro"}])
        self.assertNotIn("extra_body", after["auxiliary"]["curator"])
        self.assertEqual(after["auxiliary"]["curator"]["reasoning_effort"], "none")
        self.assertEqual(after["auxiliary"]["background_review"]["provider"], "auto")
        self.assertEqual(after["auxiliary"]["background_review"]["model"], "")
        self.assertEqual(after["auxiliary"]["background_review"]["timeout"], 77)
        self.assertNotIn("reasoning_effort", after["auxiliary"]["background_review"])
        self.assertNotIn("session_search", after["auxiliary"])
        self.assertEqual(after["delegation"]["max_iterations"], 88)
        self.assertEqual(after["delegation"]["provider"], "opencode-go")
        self.assertEqual(after["delegation"]["model"], "kimi-k2.7-code")
        self.assertEqual(after["delegation"]["reasoning_effort"], "medium")
        self.assertEqual(after["fallback_providers"], self.policy["fallback_providers"])
        self.assertNotIn("fallback_model", after)
        self.assertIn("nim", [x["name"] for x in after["custom_providers"]])

    def test_prune_retired_removes_nim_refs_only(self):
        after = self.m.reconcile_config(self.sample(), self.policy, supported_slots=set(self.policy["auxiliary"]["slots"]), prune_retired=True)
        self.assertEqual([x["name"] for x in after["custom_providers"]], ["tokenrouter"])
        self.assertNotIn("NVIDIA_API_KEY", after["secrets"]["onepassword"]["env"])
        self.assertIn("TOKENROUTER_MAIN", after["secrets"]["onepassword"]["env"])

    def test_reconcile_is_idempotent(self):
        once = self.m.reconcile_config(self.sample(), self.policy, supported_slots=set(self.policy["auxiliary"]["slots"]), prune_retired=True)
        twice = self.m.reconcile_config(once, self.policy, supported_slots=set(self.policy["auxiliary"]["slots"]), prune_retired=True)
        self.assertEqual(once, twice)

    def test_unmanaged_projection_is_equal(self):
        before = self.sample()
        after = self.m.reconcile_config(before, self.policy, supported_slots=set(self.policy["auxiliary"]["slots"]), prune_retired=True)
        self.assertEqual(self.m.unmanaged_projection(before, self.policy), self.m.unmanaged_projection(after, self.policy))

    def test_apply_writes_without_bom_preserves_mode_and_creates_backup(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            config = home / "config.yaml"
            self.m.dump_yaml(config, self.sample())
            self.write_auth(home)
            os.chmod(config, 0o640)
            result = self.m.process_config(home, self.policy, apply=True, dry_run=False, prune_retired=True, expected_hash=self.m.sha256_file(config), supported_slots=set(self.policy["auxiliary"]["slots"]), supported_reasoning_slots=set(self.policy["auxiliary"]["slots"]))
            self.assertTrue(result["changed"])
            self.assertTrue(Path(result["backup_path"]).is_file())
            self.assertFalse(config.read_bytes().startswith(b"\xef\xbb\xbf"))
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o640)
            persisted = self.m.load_yaml(config)
            self.assertEqual(persisted["delegation"]["model"], "kimi-k2.7-code")

    def test_atomic_restore_replaces_exact_backup_and_preserves_mode(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            backup = root / "backup.yaml"
            config = root / "config.yaml"
            backup.write_bytes(b"_config_version: 33\noriginal: true\n")
            config.write_bytes(b"corrupt: true\n")
            os.chmod(config, 0o640)
            self.m._restore_backup_atomic(backup, config, 0o640)
            self.assertEqual(config.read_bytes(), backup.read_bytes())
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o640)
            self.assertEqual(list(root.glob(".config.yaml.*")), [])

    def test_report_contains_audited_hash(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            config = home / "config.yaml"
            self.m.dump_yaml(config, self.sample())
            self.write_auth(home)
            report = self.m.process_config(
                home, self.policy, apply=False, dry_run=False, prune_retired=True,
                expected_hash=None, supported_slots=set(self.policy["auxiliary"]["slots"]),
                supported_reasoning_slots=set(self.policy["auxiliary"]["slots"]),
            )
            self.assertEqual(report["audited_hash"], self.m.sha256_file(config))
            self.assertIsNone(report["expected_hash"])

    def test_report_hash_rejects_mutation_before_apply(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            config = home / "config.yaml"
            self.m.dump_yaml(config, self.sample())
            self.write_auth(home)
            report = self.m.process_config(
                home, self.policy, apply=False, dry_run=False, prune_retired=True,
                expected_hash=None, supported_slots=set(self.policy["auxiliary"]["slots"]),
                supported_reasoning_slots=set(self.policy["auxiliary"]["slots"]),
            )
            changed = self.m.load_yaml(config)
            changed["model"]["default"] = "concurrent-edit"
            self.m.dump_yaml(config, changed)
            with self.assertRaisesRegex(RuntimeError, "changed since audit"):
                self.m.process_config(
                    home, self.policy, apply=True, dry_run=False, prune_retired=True,
                    expected_hash=report["audited_hash"],
                    supported_slots=set(self.policy["auxiliary"]["slots"]),
                    supported_reasoning_slots=set(self.policy["auxiliary"]["slots"]),
                )

    def test_apply_requires_report_hash(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            config = home / "config.yaml"
            self.m.dump_yaml(config, self.sample())
            self.write_auth(home)
            with self.assertRaisesRegex(RuntimeError, "expected hash from report"):
                self.m.process_config(home, self.policy, apply=True, dry_run=False, prune_retired=True, expected_hash=None, supported_slots=set(self.policy["auxiliary"]["slots"]), supported_reasoning_slots=set(self.policy["auxiliary"]["slots"]))

    def test_hash_race_refuses_apply(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            config = home / "config.yaml"
            self.m.dump_yaml(config, self.sample())
            self.write_auth(home)
            with self.assertRaisesRegex(RuntimeError, "changed since audit"):
                self.m.process_config(home, self.policy, apply=True, dry_run=False, prune_retired=True, expected_hash="0" * 64, supported_slots=set(self.policy["auxiliary"]["slots"]), supported_reasoning_slots=set(self.policy["auxiliary"]["slots"]))

    def test_apply_refuses_missing_required_credentials(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            config = home / "config.yaml"
            self.m.dump_yaml(config, self.sample())
            self.write_auth(home, nous=0)
            with self.assertRaisesRegex(RuntimeError, "missing credentials: nous"):
                self.m.process_config(home, self.policy, apply=True, dry_run=False, prune_retired=True, expected_hash=self.m.sha256_file(config), supported_slots=set(self.policy["auxiliary"]["slots"]), supported_reasoning_slots=set(self.policy["auxiliary"]["slots"]))

    def test_process_config_requires_explicit_reasoning_capability(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            config = home / "config.yaml"
            self.m.dump_yaml(config, self.sample())
            self.write_auth(home)
            with self.assertRaises(TypeError):
                self.m.process_config(
                    home, self.policy, apply=False, dry_run=False, prune_retired=True,
                    expected_hash=None,
                    supported_slots=set(self.policy["auxiliary"]["slots"]),
                )

    def test_report_redacts_secret_values_and_refs(self):
        report = self.m.build_report(self.sample(), self.policy, target="test", supported_slots=set(self.policy["auxiliary"]["slots"]), prune_retired=True)
        text = json.dumps(report)
        self.assertNotIn("op://", text)
        self.assertNotIn("hidden", text)
        self.assertNotIn("keep-me", text)
        self.assertIn("NVIDIA_API_KEY", text)

    def test_auth_pool_counts_use_pool_cardinality_only(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            (home / "auth.json").write_text(json.dumps({
                "credential_pool": {
                    "nous": [{"label": "private", "access_token": "secret"}],
                    "opencode-go": [{"secret_fingerprint": "private"}],
                    "nvidia": [],
                }
            }), encoding="utf-8")
            self.assertEqual(self.m._auth_pool_counts(home), {"nous": 1, "opencode-go": 1, "nvidia": 0})

    def test_policy_rejects_slot_missing_model(self):
        policy = json.loads(json.dumps(self.policy))
        del policy["auxiliary"]["slots"]["curator"]["model"]
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "curator.*model"):
                self.m.load_policy(path)

    def test_policy_rejects_sensitive_extra_body(self):
        policy = json.loads(json.dumps(self.policy))
        policy["auxiliary"]["slots"]["curator"]["extra_body"] = {"api_key": "literal"}
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "secret-bearing"):
                self.m.load_policy(path)

    def test_policy_credential_env_mapping_drives_gate(self):
        policy = json.loads(json.dumps(self.policy))
        policy["delegation"]["provider"] = "synthetic-provider"
        policy["credential_env"]["synthetic-provider"] = "SYNTHETIC_API_KEY"
        self.assertNotIn(
            "synthetic-provider",
            self.m._missing_credentials(policy, {}, ["SYNTHETIC_API_KEY"]),
        )

    def test_legacy_auth_shape_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            (home / "auth.json").write_text(json.dumps({
                "legacy": [{"provider": "nous", "access_token": "secret"}]
            }), encoding="utf-8")
            self.assertEqual(self.m._auth_pool_counts(home), {})

    def test_report_redacts_nested_secret_keys(self):
        config = self.sample()
        config["auxiliary"]["curator"]["extra_body"] = {
            "thinking": {"type": "disabled"},
            "api_key": "must-not-appear",
        }
        report = self.m.build_report(
            config, self.policy, target="test",
            supported_slots=set(self.policy["auxiliary"]["slots"]),
            prune_retired=True,
        )
        self.assertNotIn("must-not-appear", json.dumps(report))
        self.assertIn("[REDACTED]", json.dumps(report))

    def test_policy_has_exact_role_routes(self):
        slots = self.policy["auxiliary"]["slots"]
        self.assertEqual(slots["curator"]["model"], "kimi-k2.6")
        self.assertEqual(slots["curator"]["reasoning_effort"], "none")
        self.assertEqual(slots["curator"]["remove_keys"], ["extra_body"])
        self.assertNotIn("extra_body", slots["curator"])
        self.assertEqual(slots["kanban_decomposer"]["model"], "qwen3.7-plus")
        self.assertEqual(self.policy["delegation"]["model"], "kimi-k2.7-code")
        self.assertEqual(self.policy["delegation"]["reasoning_effort"], "medium")
        self.assertEqual(self.policy["fallback_providers"][1], {"provider": "nous", "model": "openai/gpt-5.6-sol"})

    def test_policy_has_exact_15_task_reasoning_matrix_plus_inherited_review(self):
        slots = self.policy["auxiliary"]["slots"]
        self.assertEqual(self.policy["version"], 3)
        self.assertEqual(set(slots), set(EXPECTED_REASONING) | {"background_review"})
        self.assertEqual(
            {name: route["reasoning_effort"] for name, route in slots.items() if "reasoning_effort" in route},
            EXPECTED_REASONING,
        )
        self.assertEqual(slots["background_review"], {"remove_keys": ["reasoning_effort"]})
        for name in ("background_review", "moa_reference", "moa_aggregator"):
            self.assertNotIn("provider", slots[name])
            self.assertNotIn("model", slots[name])
            self.assertNotIn("fallback_chain", slots[name])

    def test_policy_rejects_missing_or_invalid_reasoning_effort(self):
        for value in (None, "unsupported"):
            policy = json.loads(json.dumps(self.policy))
            if value is None:
                del policy["auxiliary"]["slots"]["vision"]["reasoning_effort"]
            else:
                policy["auxiliary"]["slots"]["vision"]["reasoning_effort"] = value
            with tempfile.TemporaryDirectory() as td:
                path = Path(td) / "policy.json"
                path.write_text(json.dumps(policy), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "vision.*reasoning_effort"):
                    self.m.load_policy(path)

    def test_policy_requires_background_review_inheritance_exception(self):
        for route in ({"reasoning_effort": "medium"}, {}, {"remove_keys": []}):
            policy = json.loads(json.dumps(self.policy))
            policy["auxiliary"]["slots"]["background_review"] = route
            with tempfile.TemporaryDirectory() as td:
                path = Path(td) / "policy.json"
                path.write_text(json.dumps(policy), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "background_review"):
                    self.m.load_policy(path)

    def test_policy_rejects_explicit_reasoning_wire_override(self):
        policy = json.loads(json.dumps(self.policy))
        policy["auxiliary"]["slots"]["approval"]["extra_body"] = {
            "reasoning": {"effort": "high"}
        }
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "approval.*extra_body.reasoning"):
                self.m.load_policy(path)

    def test_target_reasoning_wire_override_blocks_reconcile(self):
        config = self.sample()
        config["auxiliary"]["approval"] = {
            "provider": "auto",
            "model": "",
            "extra_body": {"reasoning": {"effort": "high"}},
        }
        with self.assertRaisesRegex(ValueError, "approval.*extra_body.reasoning"):
            self.m.reconcile_config(
                config,
                self.policy,
                supported_slots=set(self.policy["auxiliary"]["slots"]),
                prune_retired=False,
            )

    def test_reasoning_only_slots_do_not_add_provider_requirements(self):
        providers = self.m._required_providers(self.policy)
        self.assertNotIn("auto", providers)
        self.assertEqual(
            {key for key in self.policy["auxiliary"]["slots"]["background_review"]},
            {"remove_keys"},
        )

    def test_inherited_background_review_does_not_require_reasoning_capability(self):
        supported = set(self.policy["auxiliary"]["slots"])
        supported_reasoning = supported - {"background_review"}
        report = self.m.build_report(
            self.sample(),
            self.policy,
            target="test",
            supported_slots=supported,
            supported_reasoning_slots=supported_reasoning,
            prune_retired=True,
        )
        self.assertTrue(report["reasoning_effort_supported"])
        self.assertEqual(report["reasoning_effort_missing_slots"], [])

    def test_apply_blocks_when_runtime_lacks_reasoning_capability(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            config = home / "config.yaml"
            self.m.dump_yaml(config, self.sample())
            self.write_auth(home)
            supported = set(self.policy["auxiliary"]["slots"])
            supported_reasoning = supported - {"vision"}
            report = self.m.process_config(
                home,
                self.policy,
                apply=False,
                dry_run=False,
                prune_retired=True,
                expected_hash=None,
                supported_slots=supported,
                supported_reasoning_slots=supported_reasoning,
            )
            self.assertFalse(report["reasoning_effort_supported"])
            self.assertEqual(report["reasoning_effort_missing_slots"], ["vision"])
            with self.assertRaisesRegex(RuntimeError, "reasoning_effort.*vision"):
                self.m.process_config(
                    home,
                    self.policy,
                    apply=True,
                    dry_run=False,
                    prune_retired=True,
                    expected_hash=report["audited_hash"],
                    supported_slots=supported,
                    supported_reasoning_slots=supported_reasoning,
                )

    def test_posix_target_python_prefers_hermes_venv(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            python = home / "hermes-agent" / "venv" / "bin" / "python3"
            python.parent.mkdir(parents=True)
            python.write_text("", encoding="utf-8")
            os.chmod(python, 0o755)
            self.assertEqual(self.m.target_python(home), str(python))

    def test_script_compiles_under_target_python(self):
        python = self.m.target_python(Path.home() / ".hermes")
        result = subprocess.run([python, "-m", "py_compile", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_docker_ssh_is_agent_independent(self):
        with tempfile.TemporaryDirectory() as td:
            identity = Path(td) / "fleet-test-key"
            identity.write_text("synthetic private key", encoding="utf-8")
            identity.chmod(0o600)
            config = self.target_data()["docker"]
            config["identity_file"] = str(identity)
            args = self.m.docker_ssh_args(config)
            self.assertIn("BatchMode=yes", args)
            self.assertIn("IdentitiesOnly=yes", args)
            self.assertIn("IdentityAgent=none", args)
            self.assertIn(str(identity), args)
            self.assertEqual(args[-1], "docker.example")

    def test_docker_ssh_rejects_permissive_private_key(self):
        with tempfile.TemporaryDirectory() as td:
            identity = Path(td) / "fleet-test-key"
            identity.write_text("synthetic private key", encoding="utf-8")
            identity.chmod(0o644)
            config = self.target_data()["docker"]
            config["identity_file"] = str(identity)
            with self.assertRaisesRegex(ValueError, "private key permissions"):
                self.m.docker_ssh_args(config)

    def test_windows_powershell_does_not_interpolate_script_path(self):
        path = "C:\\odd'path\\$name`tick\nsegment\\tool.py"
        ps = self.m._windows_powershell(path, "safe-payload_123=")
        self.assertNotIn(path, ps)
        self.assertIn(base64.b64encode(path.encode("utf-8")).decode(), ps)
        self.assertIn("FromBase64String", ps)

    def test_target_file_drives_remote_paths(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "targets.json"
            path.write_text(json.dumps(self.target_data()), encoding="utf-8")
            targets = self.m.load_targets(path)
            self.assertEqual(targets["docker"]["python"], "/app/venv/bin/python3")
            self.assertEqual(targets["macos"]["ssh_host"], "operator@mac.example")

    def test_target_file_rejects_shell_injection(self):
        data = self.target_data()
        data["docker"]["compose_dir"] = "/srv/agent;touch-pwned"
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "targets.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unsafe compose_dir"):
                self.m.load_targets(path)

    def test_target_file_rejects_unsafe_ssh_host(self):
        data = self.target_data()
        data["docker"]["ssh_host"] = "-oProxyCommand=bad"
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "targets.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unsafe ssh_host"):
                self.m.load_targets(path)

    def test_expected_hash_parser_validates_target_and_digest(self):
        digest = "a" * 64
        self.assertEqual(self.m._expected_hash_map([f"wsl={digest}"]), {"wsl": digest})
        with self.assertRaisesRegex(ValueError, "TARGET=64_HEX_SHA256"):
            self.m._expected_hash_map(["wsl=short"])

    def test_windows_home_requires_localappdata(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "LOCALAPPDATA"):
                self.m._resolve_home("windows")

    def test_missing_remote_target_config_is_explicit(self):
        with self.assertRaisesRegex(RuntimeError, "missing host-local target config"):
            self.m._target_config({}, "docker")


if __name__ == "__main__":
    unittest.main(verbosity=2)
