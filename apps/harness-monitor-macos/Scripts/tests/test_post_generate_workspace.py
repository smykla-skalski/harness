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

class PostGenerateWorkspaceScriptTests(unittest.TestCase):
    def test_post_generate_restores_saved_user_workspace_settings(self) -> None:
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
            shutil.copy(
                APP_ROOT / "Scripts" / "lib" / "runtime-profile.sh",
                lib_root / "runtime-profile.sh",
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
            saved_profile_root = repo_root / "xcode-derived" / "profiles" / "bart-dev"
            (app_root / ".xcode-user-derived-data-path").write_text(
                f"{saved_profile_root}\n"
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
                    "USER": "monitor",
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

            shared_root = repo_root / "xcode-derived"
            shared_settings_paths = (
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
            for settings_path in shared_settings_paths:
                with self.subTest(settings_path=settings_path):
                    self.assertIn(str(shared_root), settings_path.read_text())

            user_settings_paths = (
                app_root
                / "HarnessMonitor.xcworkspace"
                / "xcuserdata"
                / "monitor.xcuserdatad"
                / "WorkspaceSettings.xcsettings",
                app_root
                / "HarnessMonitor.xcodeproj"
                / "project.xcworkspace"
                / "xcuserdata"
                / "monitor.xcuserdatad"
                / "WorkspaceSettings.xcsettings",
            )
            for settings_path in user_settings_paths:
                with self.subTest(settings_path=settings_path):
                    self.assertIn(str(saved_profile_root), settings_path.read_text())

            generated_entitlements_dir = (
                saved_profile_root
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
            self.assertTrue((saved_profile_root / ".metadata_never_index").exists())

    def test_post_generate_leaves_shared_workspace_alone_when_not_workspace_owner(
        self,
    ) -> None:
        """Agent-driven `tuist generate` runs (no `HARNESS_MONITOR_OWNS_WORKSPACE`)
        must not overwrite the user's shared workspace settings or
        buildServer.json with their isolated DerivedData path."""
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
            shutil.copy(
                APP_ROOT / "Scripts" / "lib" / "runtime-profile.sh",
                lib_root / "runtime-profile.sh",
            )
            shutil.copy(XCODE_VERSION_SOURCE, lib_root / "xcode-version.sh")

            (app_root / "HarnessMonitor.entitlements").write_bytes(
                plistlib.dumps(
                    {
                        "com.apple.security.application-groups": [
                            "Q498EB36N4.io.harnessmonitor"
                        ],
                    }
                )
            )
            (app_root / "HarnessMonitorUITestHost.entitlements").write_bytes(
                plistlib.dumps(
                    {
                        "com.apple.security.application-groups": [
                            "Q498EB36N4.io.harnessmonitor"
                        ],
                    }
                )
            )

            user_owned_marker = "USER-OWNED-SHARED-DERIVED-DATA"
            user_build_server_marker = "USER-OWNED-BUILD-SERVER"
            user_pbxproj_marker = "USER-OWNED-PBXPROJ"
            shared_settings_paths = (
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
            for settings_path in shared_settings_paths:
                settings_path.parent.mkdir(parents=True, exist_ok=True)
                settings_path.write_text(user_owned_marker)

            build_server_paths = (
                app_root / "buildServer.json",
                repo_root / "buildServer.json",
            )
            for build_server_path in build_server_paths:
                build_server_path.write_text(user_build_server_marker)
            pbxproj_path = app_root / "HarnessMonitor.xcodeproj" / "project.pbxproj"
            pbxproj_path.parent.mkdir(parents=True, exist_ok=True)
            pbxproj_path.write_text(user_pbxproj_marker)

            env = base_env()
            env.update(
                {
                    "HARNESS_MONITOR_APP_ROOT": str(app_root),
                    "HARNESS_MONITOR_RUNTIME_PROFILE": "agent-foo",
                    "HARNESS_MONITOR_SKIP_VERSION_SYNC": "1",
                    "HARNESS_MONITOR_XCODE_DTXCODE": "2640",
                    "REPO_ROOT": str(repo_root),
                    "TMPDIR": str(temp_root),
                }
            )
            env.pop("HARNESS_MONITOR_OWNS_WORKSPACE", None)

            completed = subprocess.run(
                ["bash", str(generated_post_generate)],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)

            for settings_path in shared_settings_paths:
                with self.subTest(settings_path=settings_path):
                    self.assertEqual(
                        settings_path.read_text(),
                        user_owned_marker,
                        "agent post-generate must not overwrite shared workspace settings",
                    )
            for build_server_path in build_server_paths:
                with self.subTest(build_server_path=build_server_path):
                    self.assertEqual(
                        build_server_path.read_text(),
                        user_build_server_marker,
                        "agent post-generate must not overwrite buildServer.json",
                    )
            self.assertEqual(
                pbxproj_path.read_text(),
                user_pbxproj_marker,
                "agent post-generate must not overwrite shared project metadata",
            )


if __name__ == "__main__":
    unittest.main()
