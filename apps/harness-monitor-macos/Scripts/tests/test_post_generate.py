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
    PATCH_RUN_SCHEME_ENV_SOURCE,
    POST_GENERATE_SOURCE,
    PREPARE_APP_ENTITLEMENTS_SOURCE,
    MONITOR_LANES_SOURCE,
    SWIFT_TOOL_ENV_SOURCE,
    XCODE_VERSION_SOURCE,
    base_env,
    write_executable,
)

class PostGenerateScriptTests(unittest.TestCase):
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
            shutil.copy(PATCH_RUN_SCHEME_ENV_SOURCE, scripts_root / "patch-run-scheme-env.py")
            shutil.copy(SWIFT_TOOL_ENV_SOURCE, lib_root / "swift-tool-env.sh")
            shutil.copy(NON_INDEXABLE_ROOTS_SOURCE, lib_root / "non-indexable-roots.sh")
            shutil.copy(MONITOR_LANES_SOURCE, lib_root / "monitor-lanes.sh")
            shutil.copy(XCODE_VERSION_SOURCE, lib_root / "xcode-version.sh")
            scheme_root = app_root / "HarnessMonitor.xcodeproj" / "xcshareddata" / "xcschemes"
            scheme_root.mkdir(parents=True)
            for scheme_name in (
                "HarnessMonitor.xcscheme",
                "HarnessMonitor (External Daemon).xcscheme",
            ):
                (scheme_root / scheme_name).write_text(
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

            env = base_env()
            env.update(
                {
                    "HARNESS_MONITOR_APP_ROOT": str(app_root),
                    "HARNESS_MONITOR_OWNS_WORKSPACE": "1",
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
            self.assertIn(
                '"build_root": "../../xcode-derived"',
                (app_root / "buildServer.json").read_text(),
            )
            self.assertIn(
                '"build_root": "xcode-derived"',
                (repo_root / "buildServer.json").read_text(),
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
            canonical_repo_root = repo_root.resolve()
            default_lane = "repo-" + subprocess.check_output(
                [
                    "shasum",
                    "-a",
                    "256",
                ],
                input=str(canonical_repo_root),
                text=True,
            ).split()[0][:8]
            for scheme_name in (
                "HarnessMonitor.xcscheme",
                "HarnessMonitor (External Daemon).xcscheme",
            ):
                with self.subTest(scheme=scheme_name):
                    scheme = (scheme_root / scheme_name).read_text()
                    self.assertIn('key="HARNESS_MONITOR_RUNTIME_LANE"', scheme)
                    self.assertIn(f'value="{default_lane}"', scheme)
                    self.assertIn('key="HARNESS_DAEMON_DATA_HOME"', scheme)
                    self.assertIn(f"runtime-lanes/{default_lane}", scheme)
                    self.assertIn('key="HARNESS_CODEX_WS_PORT"', scheme)

    def test_post_generate_keeps_tracked_build_server_stable_when_build_lane_is_set(
        self,
    ) -> None:
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
            shutil.copy(MONITOR_LANES_SOURCE, lib_root / "monitor-lanes.sh")

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

            env = base_env()
            env.update(
                {
                    "HARNESS_MONITOR_APP_ROOT": str(app_root),
                    "HARNESS_MONITOR_OWNS_WORKSPACE": "1",
                    "HARNESS_MONITOR_BUILD_LANE": "Bart Dev",
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

            laned_root = repo_root / "xcode-derived-lanes" / "bart-dev"

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
                    self.assertIn(str(laned_root), settings_path.read_text())

            self.assertIn(
                '"build_root": "../../xcode-derived"',
                (app_root / "buildServer.json").read_text(),
            )
            self.assertIn(
                '"build_root": "xcode-derived"',
                (repo_root / "buildServer.json").read_text(),
            )

            generated_entitlements_dir = (
                laned_root
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
            self.assertTrue((laned_root / ".metadata_never_index").exists())


if __name__ == "__main__":
    unittest.main()
