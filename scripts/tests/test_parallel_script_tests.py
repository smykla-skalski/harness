from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
RUNNER_PATH = ROOT / "scripts" / "run-script-test-suite.py"


def load_runner():
    spec = importlib.util.spec_from_file_location("run_script_test_suite", RUNNER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {RUNNER_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ParallelScriptTestRunnerTests(unittest.TestCase):
    def test_total_runtime_budget_is_opt_in(self) -> None:
        runner = load_runner()
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(sys, "argv", ["run-script-test-suite.py"]),
        ):
            arguments = runner._arguments()
        self.assertIsNone(arguments.budget_seconds)

        with (
            patch.dict(
                os.environ,
                {"HARNESS_SCRIPT_TEST_BUDGET_SECONDS": "15"},
                clear=True,
            ),
            patch.object(sys, "argv", ["run-script-test-suite.py"]),
        ):
            arguments = runner._arguments()
        self.assertEqual(arguments.budget_seconds, 15)

    def test_invalid_environment_defaults_use_argparse_errors(self) -> None:
        runner = load_runner()
        variables = (
            "HARNESS_SCRIPT_TEST_JOBS",
            "HARNESS_SCRIPT_TEST_TASK_TIMEOUT_SECONDS",
        )
        for variable in variables:
            with self.subTest(variable=variable):
                stderr = io.StringIO()
                with (
                    patch.dict(os.environ, {variable: "invalid"}, clear=True),
                    patch.object(sys, "argv", ["run-script-test-suite.py"]),
                    contextlib.redirect_stderr(stderr),
                    self.assertRaises(SystemExit) as raised,
                ):
                    runner._arguments()

                self.assertEqual(raised.exception.code, 2)
                self.assertIn("invalid", stderr.getvalue())
                self.assertNotIn("Traceback", stderr.getvalue())

    def test_jobs_overlap_and_receive_private_home_and_tmpdir(self) -> None:
        runner = load_runner()
        with tempfile.TemporaryDirectory() as directory:
            barrier = Path(directory) / "barrier"
            barrier.mkdir()
            probe = """
import os
import pathlib
import time

barrier = pathlib.Path(os.environ["PROBE_DIR"])
(barrier / os.environ["HARNESS_SCRIPT_TEST_JOB"]).touch()
deadline = time.monotonic() + 5
while len(tuple(barrier.iterdir())) < 4:
    if time.monotonic() >= deadline:
        raise SystemExit("workers did not overlap")
    time.sleep(0.01)
tmp = pathlib.Path(os.environ["TMPDIR"])
(tmp / "owner").write_text(os.environ["HARNESS_SCRIPT_TEST_JOB"])
print(os.environ["HOME"])
print(tmp)
"""
            tasks = [
                runner.Task(
                    label=f"probe-{index}",
                    command=(sys.executable, "-c", probe),
                    environment={"PROBE_DIR": str(barrier)},
                )
                for index in range(4)
            ]
            summary = runner.run_tasks(
                tasks,
                max_workers=4,
                timeout_seconds=8,
                sandbox_root=Path(directory),
            )

        self.assertTrue(summary.succeeded)
        homes = {result.output.splitlines()[0] for result in summary.results}
        tmpdirs = {result.output.splitlines()[1] for result in summary.results}
        self.assertEqual(len(homes), 4)
        self.assertEqual(len(tmpdirs), 4)

    def test_exclusive_tasks_keep_the_top_level_cleanup_token(self) -> None:
        runner = load_runner()
        task = runner.Task(
            label="exclusive",
            command=(
                sys.executable,
                "-c",
                "import os; print(os.environ['HARNESS_SCRIPT_TEST_RUN_TOKEN'])",
            ),
            exclusive=True,
        )

        summary = runner._run_task_groups(
            (task,),
            max_workers=1,
            timeout_seconds=2,
        )

        self.assertTrue(summary.succeeded)
        run_token = summary.results[0].output.strip()
        self.assertTrue(run_token.startswith("hst."))
        self.assertNotEqual(run_token, "exclusive")

    def test_failure_is_captured_without_hiding_other_results(self) -> None:
        runner = load_runner()
        tasks = [
            runner.Task(
                label="fails",
                command=(sys.executable, "-c", "print('diagnostic'); raise SystemExit(7)"),
            ),
            runner.Task(
                label="passes",
                command=(sys.executable, "-c", "print('finished')"),
            ),
        ]

        with tempfile.TemporaryDirectory() as directory:
            summary = runner.run_tasks(
                tasks,
                max_workers=2,
                timeout_seconds=2,
                sandbox_root=Path(directory),
            )

        self.assertFalse(summary.succeeded)
        by_label = {result.task.label: result for result in summary.results}
        self.assertEqual(by_label["fails"].returncode, 7)
        self.assertIn("diagnostic", by_label["fails"].output)
        self.assertEqual(by_label["passes"].returncode, 0)
        self.assertIn("finished", by_label["passes"].output)

    def test_weighted_jobs_do_not_oversubscribe_process_capacity(self) -> None:
        runner = load_runner()
        tasks = [
            runner.Task(
                label=f"weighted-{index}",
                command=(sys.executable, "-c", "import time; time.sleep(0.2)"),
                weight=2,
            )
            for index in range(2)
        ]

        with tempfile.TemporaryDirectory() as directory:
            summary = runner.run_tasks(
                tasks,
                max_workers=2,
                timeout_seconds=2,
                sandbox_root=Path(directory),
            )

        self.assertTrue(summary.succeeded)
        self.assertGreater(summary.elapsed_seconds, 0.35)

    def test_weights_larger_than_the_selected_capacity_are_exclusive(self) -> None:
        runner = load_runner()
        tasks = [
            runner.Task(
                label=f"heavy-{index}",
                command=(sys.executable, "-c", "import time; time.sleep(0.2)"),
                weight=8,
            )
            for index in range(2)
        ]

        with tempfile.TemporaryDirectory() as directory:
            summary = runner.run_tasks(
                tasks,
                max_workers=2,
                timeout_seconds=2,
                sandbox_root=Path(directory),
            )

        self.assertTrue(summary.succeeded)
        self.assertGreater(summary.elapsed_seconds, 0.35)

    def test_higher_priority_tasks_start_first(self) -> None:
        runner = load_runner()
        with tempfile.TemporaryDirectory() as directory:
            order = Path(directory) / "order"
            probe = (
                "import os, pathlib; "
                "path = pathlib.Path(os.environ['ORDER']); "
                "path.open('a').write(os.environ['NAME'] + '\\n')"
            )
            tasks = [
                runner.Task(
                    label="low",
                    command=(sys.executable, "-c", probe),
                    environment={"NAME": "low", "ORDER": str(order)},
                    priority=1,
                ),
                runner.Task(
                    label="high",
                    command=(sys.executable, "-c", probe),
                    environment={"NAME": "high", "ORDER": str(order)},
                    priority=2,
                ),
            ]
            summary = runner.run_tasks(
                tasks,
                max_workers=1,
                timeout_seconds=2,
                sandbox_root=Path(directory) / "jobs",
            )

            self.assertTrue(summary.succeeded)
            self.assertEqual(order.read_text().splitlines(), ["high", "low"])

    def test_group_limit_caps_only_matching_tasks(self) -> None:
        runner = load_runner()
        tasks = [
            runner.Task(
                label=f"grouped-{index}",
                command=(sys.executable, "-c", "import time; time.sleep(0.2)"),
                group="shared",
                group_limit=1,
            )
            for index in range(2)
        ]

        with tempfile.TemporaryDirectory() as directory:
            summary = runner.run_tasks(
                tasks,
                max_workers=2,
                timeout_seconds=2,
                sandbox_root=Path(directory),
            )

        self.assertTrue(summary.succeeded)
        self.assertGreater(summary.elapsed_seconds, 0.35)

    def test_python_files_are_split_into_bounded_process_shards(self) -> None:
        runner = load_runner()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test_many.py"
            methods = "\n".join(
                f"    def test_{index}(self): pass" for index in range(17)
            )
            path.write_text(
                f"import unittest\nclass ManyTests(unittest.TestCase):\n{methods}\n"
            )
            tasks = runner._python_test_tasks("many", path)

        self.assertEqual(len(tasks), 3)
        self.assertEqual(
            [len(task.command) - 3 for task in tasks],
            [8, 8, 1],
        )

    def test_monitor_process_shards_consume_more_capacity(self) -> None:
        runner = load_runner()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test_monitor_xcodebuild.py"
            path.write_text(
                "class Tests:\n"
                "    def test_regular(self): pass\n"
                "    def test_protect_inflight_example(self): pass\n"
            )
            tasks = runner._python_test_tasks(
                "monitor python: monitor_xcodebuild",
                path,
            )

        by_test = {
            task.command[-1]: task.weight
            for task in tasks
        }
        self.assertEqual(
            by_test["test_monitor_xcodebuild.Tests.test_regular"],
            runner.MONITOR_XCODEBUILD_WEIGHT,
        )
        self.assertEqual(
            by_test[
                "test_monitor_xcodebuild.Tests.test_protect_inflight_example"
            ],
            runner.MONITOR_XCODEBUILD_PROCESS_WEIGHT,
        )

    def test_round_robin_keeps_task_families_from_starving(self) -> None:
        runner = load_runner()

        tasks = runner._round_robin(
            (
                [
                    runner.Task("support-1", ("true",)),
                    runner.Task("support-2", ("true",)),
                ],
                [runner.Task("release-1", ("true",))],
                [runner.Task("cargo-1", ("true",)), runner.Task("cargo-2", ("true",))],
            )
        )

        self.assertEqual(
            [task.label for task in tasks],
            ["support-1", "release-1", "cargo-1", "support-2", "cargo-2"],
        )

    def test_teardown_kills_only_processes_owned_by_the_sandbox(self) -> None:
        runner = load_runner()
        with tempfile.TemporaryDirectory(prefix="hst.", dir="/tmp") as directory:
            sandbox = Path(directory)
            process = subprocess.Popen(
                (
                    sys.executable,
                    "-c",
                    "import time; time.sleep(30)",
                    str(sandbox / "owned"),
                ),
                start_new_session=True,
            )
            runner._terminate_owned_processes(sandbox)
            process.wait(timeout=2)

        self.assertNotEqual(process.returncode, 0)

    def test_jobserver_cleanup_token_excludes_production_roots(self) -> None:
        runner = load_runner()
        jobserver = runner.ROOT / "scripts" / "harness-jobserver.py"

        self.assertEqual(
            runner._test_jobserver_token(
                f"python3 {jobserver} supervise --repo-root /synthetic/hst.run/1/a "
                "--budget 2"
            ),
            "hst.run",
        )
        self.assertEqual(
            runner._test_jobserver_token(
                f"python3 {jobserver} supervise --repo-root pool-hst.run-sizing-1 "
                "--budget 2"
            ),
            "hst.run",
        )
        self.assertIsNone(
            runner._test_jobserver_token(
                f"python3 {jobserver} supervise --repo-root {runner.ROOT} --budget 2"
            )
        )

    def test_native_release_fixture_reads_appended_version_and_binary_name(self) -> None:
        runner = load_runner()
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fake-release-binary"
            binary = Path(directory) / "harness-codex-acp"
            runner.compile_release_fixture(fixture)
            binary.write_bytes(
                fixture.read_bytes() + b"\nHARNESS_FAKE_VERSION=48.0.0\n"
            )
            binary.chmod(0o755)

            version = subprocess.run(
                (str(binary), "--version"),
                check=True,
                capture_output=True,
                env={**os.environ, "BASH_ENV": "/dev/null"},
                text=True,
            )
            probe = subprocess.run(
                (str(binary), "--probe"),
                check=True,
                capture_output=True,
                env={**os.environ, "BASH_ENV": "/dev/null"},
                text=True,
            )

        self.assertEqual(version.stdout, "harness-codex-acp 48.0.0\n")
        self.assertEqual(probe.stdout, "harness-codex-acp\n")

    def test_release_acceleration_overrides_require_the_script_runner(self) -> None:
        install_script = ROOT / "scripts" / "install-release-set.sh"
        build_script = ROOT / "scripts" / "build-release-set.sh"
        cases = (
            (
                install_script,
                "HARNESS_INSTALL_TEST_TRUST_ARTIFACTS",
                "1",
            ),
            (
                install_script,
                "HARNESS_INSTALL_TEST_INVENTORY_BINARIES",
                "harness",
            ),
            (
                install_script,
                "HARNESS_INSTALL_TEST_LIVE_EXECUTABLES_FILE",
                "/tmp/not-used",
            ),
            (
                install_script,
                "HARNESS_INSTALL_TEST_EXIT_AFTER_LOCK",
                "1",
            ),
            (
                install_script,
                "HARNESS_INSTALL_TEST_ACTIVATED_FILE",
                "/tmp/not-used",
            ),
            (
                install_script,
                "HARNESS_INSTALL_TEST_CONTINUE_FILE",
                "/tmp/not-used",
            ),
            (
                install_script,
                "HARNESS_RELEASE_TEST_PROCESS_START_MARKER",
                "synthetic",
            ),
            (
                build_script,
                "HARNESS_RELEASE_BUILD_TEST_CARGO_WRAPPER",
                "/tmp/not-used",
            ),
            (
                build_script,
                "HARNESS_RELEASE_BUILD_TEST_WAIT_FOR_FILE",
                "/tmp/not-used",
            ),
        )
        variables = {variable for _, variable, _ in cases}
        for script, variable, value in cases:
            with self.subTest(variable=variable):
                environment = os.environ.copy()
                environment.pop("HARNESS_SCRIPT_TEST_JOB", None)
                for test_variable in variables:
                    environment.pop(test_variable, None)
                environment[variable] = value
                completed = subprocess.run(
                    (str(script), "--print-build-binary"),
                    check=False,
                    capture_output=True,
                    env=environment,
                    text=True,
                )

                self.assertEqual(completed.returncode, 2)
                self.assertIn(f"{variable} is test-only", completed.stderr)


if __name__ == "__main__":
    unittest.main()
