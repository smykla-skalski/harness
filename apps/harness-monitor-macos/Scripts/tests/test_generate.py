from __future__ import annotations

import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
GENERATE_SOURCE = APP_ROOT / "Scripts" / "generate.sh"
POST_GENERATE_SOURCE = APP_ROOT / "Scripts" / "post-generate.sh"
PREPARE_APP_ENTITLEMENTS_SOURCE = APP_ROOT / "Scripts" / "prepare-app-entitlements.sh"
SWIFT_TOOL_ENV_SOURCE = APP_ROOT / "Scripts" / "lib" / "swift-tool-env.sh"
NON_INDEXABLE_ROOTS_SOURCE = APP_ROOT / "Scripts" / "lib" / "non-indexable-roots.sh"
XCODE_VERSION_SOURCE = APP_ROOT / "Scripts" / "lib" / "xcode-version.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class GenerateScriptTests(unittest.TestCase):
    def test_post_generate_keeps_mcp_servers_workspace_path_repo_relative(self) -> None:
        source = POST_GENERATE_SOURCE.read_text()

        self.assertNotIn("../../../mcp-servers", source)

    def test_unsets_xcode_only_swift_debug_environment_before_tuist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "HarnessMonitor"
            scripts_root = app_root / "Scripts"
            lib_root = scripts_root / "lib"
            tuist_root = app_root / "Tuist"
            generated_script = scripts_root / "generate.sh"
            generated_helper = lib_root / "swift-tool-env.sh"
            fake_post_generate = scripts_root / "post-generate.sh"
            fake_patcher = scripts_root / "patch-tuist-pbxproj.py"
            fake_tuist = temp_root / "fake-tuist.sh"
            captured_env_path = temp_root / "captured-tuist-env.txt"
            captured_args_path = temp_root / "captured-tuist-args.txt"

            lib_root.mkdir(parents=True)
            (tuist_root / ".build").mkdir(parents=True)
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
            shutil.copy(GENERATE_SOURCE, generated_script)
            generated_script.chmod(generated_script.stat().st_mode | stat.S_IXUSR)
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, generated_helper)
            write_executable(fake_post_generate, "#!/bin/bash\nset -euo pipefail\n")
            fake_patcher.write_text("# test\n")
            write_executable(
                fake_tuist,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "env | sort > \"$CAPTURED_TUIST_ENV\"\n"
                "printf '%s\\n' \"$*\" > \"$CAPTURED_TUIST_ARGS\"\n",
            )

            env = os.environ.copy()
            env.update(
                {
                    "CAPTURED_TUIST_ENV": str(captured_env_path),
                    "CAPTURED_TUIST_ARGS": str(captured_args_path),
                    "SWIFT_DEBUG_INFORMATION_FORMAT": "dwarf",
                    "SWIFT_DEBUG_INFORMATION_VERSION": "5",
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
            self.assertEqual(
                captured_args_path.read_text().strip(),
                f"generate --no-open --path {app_root}",
            )
            captured_env = captured_env_path.read_text()
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_FORMAT=", captured_env)
            self.assertNotIn("SWIFT_DEBUG_INFORMATION_VERSION=", captured_env)

    def test_runs_post_generate_even_when_tuist_regeneration_is_not_needed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root = temp_root / "repo"
            app_root = repo_root / "apps" / "harness-monitor-macos"
            scripts_root = app_root / "Scripts"
            lib_root = scripts_root / "lib"
            tuist_root = app_root / "Tuist"
            generated_script = scripts_root / "generate.sh"
            generated_helper = lib_root / "swift-tool-env.sh"
            fake_post_generate = scripts_root / "post-generate.sh"
            fake_patcher = scripts_root / "patch-tuist-pbxproj.py"
            marker_path = temp_root / "post-generate.marker"

            lib_root.mkdir(parents=True)
            (tuist_root / ".build").mkdir(parents=True)
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
            (app_root / "Tuist.swift").write_text("// test\n")
            shutil.copy(GENERATE_SOURCE, generated_script)
            generated_script.chmod(generated_script.stat().st_mode | stat.S_IXUSR)
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, generated_helper)
            write_executable(
                fake_post_generate,
                "#!/bin/bash\nset -euo pipefail\n: > \"$POST_GENERATE_MARKER\"\n",
            )
            fake_patcher.write_text("# test\n")

            outputs = (
                app_root / "HarnessMonitor.xcodeproj" / "project.pbxproj",
                app_root
                / "HarnessMonitor.xcodeproj"
                / "project.xcworkspace"
                / "xcshareddata"
                / "WorkspaceSettings.xcsettings",
                app_root / "HarnessMonitor.xcworkspace" / "contents.xcworkspacedata",
                app_root
                / "HarnessMonitor.xcworkspace"
                / "xcshareddata"
                / "WorkspaceSettings.xcsettings",
                app_root / "buildServer.json",
                repo_root / "buildServer.json",
            )
            for output in outputs:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text("generated\n")

            stale_timestamp = 1_000_000_000
            fresh_timestamp = stale_timestamp + 100
            for input_path in (
                app_root / "Project.swift",
                app_root / "Tuist.swift",
                fake_post_generate,
                fake_patcher,
                tuist_root / "Package.swift",
            ):
                os.utime(input_path, (stale_timestamp, stale_timestamp))
            for output in outputs:
                os.utime(output, (fresh_timestamp, fresh_timestamp))

            env = os.environ.copy()
            env.update(
                {
                    "PATH": "/usr/bin:/bin",
                    "POST_GENERATE_MARKER": str(marker_path),
                    "TMPDIR": str(temp_root),
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
            self.assertTrue(marker_path.exists(), "post-generate should still run")

    def test_post_generate_writes_internal_workspace_settings_and_seeded_entitlements(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root = temp_root / "repo"
            app_root = repo_root / "apps" / "harness-monitor-macos"
            scripts_root = app_root / "Scripts"
            lib_root = scripts_root / "lib"
            generated_post_generate = scripts_root / "post-generate.sh"
            generated_prepare_entitlements = scripts_root / "prepare-app-entitlements.sh"

            lib_root.mkdir(parents=True)
            shutil.copy(POST_GENERATE_SOURCE, generated_post_generate)
            generated_post_generate.chmod(
                generated_post_generate.stat().st_mode | stat.S_IXUSR
            )
            shutil.copy(PREPARE_APP_ENTITLEMENTS_SOURCE, generated_prepare_entitlements)
            generated_prepare_entitlements.chmod(
                generated_prepare_entitlements.stat().st_mode | stat.S_IXUSR
            )
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, lib_root / "swift-tool-env.sh")
            shutil.copy(NON_INDEXABLE_ROOTS_SOURCE, lib_root / "non-indexable-roots.sh")
            shutil.copy(XCODE_VERSION_SOURCE, lib_root / "xcode-version.sh")

            monitor_entitlements = {
                "com.apple.security.application-groups": ["Q498EB36N4.io.harnessmonitor"],
                "monitor": True,
            }
            ui_test_host_entitlements = {
                "com.apple.security.application-groups": ["Q498EB36N4.io.harnessmonitor"],
                "ui-test-host": True,
            }
            (app_root / "HarnessMonitor.entitlements").write_bytes(
                plistlib.dumps(monitor_entitlements)
            )
            (app_root / "HarnessMonitorUITestHost.entitlements").write_bytes(
                plistlib.dumps(ui_test_host_entitlements)
            )

            env = os.environ.copy()
            env.update(
                {
                    "HARNESS_MONITOR_APP_ROOT": str(app_root),
                    "HARNESS_MONITOR_SKIP_VERSION_SYNC": "1",
                    "HARNESS_MONITOR_XCODE_DTXCODE": "2640",
                    "REPO_ROOT": str(repo_root),
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                ["bash", str(generated_post_generate)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)

            settings_paths = (
                app_root
                / "HarnessMonitor.xcworkspace"
                / "xcshareddata"
                / "WorkspaceSettings.xcsettings",
                app_root
                / "HarnessMonitor.xcodeproj"
                / "project.xcworkspace"
                / "xcshareddata"
                / "WorkspaceSettings.xcsettings",
            )
            for settings_path in settings_paths:
                with self.subTest(settings_path=settings_path):
                    self.assertTrue(settings_path.exists())
                    self.assertIn(
                        str(repo_root / "xcode-derived"),
                        settings_path.read_text(),
                    )

            generated_entitlements_dir = (
                repo_root
                / "xcode-derived"
                / "Build"
                / "Intermediates.noindex"
                / "HarnessMonitor.build"
                / "GeneratedAppEntitlements"
            )
            self.assertEqual(
                plistlib.loads(
                    (
                        generated_entitlements_dir
                        / "HarnessMonitor.codesign.entitlements"
                    ).read_bytes()
                ),
                monitor_entitlements,
            )
            self.assertEqual(
                plistlib.loads(
                    (
                        generated_entitlements_dir
                        / "HarnessMonitorUITestHost.codesign.entitlements"
                    ).read_bytes()
                ),
                ui_test_host_entitlements,
            )
            self.assertTrue(
                (repo_root / "xcode-derived" / ".metadata_never_index").exists()
            )

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
            write_executable(fake_post_generate, "#!/bin/bash\nset -euo pipefail\n")
            fake_patcher.write_text("# test\n")
            write_executable(
                fake_tuist,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$*\" >> \"$CAPTURED_TUIST_ARGS\"\n",
            )

            env = os.environ.copy()
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
