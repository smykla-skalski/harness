from __future__ import annotations

import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from generate_test_support import (
    APP_ROOT,
    GENERATE_SOURCE,
    NON_INDEXABLE_ROOTS_SOURCE,
    POST_GENERATE_SOURCE,
    PREPARE_APP_ENTITLEMENTS_SOURCE,
    MONITOR_LANES_SOURCE,
    SWIFT_TOOL_ENV_SOURCE,
    XCODE_VERSION_SOURCE,
    base_env,
    write_executable,
)

class GenerateCleanupScriptTests(unittest.TestCase):
    def test_removes_legacy_spotlight_project_links_before_generation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "HarnessMonitor"
            repo_root = temp_root
            scripts_root = app_root / "Scripts"
            lib_root = scripts_root / "lib"
            tuist_root = app_root / "Tuist"
            hidden_app_root = (
                repo_root
                / ".spotlight-build-artifacts.noindex"
                / "apps"
                / "harness-monitor-macos"
            )
            generated_script = scripts_root / "generate.sh"
            generated_helper = lib_root / "swift-tool-env.sh"
            fake_post_generate = scripts_root / "post-generate.sh"
            fake_patcher = scripts_root / "patch-tuist-pbxproj.py"
            fake_tuist = temp_root / "fake-tuist.sh"
            captured_args_path = temp_root / "captured-tuist-args.txt"

            lib_root.mkdir(parents=True)
            tuist_root.mkdir(parents=True)
            hidden_tuist_build = hidden_app_root / "Tuist" / ".build"
            (hidden_app_root / "HarnessMonitor.xcodeproj").mkdir(parents=True)
            (hidden_app_root / "HarnessMonitor.xcworkspace" / "xcshareddata").mkdir(
                parents=True
            )
            hidden_tuist_build.mkdir(parents=True)
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
            (app_root / "buildServer.json").write_text("{}\n")
            (repo_root / "buildServer.json").write_text("{}\n")
            (hidden_app_root / "HarnessMonitor.xcodeproj" / "project.pbxproj").write_text(
                "// generated\n"
            )
            (
                hidden_app_root
                / "HarnessMonitor.xcworkspace"
                / "contents.xcworkspacedata"
            ).write_text("<Workspace/>\n")
            (
                hidden_app_root
                / "HarnessMonitor.xcworkspace"
                / "xcshareddata"
                / "WorkspaceSettings.xcsettings"
            ).write_text("<plist/>\n")
            (app_root / "HarnessMonitor.xcodeproj").symlink_to(
                hidden_app_root / "HarnessMonitor.xcodeproj"
            )
            (app_root / "HarnessMonitor.xcworkspace").symlink_to(
                hidden_app_root / "HarnessMonitor.xcworkspace"
            )
            (tuist_root / ".build").symlink_to(hidden_tuist_build)
            for name in (
                ".build",
                ".sourcekit-lsp",
                "Derived",
                "DerivedData",
                "build",
                "tmp",
                "xcode-derived",
            ):
                (app_root / name).symlink_to(hidden_app_root / name)
            for source_path, target_path in (
                (
                    app_root / "Tools" / "HarnessMonitorE2E" / ".build",
                    hidden_app_root / "Tools" / "HarnessMonitorE2E" / ".build",
                ),
                (
                    app_root / "Tools" / "HarnessMonitorPerf" / ".build",
                    hidden_app_root / "Tools" / "HarnessMonitorPerf" / ".build",
                ),
                (repo_root / ".cache", repo_root / ".spotlight-build-artifacts.noindex" / ".cache"),
                (
                    repo_root / ".claude" / "worktrees" / "tmp" / "xcode-derived",
                    repo_root
                    / ".spotlight-build-artifacts.noindex"
                    / ".claude"
                    / "worktrees"
                    / "tmp"
                    / "xcode-derived",
                ),
                (
                    repo_root / ".claude" / "worktrees" / "xcode-derived",
                    repo_root
                    / ".spotlight-build-artifacts.noindex"
                    / ".claude"
                    / "worktrees"
                    / "xcode-derived",
                ),
                (
                    repo_root / ".opencode" / "node_modules",
                    repo_root / ".spotlight-build-artifacts.noindex" / ".opencode" / "node_modules",
                ),
                (
                    repo_root / ".playwright-cli",
                    repo_root / ".spotlight-build-artifacts.noindex" / ".playwright-cli",
                ),
                (
                    repo_root / "_artifacts",
                    repo_root / ".spotlight-build-artifacts.noindex" / "_artifacts",
                ),
                (
                    repo_root / "mcp-servers" / "harness-monitor-registry" / ".build",
                    repo_root
                    / ".spotlight-build-artifacts.noindex"
                    / "mcp-servers"
                    / "harness-monitor-registry"
                    / ".build",
                ),
                (repo_root / "output", repo_root / ".spotlight-build-artifacts.noindex" / "output"),
            ):
                source_path.parent.mkdir(parents=True, exist_ok=True)
                source_path.symlink_to(target_path)
            shutil.copy(GENERATE_SOURCE, generated_script)
            generated_script.chmod(generated_script.stat().st_mode | stat.S_IXUSR)
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, generated_helper)
            shutil.copy(MONITOR_LANES_SOURCE, lib_root / "monitor-lanes.sh")
            write_executable(fake_post_generate, "#!/bin/bash\nset -euo pipefail\n")
            fake_patcher.write_text("# test\n")
            write_executable(
                fake_tuist,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$*\" >> \"$CAPTURED_TUIST_ARGS\"\n",
            )

            env = base_env()
            env.update(
                {
                    "CAPTURED_TUIST_ARGS": str(captured_args_path),
                    "TMPDIR": str(temp_root),
                    "TUIST_BIN": str(fake_tuist),
                }
            )

            completed = subprocess.run(
                ["bash", str(generated_script)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse((app_root / "HarnessMonitor.xcodeproj").is_symlink())
            self.assertFalse((app_root / "HarnessMonitor.xcworkspace").is_symlink())
            self.assertFalse((tuist_root / ".build").exists())
            for name in (
                ".build",
                ".sourcekit-lsp",
                "Derived",
                "DerivedData",
                "build",
                "tmp",
                "xcode-derived",
            ):
                self.assertFalse((app_root / name).exists(), name)
            for path in (
                app_root / "Tools" / "HarnessMonitorE2E" / ".build",
                app_root / "Tools" / "HarnessMonitorPerf" / ".build",
                repo_root / ".cache",
                repo_root / ".claude" / "worktrees" / "tmp" / "xcode-derived",
                repo_root / ".claude" / "worktrees" / "xcode-derived",
                repo_root / ".opencode" / "node_modules",
                repo_root / ".playwright-cli",
                repo_root / "_artifacts",
                repo_root / "mcp-servers" / "harness-monitor-registry" / ".build",
                repo_root / "output",
            ):
                self.assertFalse(path.exists(), str(path))
            self.assertEqual(
                captured_args_path.read_text().splitlines(),
                [
                    f"install --path {app_root}",
                    f"generate --no-open --path {app_root}",
                ],
            )


if __name__ == "__main__":
    unittest.main()
