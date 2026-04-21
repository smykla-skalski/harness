from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = APP_ROOT / "Scripts" / "generate-project.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def extract_testable_reference(text: str, buildable_name: str) -> str:
    buildable_marker = f'BuildableName = "{buildable_name}"'
    marker_index = text.index(buildable_marker)
    block_start = text.rfind("<TestableReference", 0, marker_index)
    block_end = text.index("</TestableReference>", marker_index) + len(
        "</TestableReference>"
    )
    return text[block_start:block_end]


class GenerateProjectScriptTests(unittest.TestCase):
    def test_removes_stale_shared_schemes_before_regeneration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "HarnessMonitor"
            scripts_root = app_root / "Scripts"
            schemes_root = (
                app_root / "HarnessMonitor.xcodeproj" / "xcshareddata" / "xcschemes"
            )
            fake_xcodegen = temp_root / "xcodegen"
            stale_scheme = schemes_root / "Stale.xcscheme"

            schemes_root.mkdir(parents=True)
            scripts_root.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SCRIPT_PATH, scripts_root / "generate-project.sh")
            (app_root / "project.yml").write_text("name: HarnessMonitor\n")
            stale_scheme.write_text("<Scheme LastUpgradeVersion = \"1430\" />\n")

            write_executable(
                fake_xcodegen,
                """#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "Version: 2.45.4"
  exit 0
fi
if [[ "${1:-}" != "generate" ]]; then
  echo "unexpected xcodegen invocation: $*" >&2
  exit 99
fi

project_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      project_root="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$project_root/HarnessMonitor.xcodeproj/xcshareddata/xcschemes"

cat > "$project_root/HarnessMonitor.xcodeproj/project.pbxproj" <<'EOF'
ABCDEF1234567890 /* XCLocalSwiftPackageReference "../../mcp-servers/harness-monitor-registry" */ = {
			isa = XCLocalSwiftPackageReference;
};
		DEADBEEF12345678 /* HarnessMonitorRegistry */ = {
			isa = XCSwiftPackageProductDependency;
			productName = HarnessMonitorRegistry;
};
LastUpgradeCheck = 1430;
/* HarnessMonitor.app */
path = HarnessMonitor.app;
/* HarnessMonitorUITestHost.app */
path = HarnessMonitorUITestHost.app;
EOF

cat > "$project_root/HarnessMonitor.xcodeproj/xcshareddata/xcschemes/HarnessMonitor.xcscheme" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1430"
   version = "1.7">
</Scheme>
EOF
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "XCODEGEN_BIN": str(fake_xcodegen),
                    "HARNESS_MONITOR_SKIP_VERSION_SYNC": "1",
                }
            )

            completed = subprocess.run(
                ["bash", str(scripts_root / "generate-project.sh")],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse(
                stale_scheme.exists(),
                "generate-project.sh should remove stale shared schemes before regeneration",
            )

    def test_fails_fast_when_xcodegen_version_is_not_supported(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "HarnessMonitor"
            scripts_root = app_root / "Scripts"
            fake_xcodegen = temp_root / "xcodegen"

            scripts_root.mkdir(parents=True)
            shutil.copy2(SCRIPT_PATH, scripts_root / "generate-project.sh")
            (app_root / "project.yml").write_text("name: HarnessMonitor\n")

            write_executable(
                fake_xcodegen,
                """#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "Version: 0.0.0"
  exit 0
fi
echo "unexpected xcodegen invocation" >&2
exit 99
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "XCODEGEN_BIN": str(fake_xcodegen),
                    "HARNESS_MONITOR_SKIP_VERSION_SYNC": "1",
                }
            )

            completed = subprocess.run(
                ["bash", str(scripts_root / "generate-project.sh")],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("unsupported xcodegen version", completed.stderr)
            self.assertIn("2.45.4", completed.stderr)
            self.assertNotIn("unexpected xcodegen invocation", completed.stderr)

    def test_normalizes_xcodegen_schemes_to_xcode_round_trip_form(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            app_root = temp_root / "HarnessMonitor"
            scripts_root = app_root / "Scripts"
            schemes_root = (
                app_root / "HarnessMonitor.xcodeproj" / "xcshareddata" / "xcschemes"
            )
            fake_xcodegen = temp_root / "xcodegen"

            schemes_root.mkdir(parents=True)
            scripts_root.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SCRIPT_PATH, scripts_root / "generate-project.sh")
            (app_root / "project.yml").write_text("name: HarnessMonitor\n")

            write_executable(
                fake_xcodegen,
                """#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "Version: 2.45.4"
  exit 0
fi
if [[ "${1:-}" != "generate" ]]; then
  echo "unexpected xcodegen invocation: $*" >&2
  exit 99
fi

project_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      project_root="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$project_root/HarnessMonitor.xcodeproj/xcshareddata/xcschemes"

cat > "$project_root/HarnessMonitor.xcodeproj/project.pbxproj" <<'EOF'
ABCDEF1234567890 /* XCLocalSwiftPackageReference "../../mcp-servers/harness-monitor-registry" */ = {
			isa = XCLocalSwiftPackageReference;
};
		DEADBEEF12345678 /* HarnessMonitorRegistry */ = {
			isa = XCSwiftPackageProductDependency;
			productName = HarnessMonitorRegistry;
};
LastUpgradeCheck = 1430;
/* HarnessMonitor.app */
path = HarnessMonitor.app;
/* HarnessMonitorUITestHost.app */
path = HarnessMonitorUITestHost.app;
EOF

cat > "$project_root/HarnessMonitor.xcodeproj/xcshareddata/xcschemes/HarnessMonitor.xcscheme" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1430"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      runPostActionsOnFailure = "NO">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "MONITOR"
               BuildableName = "HarnessMonitor.app"
               BlueprintName = "HarnessMonitor"
               ReferencedContainer = "container:HarnessMonitor.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      codeCoverageEnabled = "YES"
      onlyGenerateCoverageForSpecifiedTargets = "NO">
      <MacroExpansion>
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "MONITOR"
            BuildableName = "HarnessMonitor.app"
            BlueprintName = "HarnessMonitor"
            ReferencedContainer = "container:HarnessMonitor.xcodeproj">
         </BuildableReference>
      </MacroExpansion>
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "KIT_TESTS"
               BuildableName = "HarnessMonitorKitTests.xctest"
               BlueprintName = "HarnessMonitorKitTests"
               ReferencedContainer = "container:HarnessMonitor.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "UI_TESTS"
               BuildableName = "HarnessMonitorUITests.xctest"
               BlueprintName = "HarnessMonitorUITests"
               ReferencedContainer = "container:HarnessMonitor.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
      <CommandLineArguments>
      </CommandLineArguments>
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "HARNESS_DAEMON_DATA_HOME"
            value = "/tmp/harness-monitor-tests"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "MONITOR"
            BuildableName = "HarnessMonitor.app"
            BlueprintName = "HarnessMonitor"
            ReferencedContainer = "container:HarnessMonitor.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
      <CommandLineArguments>
      </CommandLineArguments>
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "HARNESS_OTEL_EXPORT"
            value = "1"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
   </LaunchAction>
</Scheme>
EOF

cat > "$project_root/HarnessMonitor.xcodeproj/xcshareddata/xcschemes/HarnessMonitorKitTests.xcscheme" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1430"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES"
      runPostActionsOnFailure = "NO">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "KIT_TESTS"
               BuildableName = "HarnessMonitorKitTests.xctest"
               BlueprintName = "HarnessMonitorKitTests"
               ReferencedContainer = "container:HarnessMonitor.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      onlyGenerateCoverageForSpecifiedTargets = "NO">
      <MacroExpansion>
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "KIT_TESTS"
            BuildableName = "HarnessMonitorKitTests.xctest"
            BlueprintName = "HarnessMonitorKitTests"
            ReferencedContainer = "container:HarnessMonitor.xcodeproj">
         </BuildableReference>
      </MacroExpansion>
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "KIT_TESTS"
               BuildableName = "HarnessMonitorKitTests.xctest"
               BlueprintName = "HarnessMonitorKitTests"
               ReferencedContainer = "container:HarnessMonitor.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
      <CommandLineArguments>
      </CommandLineArguments>
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "HARNESS_DAEMON_DATA_HOME"
            value = "/tmp/harness-monitor-tests"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
   </TestAction>
</Scheme>
EOF
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "XCODEGEN_BIN": str(fake_xcodegen),
                    "HARNESS_MONITOR_SKIP_VERSION_SYNC": "1",
                }
            )

            completed = subprocess.run(
                ["bash", str(scripts_root / "generate-project.sh")],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)

            monitor_scheme = (schemes_root / "HarnessMonitor.xcscheme").read_text()
            self.assertIn('version = "1.3"', monitor_scheme)
            self.assertNotIn('version = "1.7"', monitor_scheme)
            self.assertIn('BuildableName = "Harness Monitor.app"', monitor_scheme)
            self.assertNotIn('BuildableName = "HarnessMonitor.app"', monitor_scheme)
            self.assertNotIn('runPostActionsOnFailure = "NO"', monitor_scheme)
            self.assertNotIn(
                'onlyGenerateCoverageForSpecifiedTargets = "NO"',
                monitor_scheme,
            )
            self.assertNotIn("<CommandLineArguments>", monitor_scheme)

            test_action = monitor_scheme.split("<TestAction", 1)[1].split(
                "</TestAction>",
                1,
            )[0]
            self.assertLess(
                test_action.index("<EnvironmentVariables>"),
                test_action.index("<Testables>"),
            )

            kit_testable = extract_testable_reference(
                monitor_scheme,
                "HarnessMonitorKitTests.xctest",
            )
            ui_testable = extract_testable_reference(
                monitor_scheme,
                "HarnessMonitorUITests.xctest",
            )
            self.assertIn('parallelizable = "NO"', kit_testable)
            self.assertNotIn('parallelizable = "NO"', ui_testable)

            kit_scheme = (schemes_root / "HarnessMonitorKitTests.xcscheme").read_text()
            self.assertIn('version = "1.3"', kit_scheme)
            self.assertNotIn('runPostActionsOnFailure = "NO"', kit_scheme)
            self.assertNotIn(
                'onlyGenerateCoverageForSpecifiedTargets = "NO"',
                kit_scheme,
            )
            self.assertNotIn("<CommandLineArguments>", kit_scheme)
            self.assertIn('parallelizable = "NO"', kit_scheme)


if __name__ == "__main__":
    unittest.main()
