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
    RUNTIME_PROFILE_SOURCE,
    SWIFT_TOOL_ENV_SOURCE,
    XCODE_VERSION_SOURCE,
    base_env,
    write_executable,
)

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
            shutil.copy(RUNTIME_PROFILE_SOURCE, lib_root / "runtime-profile.sh")
            write_executable(fake_post_generate, "#!/bin/bash\nset -euo pipefail\n")
            fake_patcher.write_text("# test\n")
            write_executable(
                fake_tuist,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "env | sort > \"$CAPTURED_TUIST_ENV\"\n"
                "printf '%s\\n' \"$*\" > \"$CAPTURED_TUIST_ARGS\"\n",
            )

            env = base_env()
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
            shutil.copy(RUNTIME_PROFILE_SOURCE, lib_root / "runtime-profile.sh")
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

            env = base_env()
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

    def test_profile_scoped_non_owner_lane_refuses_to_regenerate_shared_project(
        self,
    ) -> None:
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
            fake_tuist = temp_root / "fake-tuist.sh"
            captured_args_path = temp_root / "captured-tuist-args.txt"

            lib_root.mkdir(parents=True)
            tuist_root.mkdir(parents=True)
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
            (app_root / "Tuist.swift").write_text("// test\n")
            shutil.copy(GENERATE_SOURCE, generated_script)
            generated_script.chmod(generated_script.stat().st_mode | stat.S_IXUSR)
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, generated_helper)
            shutil.copy(RUNTIME_PROFILE_SOURCE, lib_root / "runtime-profile.sh")
            write_executable(fake_post_generate, "#!/bin/bash\nset -euo pipefail\n")
            fake_patcher.write_text("# test\n")
            write_executable(
                fake_tuist,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$*\" > \"$CAPTURED_TUIST_ARGS\"\n",
            )

            env = base_env()
            env.update(
                {
                    "CAPTURED_TUIST_ARGS": str(captured_args_path),
                    "HARNESS_MONITOR_RUNTIME_PROFILE": "agent-foo",
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

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(
                "must not regenerate the shared Harness Monitor Xcode project",
                completed.stderr,
            )
            self.assertFalse(
                captured_args_path.exists(),
                "non-owner profile lane must fail before invoking tuist",
            )

    def test_profile_scoped_non_owner_lane_skips_regenerate_when_pbxproj_is_fresh(
        self,
    ) -> None:
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
            fake_tuist = temp_root / "fake-tuist.sh"
            marker_path = temp_root / "post-generate.marker"
            captured_args_path = temp_root / "captured-tuist-args.txt"

            lib_root.mkdir(parents=True)
            (tuist_root / ".build").mkdir(parents=True)
            build_settings = tuist_root / "ProjectDescriptionHelpers" / "BuildSettings.swift"
            build_settings.parent.mkdir(parents=True, exist_ok=True)
            build_settings.write_text("// test\n")
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
            shutil.copy(GENERATE_SOURCE, generated_script)
            generated_script.chmod(generated_script.stat().st_mode | stat.S_IXUSR)
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, generated_helper)
            shutil.copy(RUNTIME_PROFILE_SOURCE, lib_root / "runtime-profile.sh")
            write_executable(
                fake_post_generate,
                "#!/bin/bash\nset -euo pipefail\n: > \"$POST_GENERATE_MARKER\"\n",
            )
            fake_patcher.write_text("# test\n")
            write_executable(
                fake_tuist,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$*\" > \"$CAPTURED_TUIST_ARGS\"\n",
            )

            pbxproj_path = app_root / "HarnessMonitor.xcodeproj" / "project.pbxproj"
            workspace_path = (
                app_root / "HarnessMonitor.xcworkspace" / "contents.xcworkspacedata"
            )
            pbxproj_path.parent.mkdir(parents=True, exist_ok=True)
            workspace_path.parent.mkdir(parents=True, exist_ok=True)
            pbxproj_path.write_text("// generated\n")
            workspace_path.write_text("<Workspace/>\n")

            stale_timestamp = 1_000_000_000
            fresh_input_timestamp = stale_timestamp + 100
            fresh_pbxproj_timestamp = fresh_input_timestamp + 100

            for input_path in (
                app_root / "Project.swift",
                build_settings,
                fake_post_generate,
                fake_patcher,
                tuist_root / "Package.swift",
            ):
                os.utime(input_path, (fresh_input_timestamp, fresh_input_timestamp))
            os.utime(workspace_path, (stale_timestamp, stale_timestamp))
            os.utime(
                pbxproj_path,
                (fresh_pbxproj_timestamp, fresh_pbxproj_timestamp),
            )

            env = base_env()
            env.update(
                {
                    "CAPTURED_TUIST_ARGS": str(captured_args_path),
                    "HARNESS_MONITOR_RUNTIME_PROFILE": "agent-foo",
                    "POST_GENERATE_MARKER": str(marker_path),
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
            self.assertTrue(marker_path.exists(), "post-generate should still run")
            self.assertFalse(
                captured_args_path.exists(),
                "fresh pbxproj should let non-owner lanes skip tuist generate",
            )


if __name__ == "__main__":
    unittest.main()
