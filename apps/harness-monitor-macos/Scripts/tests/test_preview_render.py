from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_SOURCE = APP_ROOT / "Scripts" / "preview-render.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class PreviewRenderScriptTests(unittest.TestCase):
    def run_script(
        self,
        *,
        use_repo_root_relative: bool = False,
        use_absolute_path: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            repo_root = temp_root / "repo"
            app_root = repo_root / "apps" / "harness-monitor-macos"
            scripts_root = app_root / "Scripts"
            sources_root = app_root / "Sources" / "HarnessMonitorUIPreviewable" / "Views" / "Decisions"
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            scripts_root.mkdir(parents=True)
            sources_root.mkdir(parents=True)

            script_path = scripts_root / "preview-render.sh"
            script_path.write_text(SCRIPT_SOURCE.read_text())
            script_path.chmod(script_path.stat().st_mode | stat.S_IXUSR)

            target_file = sources_root / "DecisionsSidebar.swift"
            target_file.write_text("import SwiftUI\n")

            tool_log = temp_root / "xcode-cli.log"
            write_executable(
                fake_bin / "xcode-cli",
                f"""#!/bin/bash
set -euo pipefail
printf 'scheme=%s\\nargs=%s\\n' "${{XCODE_BUILD_SERVER_SCHEME:-}}" "$*" > "{tool_log}"
out=""
args=("$@")
for ((i=0; i<${{#args[@]}}; i++)); do
  if [[ "${{args[$i]}}" == "--out" ]]; then
    out="${{args[$((i + 1))]}}"
    break
  fi
done
[[ -n "$out" ]] || exit 2
mkdir -p "$(dirname "$out")"
touch "$out"
""",
            )
            write_executable(
                fake_bin / "jq",
                """#!/bin/bash
set -euo pipefail
printf '{}\n'
""",
            )

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
            file_arg = "Sources/HarnessMonitorUIPreviewable/Views/Decisions/DecisionsSidebar.swift"
            if use_repo_root_relative:
                file_arg = (
                    "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Decisions/"
                    "DecisionsSidebar.swift"
                )
            elif use_absolute_path:
                file_arg = str(target_file)

            completed = subprocess.run(
                ["bash", str(script_path), "--file", file_arg, "--index", "0"],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            log = tool_log.read_text() if tool_log.exists() else ""
            return completed, log

    def test_accepts_repo_root_relative_file_path(self) -> None:
        completed, log = self.run_script(use_repo_root_relative=True)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            "scheme=HarnessMonitorUIPreviews",
            log,
        )
        self.assertIn(
            "preview apps/HarnessMonitor/Project/Sources/HarnessMonitorUIPreviewable/Views/Decisions/DecisionsSidebar.swift",
            log,
        )

    def test_accepts_absolute_file_path(self) -> None:
        completed, log = self.run_script(use_absolute_path=True)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            "scheme=HarnessMonitorUIPreviews",
            log,
        )
        self.assertIn(
            "preview apps/HarnessMonitor/Project/Sources/HarnessMonitorUIPreviewable/Views/Decisions/DecisionsSidebar.swift",
            log,
        )


if __name__ == "__main__":
    unittest.main()
