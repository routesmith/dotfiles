#!/usr/bin/env python3
"""Regression tests for path-audit."""

from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
PATH_AUDIT = REPO / "dot_zsh" / "bin" / "executable_path-audit"


def load_path_audit():
    loader = importlib.machinery.SourceFileLoader("path_audit", str(PATH_AUDIT))
    spec = importlib.util.spec_from_loader("path_audit", loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    loader.exec_module(module)
    return module


class PathAuditSystemSourcesTests(unittest.TestCase):
    def test_macos_system_path_files_are_reported_for_present_and_missing_entries(self) -> None:
        pa = load_path_audit()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "etc" / "paths.d").mkdir(parents=True)
            (root / "etc" / "paths").write_text("/usr/bin\n/Library/Apple/usr/bin\n", encoding="utf-8")
            (root / "etc" / "paths.d" / "40-cryptex").write_text(
                "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin\n",
                encoding="utf-8",
            )

            sources = pa.collect_system_path_sources(system_root=root, platform_name="darwin", is_wsl=False)
            entries = pa.build_entries(
                "/usr/bin:/Library/Apple/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin",
                system_path_sources=sources,
            )

        by_raw = {entry.raw: entry for entry in entries}
        self.assertEqual(by_raw["/usr/bin"].system_sources, ("/etc/paths",))
        self.assertEqual(by_raw["/Library/Apple/usr/bin"].system_sources, ("/etc/paths",))
        self.assertEqual(
            by_raw["/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin"].system_sources,
            ("/etc/paths.d/40-cryptex",),
        )

    def test_wsl_system_path_sources_include_etc_environment_and_windows_bridge(self) -> None:
        pa = load_path_audit()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "etc").mkdir(parents=True)
            (root / "etc" / "environment").write_text(
                'PATH="/usr/local/bin:/custom/system/bin"\n',
                encoding="utf-8",
            )
            (root / "etc" / "wsl.conf").write_text("[interop]\nappendWindowsPath = true\n", encoding="utf-8")

            sources = pa.collect_system_path_sources(system_root=root, platform_name="linux", is_wsl=True)
            entries = pa.build_entries(
                "/usr/local/bin:/custom/system/bin:/mnt/c/Windows/System32",
                system_path_sources=sources,
            )

        by_raw = {entry.raw: entry for entry in entries}
        self.assertEqual(by_raw["/usr/local/bin"].system_sources, ("/etc/environment",))
        self.assertEqual(by_raw["/custom/system/bin"].system_sources, ("/etc/environment",))
        self.assertEqual(by_raw["/mnt/c/Windows/System32"].system_sources, ("wsl:appendWindowsPath",))

    def test_system_added_missing_paths_are_not_plain_cleanup_clues(self) -> None:
        pa = load_path_audit()
        entries = pa.build_entries(
            "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin",
            system_path_sources={
                "/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin": (
                    "/etc/paths.d/10-cryptex",
                )
            },
        )

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            pa.render_cleanup_clues(entries)

        rendered = out.getvalue()
        self.assertIn("system-added missing", rendered)
        self.assertIn("/etc/paths.d/10-cryptex", rendered)
        self.assertNotIn("PATH #1: missing: /var/run", rendered)


if __name__ == "__main__":
    unittest.main(verbosity=2)
