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
    PATCH_RUN_SCHEME_ENV_SOURCE,
    SWIFT_TOOL_ENV_SOURCE,
    XCODE_VERSION_SOURCE,
    base_env,
    write_executable,
)

class GenerateScriptTests(unittest.TestCase):
    def test_post_generate_keeps_mcp_servers_workspace_path_repo_relative(self) -> None:
        source = POST_GENERATE_SOURCE.read_text()

        self.assertNotIn("../../../mcp-servers", source)

    def test_project_manifest_does_not_hardcode_personal_runtime_lane(self) -> None:
        source = (APP_ROOT / "Project.swift").read_text()

        self.assertNotIn("bartsmykla", source)

    def test_patch_run_scheme_env_updates_launch_environment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            scheme_path = temp_root / "HarnessMonitor.xcscheme"
            scheme_path.write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <LaunchAction buildConfiguration="Debug">
      <CommandLineArguments>
      </CommandLineArguments>
      <EnvironmentVariables>
         <EnvironmentVariable key="HARNESS_OTEL_EXPORT" value="1" isEnabled="YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
   </LaunchAction>
</Scheme>
"""
            )

            completed = subprocess.run(
                [
                    "python3",
                    str(PATCH_RUN_SCHEME_ENV_SOURCE),
                    str(scheme_path),
                    "HARNESS_MONITOR_RUNTIME_LANE=harness-deadbeef",
                    "HARNESS_DAEMON_DATA_HOME=/tmp/harness-lane",
                    "HARNESS_CODEX_WS_PORT=12345",
                    "HARNESS_EMPTY_TEST_VALUE=",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            scheme = scheme_path.read_text()
            self.assertIn('key="HARNESS_OTEL_EXPORT"', scheme)
            self.assertIn('key="HARNESS_MONITOR_RUNTIME_LANE"', scheme)
            self.assertIn('value="harness-deadbeef"', scheme)
            self.assertIn('key="HARNESS_DAEMON_DATA_HOME"', scheme)
            self.assertIn('value="/tmp/harness-lane"', scheme)
            self.assertIn('key="HARNESS_CODEX_WS_PORT"', scheme)
            self.assertIn('value="12345"', scheme)
            self.assertIn('key="HARNESS_EMPTY_TEST_VALUE"', scheme)
            self.assertIn('value=""', scheme)

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
            (tuist_root / ".build" / "checkouts" / "dep").mkdir(parents=True)
            (tuist_root / ".build" / "repositories" / "dep").mkdir(parents=True)
            (tuist_root / ".build" / "workspace-state.json").write_text("{}\n")
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
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
            runtime_lane = next(
                line.split("=", 1)[1]
                for line in captured_env.splitlines()
                if line.startswith("HARNESS_MONITOR_RUNTIME_LANE=")
            )
            self.assertIn(
                f"HARNESS_DAEMON_DATA_HOME={Path.home()}/Library/Group Containers/"
                f"Q498EB36N4.io.harnessmonitor/runtime-lanes/{runtime_lane}",
                captured_env,
            )
            self.assertIn("HARNESS_CODEX_WS_PORT=", captured_env)

    def test_runs_post_generate_even_when_tuist_regeneration_is_not_needed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root = temp_root / "repo"
            app_root = repo_root / "apps" / "harness-monitor"
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
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
            (app_root / "Tuist.swift").write_text("// test\n")
            shutil.copy(GENERATE_SOURCE, generated_script)
            generated_script.chmod(generated_script.stat().st_mode | stat.S_IXUSR)
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, generated_helper)
            shutil.copy(MONITOR_LANES_SOURCE, lib_root / "monitor-lanes.sh")
            write_executable(
                fake_post_generate,
                "#!/bin/bash\nset -euo pipefail\n: > \"$POST_GENERATE_MARKER\"\n",
            )
            fake_patcher.write_text("# test\n")
            write_executable(
                fake_tuist,
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "if [[ \"${1:-}\" == \"version\" ]]; then\n"
                "  printf '4.0.0-test\\n'\n"
                "  exit 0\n"
                "fi\n"
                "printf '%s\\n' \"$*\" >> \"$CAPTURED_TUIST_ARGS\"\n",
            )

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
                    "CAPTURED_TUIST_ARGS": str(captured_args_path),
                    "POST_GENERATE_MARKER": str(marker_path),
                    "TMPDIR": str(temp_root),
                    "TUIST_BIN": str(fake_tuist),
                }
            )

            # Prime freshness state.
            priming_run = subprocess.run(
                ["bash", str(generated_script)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(priming_run.returncode, 0, priming_run.stderr)

            if marker_path.exists():
                marker_path.unlink()
            if captured_args_path.exists():
                captured_args_path.unlink()

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
                "freshness state should skip tuist install/generate",
            )

    def test_legacy_profile_env_refuses_to_regenerate_project(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root = temp_root / "repo"
            app_root = repo_root / "apps" / "harness-monitor"
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
            shutil.copy(MONITOR_LANES_SOURCE, lib_root / "monitor-lanes.sh")
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
                "HARNESS_MONITOR_RUNTIME_PROFILE is no longer supported",
                completed.stderr,
            )
            self.assertFalse(
                captured_args_path.exists(),
                "legacy profile env must fail before invoking tuist",
            )

    def test_runtime_lane_skips_regenerate_when_pbxproj_is_fresh(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root = temp_root / "repo"
            app_root = repo_root / "apps" / "harness-monitor"
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
            shutil.copy(MONITOR_LANES_SOURCE, lib_root / "monitor-lanes.sh")
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
                    "HARNESS_MONITOR_RUNTIME_LANE": "agent-foo",
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
            self.assertTrue(captured_args_path.exists(), "priming run should invoke tuist")
            captured_args_path.unlink()

            # Second run with unchanged inputs should skip tuist regenerate.
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
                "freshness state should skip tuist generate",
            )

    def test_regenerates_when_tuist_input_file_is_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "repo" / "apps" / "harness-monitor"
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
            (tuist_root / ".build").mkdir(parents=True)
            helper_file = tuist_root / "ProjectDescriptionHelpers" / "BuildSettings.swift"
            helper_file.parent.mkdir(parents=True, exist_ok=True)
            helper_file.write_text("// test\n")
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
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
                "if [[ \"${1:-}\" == \"version\" ]]; then\n"
                "  printf '4.0.0-test\\n'\n"
                "  exit 0\n"
                "fi\n"
                "printf '%s\\n' \"$*\" >> \"$CAPTURED_TUIST_ARGS\"\n",
            )

            pbxproj_path = app_root / "HarnessMonitor.xcodeproj" / "project.pbxproj"
            workspace_path = app_root / "HarnessMonitor.xcworkspace" / "contents.xcworkspacedata"
            pbxproj_path.parent.mkdir(parents=True, exist_ok=True)
            workspace_path.parent.mkdir(parents=True, exist_ok=True)
            pbxproj_path.write_text("// generated\n")
            workspace_path.write_text("<Workspace/>\n")

            env = base_env()
            env.update(
                {
                    "CAPTURED_TUIST_ARGS": str(captured_args_path),
                    "TMPDIR": str(temp_root),
                    "TUIST_BIN": str(fake_tuist),
                }
            )

            priming = subprocess.run(
                ["bash", str(generated_script)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(priming.returncode, 0, priming.stderr)
            self.assertTrue(captured_args_path.exists())
            captured_args_path.unlink()

            helper_file.unlink()

            completed = subprocess.run(
                ["bash", str(generated_script)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(
                captured_args_path.exists(),
                "deleting a Tuist input file should invalidate freshness and regenerate",
            )

    def test_regenerates_when_tuist_env_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "repo" / "apps" / "harness-monitor"
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
            (tuist_root / ".build").mkdir(parents=True)
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
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
                "if [[ \"${1:-}\" == \"version\" ]]; then\n"
                "  printf '4.0.0-test\\n'\n"
                "  exit 0\n"
                "fi\n"
                "printf '%s\\n' \"$*\" >> \"$CAPTURED_TUIST_ARGS\"\n",
            )

            pbxproj_path = app_root / "HarnessMonitor.xcodeproj" / "project.pbxproj"
            workspace_path = app_root / "HarnessMonitor.xcworkspace" / "contents.xcworkspacedata"
            pbxproj_path.parent.mkdir(parents=True, exist_ok=True)
            workspace_path.parent.mkdir(parents=True, exist_ok=True)
            pbxproj_path.write_text("// generated\n")
            workspace_path.write_text("<Workspace/>\n")

            env = base_env()
            env.update(
                {
                    "CAPTURED_TUIST_ARGS": str(captured_args_path),
                    "TMPDIR": str(temp_root),
                    "TUIST_BIN": str(fake_tuist),
                }
            )

            priming = subprocess.run(
                ["bash", str(generated_script)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(priming.returncode, 0, priming.stderr)
            self.assertTrue(captured_args_path.exists())
            captured_args_path.unlink()

            env["DEVELOPER_DIR"] = "/Applications/Xcode-Other.app/Contents/Developer"

            completed = subprocess.run(
                ["bash", str(generated_script)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(
                captured_args_path.exists(),
                "generation environment drift should invalidate freshness and regenerate",
            )

    def test_runs_tuist_install_when_build_cache_is_present_but_dependency_state_is_missing(
        self,
    ) -> None:
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
            captured_args_path = temp_root / "captured-tuist-args.txt"

            lib_root.mkdir(parents=True)
            (tuist_root / ".build").mkdir(parents=True)
            (tuist_root / "Package.swift").write_text("// test\n")
            (app_root / "Project.swift").write_text("// test\n")
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
            self.assertEqual(
                captured_args_path.read_text().splitlines(),
                [
                    f"install --path {app_root}",
                    f"generate --no-open --path {app_root}",
                ],
            )


if __name__ == "__main__":
    unittest.main()
