#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import os
import platform
import signal
import subprocess
import sys
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass, field, replace
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
SESSION_VARIABLES = (
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_SESSION_ID",
    "CODEX_SESSION_ID",
    "CODEX_THREAD_ID",
    "COPILOT_SESSION_ID",
    "GEMINI_SESSION_ID",
    "OPENCODE_SESSION_ID",
)
PYTHON_TEST_CHUNK_SIZE = 8
PYTHON_TEST_CHUNK_SIZES = {
    "monitor python: bundle_daemon_agent_env": 2,
    "monitor python: generate": 2,
    "monitor python: run_daemon_dev": 2,
    "monitor python: run_quality_gates": 2,
    "root macOS python: clean stale fsmonitor": 2,
}
MONITOR_XCODEBUILD_PROCESS_WEIGHT = 2
MONITOR_XCODEBUILD_WEIGHT = 1
MONITOR_XCODEBUILD_LABEL = "monitor python: monitor_xcodebuild"
MONITOR_XCODEBUILD_REAL_PROCESS_TESTS = (
    "test_protect_inflight_",
    "test_success_path_has_no_terminated_signal_noise",
    "test_global_semaphore_",
    "test_legitimate_launchd_wrapper_",
    "test_orphan_wrapper_",
    "test_stale_heartbeat_",
    "test_legacy_concurrency_",
    "test_test_override_",
    "test_cap_zero_",
)


def _is_monitor_xcodebuild_label(label: str) -> bool:
    return label == MONITOR_XCODEBUILD_LABEL or label.startswith(
        f"{MONITOR_XCODEBUILD_LABEL}:"
    )


@dataclass(frozen=True)
class Task:
    label: str
    command: tuple[str, ...]
    environment: dict[str, str] = field(default_factory=dict)
    exclusive: bool = False
    weight: int = 1
    priority: int = 0
    group: str = ""
    group_limit: int = 0


@dataclass(frozen=True)
class TaskResult:
    task: Task
    returncode: int
    elapsed_seconds: float
    output: str
    timed_out: bool


@dataclass(frozen=True)
class RunSummary:
    results: tuple[TaskResult, ...]
    elapsed_seconds: float

    @property
    def succeeded(self) -> bool:
        return all(result.returncode == 0 for result in self.results)


def _job_directory(root: Path, index: int, _label: str) -> Path:
    return root / f"{index:03x}"


def _environment(
    task: Task,
    job_directory: Path,
    run_token: str,
) -> dict[str, str]:
    environment = os.environ.copy()
    for variable in SESSION_VARIABLES:
        environment.pop(variable, None)
    environment.update(task.environment)
    if _is_monitor_xcodebuild_label(task.label):
        environment["HARNESS_MONITOR_APP_ROOT"] = str(
            ROOT / "apps" / "harness-monitor"
        )
        environment["_HARNESS_INTERNAL_TEST_ONLY_CHECKOUT_ROOT"] = str(ROOT)
        environment["_HARNESS_INTERNAL_TEST_ONLY_SCRIPT_DIR"] = str(
            ROOT / "apps" / "harness-monitor" / "Scripts"
        )
        environment["_HARNESS_INTERNAL_TEST_ONLY_COMMON_REPO_ROOT"] = str(ROOT)
    if _is_monitor_xcodebuild_label(task.label) and not any(
        name in argument
        for name in MONITOR_XCODEBUILD_REAL_PROCESS_TESTS
        for argument in task.command
    ):
        descendant_snapshot = job_directory / "descendant-pids"
        descendant_snapshot.touch()
        environment[
            "_HARNESS_INTERNAL_TEST_ONLY_DESCENDANT_PIDS_FILE"
        ] = str(descendant_snapshot)
        environment["HARNESS_MONITOR_SCRIPT_TEST_FAST_XCODEBUILD"] = "1"
    home = job_directory / "h"
    tmpdir = job_directory / "t"
    home.mkdir(parents=True)
    tmpdir.mkdir()
    environment.update(
        {
            "BASH_ENV": "/dev/null",
            "HARNESS_SCRIPT_TEST_JOB": task.label,
            "HARNESS_SCRIPT_TEST_RUN_TOKEN": run_token,
            "HOME": str(home),
            "PYTHONDONTWRITEBYTECODE": "1",
            "TMPDIR": f"{tmpdir}/",
        }
    )
    return environment


def _descendant_pids(root_pid: int) -> tuple[int, ...]:
    completed = subprocess.run(
        ("/bin/ps", "-Ao", "pid=,ppid="),
        check=False,
        capture_output=True,
        text=True,
    )
    children: dict[int, list[int]] = {}
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        pid, parent_pid = (int(field) for field in fields)
        children.setdefault(parent_pid, []).append(pid)
    descendants = []
    pending = list(children.get(root_pid, ()))
    while pending:
        pid = pending.pop()
        descendants.append(pid)
        pending.extend(children.get(pid, ()))
    return tuple(descendants)


def _signal_pids(pids: Iterable[int], sent_signal: signal.Signals) -> None:
    for pid in pids:
        try:
            os.kill(pid, sent_signal)
        except (PermissionError, ProcessLookupError):
            pass


def _process_commands() -> dict[int, str]:
    completed = subprocess.run(
        ("/bin/ps", "-ww", "-Ao", "pid=,command="),
        check=False,
        capture_output=True,
        text=True,
    )
    processes = {}
    for line in completed.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2 and fields[0].isdigit():
            processes[int(fields[0])] = fields[1]
    return processes


def _test_jobserver_token(command: str) -> str | None:
    jobserver = str(ROOT / "scripts" / "harness-jobserver.py")
    marker = f"{jobserver} supervise --repo-root "
    if marker not in command:
        return None
    repo_root = command.partition(marker)[2].split(maxsplit=1)[0]
    if repo_root.startswith("/synthetic/"):
        fields = repo_root.split("/")
        return fields[2] if len(fields) > 2 else None
    if repo_root.startswith("pool-hst."):
        return repo_root.split("-", maxsplit=2)[1]
    return None


def _terminate_owned_processes(sandbox_root: Path) -> None:
    run_token = sandbox_root.name

    def owned(command: str) -> bool:
        return f"{sandbox_root}/" in command or _test_jobserver_token(command) == run_token

    processes = _process_commands()
    pids = [
        pid
        for pid, command in processes.items()
        if pid != os.getpid() and owned(command)
    ]
    _signal_pids(pids, signal.SIGTERM)
    deadline = time.monotonic() + 0.5
    while pids and time.monotonic() < deadline:
        time.sleep(0.02)
        current = _process_commands()
        pids = [pid for pid in pids if pid in current and owned(current[pid])]
    _signal_pids(pids, signal.SIGKILL)


def _terminate_process_group(process: subprocess.Popen[str]) -> None:
    descendants = _descendant_pids(process.pid)
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (PermissionError, ProcessLookupError):
        pass
    _signal_pids(reversed(descendants), signal.SIGTERM)
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (PermissionError, ProcessLookupError):
            pass
    _signal_pids(reversed(descendants), signal.SIGKILL)
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _run_task(
    task: Task,
    index: int,
    sandbox_root: Path,
    timeout_seconds: float,
    run_token: str,
) -> TaskResult:
    job_directory = _job_directory(sandbox_root, index, task.label)
    job_directory.mkdir()
    started = time.monotonic()
    process = subprocess.Popen(
        task.command,
        env=_environment(task, job_directory, run_token),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        text=True,
    )
    timed_out = False
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        _terminate_process_group(process)
        output, _ = process.communicate()
        output += f"\nerror: timed out after {timeout_seconds:g}s\n"
    elapsed = time.monotonic() - started
    return TaskResult(
        task=task,
        returncode=124 if timed_out else process.returncode,
        elapsed_seconds=elapsed,
        output=output,
        timed_out=timed_out,
    )


def _run_in_root(
    tasks: tuple[Task, ...],
    max_workers: int,
    timeout_seconds: float,
    sandbox_root: Path,
    run_token: str,
) -> RunSummary:
    started = time.monotonic()
    indexed_tasks = sorted(
        (
            (index, task, min(task.weight, max_workers))
            for index, task in enumerate(tasks)
        ),
        key=lambda indexed_task: indexed_task[1].priority,
        reverse=True,
    )
    available = max_workers
    active = {}
    active_groups: dict[str, int] = {}
    completed: dict[int, TaskResult] = {}
    worker_count = max(1, min(max_workers, len(tasks)))
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        while indexed_tasks or active:
            while indexed_tasks:
                fitting_index = next(
                    (
                        index
                        for index, (_, task, weight) in enumerate(indexed_tasks)
                        if weight <= available
                        and (
                            not task.group
                            or task.group_limit < 1
                            or active_groups.get(task.group, 0) < task.group_limit
                        )
                    ),
                    None,
                )
                if fitting_index is None:
                    break
                task_index, task, weight = indexed_tasks.pop(fitting_index)
                available -= weight
                future = executor.submit(
                    _run_task,
                    task,
                    task_index,
                    sandbox_root,
                    timeout_seconds,
                    run_token,
                )
                active[future] = (task_index, weight)
                if task.group:
                    active_groups[task.group] = active_groups.get(task.group, 0) + 1
            if not active:
                raise RuntimeError("no script test fits the available capacity")
            finished, _ = wait(active, return_when=FIRST_COMPLETED)
            for future in finished:
                task_index, weight = active.pop(future)
                result = future.result()
                completed[task_index] = result
                available += weight
                if result.task.group:
                    active_groups[result.task.group] -= 1
    results = tuple(completed[index] for index in range(len(tasks)))
    return RunSummary(
        results=results,
        elapsed_seconds=time.monotonic() - started,
    )


def run_tasks(
    tasks: Iterable[Task],
    *,
    max_workers: int,
    timeout_seconds: float,
    sandbox_root: Path | None = None,
    run_token: str | None = None,
) -> RunSummary:
    task_tuple = tuple(tasks)
    if max_workers < 1:
        raise ValueError("max_workers must be positive")
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    if any(task.weight < 1 for task in task_tuple):
        raise ValueError("task weights must be positive")
    if any(task.group_limit < 0 for task in task_tuple):
        raise ValueError("task group limits cannot be negative")
    if sandbox_root is not None:
        sandbox_root.mkdir(parents=True, exist_ok=True)
        return _run_in_root(
            task_tuple,
            max_workers,
            timeout_seconds,
            sandbox_root,
            run_token or sandbox_root.name,
        )
    # macOS caps AF_UNIX paths at 104 bytes; nested test sandboxes need a short root.
    with TemporaryDirectory(prefix="hst.", dir="/tmp") as directory:
        return _run_in_root(
            task_tuple,
            max_workers,
            timeout_seconds,
            Path(directory),
            Path(directory).name,
        )


def _task(label: str, path: Path, *arguments: str) -> Task:
    return Task(label=label, command=(str(path), *arguments))


def _python_test_tasks(label: str, path: Path, **environment: str) -> list[Task]:
    python_path = str(path.parent)
    if inherited := environment.get("PYTHONPATH", os.environ.get("PYTHONPATH")):
        python_path = f"{python_path}{os.pathsep}{inherited}"
    test_environment = {**environment, "PYTHONPATH": python_path}
    tree = ast.parse(path.read_text(), filename=str(path))
    test_ids = [
        f"{path.stem}.{node.name}.{member.name}"
        for node in tree.body
        if isinstance(node, ast.ClassDef)
        for member in node.body
        if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef))
        and member.name.startswith("test_")
    ]
    if not test_ids:
        return [
            Task(
                label=label,
                command=(sys.executable, "-m", "unittest", str(path)),
                environment=test_environment,
            )
        ]
    if label == MONITOR_XCODEBUILD_LABEL:
        regular_ids = [
            test_id
            for test_id in test_ids
            if not any(
                name in test_id
                for name in MONITOR_XCODEBUILD_REAL_PROCESS_TESTS
            )
        ]
        sensitive_ids = [
            [test_id]
            for test_id in test_ids
            if any(
                name in test_id
                for name in MONITOR_XCODEBUILD_REAL_PROCESS_TESTS
            )
        ]
    else:
        regular_ids = test_ids
        sensitive_ids = []
    chunk_size = (
        2
        if label == "monitor python: monitor_xcodebuild"
        else PYTHON_TEST_CHUNK_SIZES.get(label, PYTHON_TEST_CHUNK_SIZE)
    )
    regular_chunks = [
        regular_ids[index : index + chunk_size]
        for index in range(0, len(regular_ids), chunk_size)
    ]
    chunks = _round_robin((regular_chunks, sensitive_ids))
    tasks = []
    for index, test_chunk in enumerate(chunks, start=1):
        sensitive = any(
            name in test_id
            for name in MONITOR_XCODEBUILD_REAL_PROCESS_TESTS
            for test_id in test_chunk
        )
        priority = 100
        weight = 1
        group = ""
        group_limit = 0
        if label in PYTHON_TEST_CHUNK_SIZES:
            priority = 700
            weight = 2
            group = label
            group_limit = {
                "monitor python: bundle_daemon_agent_env": 6,
                "monitor python: generate": 4,
                "monitor python: run_daemon_dev": 2,
                "monitor python: run_quality_gates": 2,
                "root macOS python: clean stale fsmonitor": 4,
            }[label]
        if label in (
            "monitor python: build_for_testing",
            "monitor python: run_bridge_start",
            "monitor python: run_lint",
            "monitor python: swift_package_freshness",
        ):
            priority = 700
            weight = 2
            group = "monitor process-heavy"
            group_limit = 3
        if label == MONITOR_XCODEBUILD_LABEL:
            priority = 850 if sensitive else 600
            weight = (
                MONITOR_XCODEBUILD_PROCESS_WEIGHT
                if sensitive
                else MONITOR_XCODEBUILD_WEIGHT
            )
            group = "monitor xcodebuild real" if sensitive else "monitor xcodebuild fake"
            group_limit = 2 if sensitive else 8
        tasks.append(
            Task(
                label=(
                    label
                    if len(chunks) == 1
                    else f"{label}: shard {index}/{len(chunks)}"
                ),
                command=(sys.executable, "-m", "unittest", *test_chunk),
                environment=test_environment,
                weight=weight,
                priority=priority,
                group=group,
                group_limit=group_limit,
            )
        )
    return tasks


def _round_robin(task_groups: Iterable[Iterable[Task]]) -> list[Task]:
    iterators = [iter(group) for group in task_groups]
    tasks = []
    while iterators:
        remaining = []
        for iterator in iterators:
            try:
                tasks.append(next(iterator))
                remaining.append(iterator)
            except StopIteration:
                pass
        iterators = remaining
    return tasks


def _scenario_names(script: Path) -> tuple[str, ...]:
    environment = os.environ.copy()
    environment["BASH_ENV"] = "/dev/null"
    completed = subprocess.run(
        (str(script), "--list"),
        check=True,
        capture_output=True,
        env=environment,
        text=True,
    )
    return tuple(line for line in completed.stdout.splitlines() if line)


def _scenario_tasks(
    label_prefix: str,
    script: Path,
    *,
    exclusive: frozenset[str] = frozenset(),
    group: str = "",
    group_limit: int = 0,
    priority: int = 0,
    priority_overrides: dict[str, int] | None = None,
    weight: int = 1,
) -> list[Task]:
    overrides = priority_overrides or {}
    return [
        Task(
            label=f"{label_prefix}: {scenario.removeprefix('scenario_')}",
            command=(str(script), "--scenario", scenario),
            exclusive=scenario in exclusive,
            weight=1 if scenario in exclusive else weight,
            priority=overrides.get(scenario, priority),
            group=group,
            group_limit=group_limit,
        )
        for scenario in _scenario_names(script)
    ]


def _root_python_tasks(host_os: str) -> list[Task]:
    tests_dir = ROOT / "scripts" / "tests"
    tests = (
        ("root python: disable fsmonitor dormant", "test_disable_fsmonitor_dormant.py"),
        ("root python: parallel script runner", "test_parallel_script_tests.py"),
        ("root python: seed Rust build lane", "test_seed_rust_build_lane.py"),
    )
    task_groups = [
        _python_test_tasks(label, tests_dir / name)
        for label, name in tests
    ]
    if host_os == "Darwin":
        task_groups.extend(
            _python_test_tasks(label, tests_dir / name)
            for label, name in (
            ("root macOS python: clean stale fsmonitor", "test_clean_stale_fsmonitor.py"),
            ("root macOS python: launchd fsmonitor", "test_launchd_fsmonitor.py"),
            )
        )
    return _round_robin(task_groups)


def _monitor_python_tasks(host_os: str) -> list[Task]:
    if host_os != "Darwin":
        return []
    tests_dir = ROOT / "apps" / "harness-monitor" / "Scripts" / "tests"
    return _round_robin(
        _python_test_tasks(
            f"monitor python: {path.stem.removeprefix('test_')}",
            path,
        )
        for path in sorted(tests_dir.glob("test_*.py"))
        if path.name != "test_test_swift.py"
    )


def _ordinary_shell_tasks() -> list[Task]:
    tests_dir = ROOT / "scripts" / "tests"
    named_tests = (
        ("check-scripts shell", "test-check-scripts.sh"),
        ("panel frontend install shell", "test-panel-frontend-install.sh"),
        ("run-unit-tests shell", "test-run-unit-tests.sh"),
        ("Linux-only command shell", "test-run-linux-only.sh"),
        ("run-step shell", "test-run-step.sh"),
        ("remote-daemon-deploy shell", "test-remote-daemon-deploy.sh"),
        ("clean-build-caches shell", "test-clean-build-caches.sh"),
        ("clean-stale-lanes shell", "test-clean-stale-lanes.sh"),
        ("mcp shell", "test-mcp-scripts.sh"),
        ("swarm e2e contract shell", "test-e2e-swarm-contract.sh"),
        ("e2e triage-run shell", "test-e2e-triage-run.sh"),
    )
    fanout_heavy = {
        "Linux-only command shell",
        "clean-build-caches shell",
        "mcp shell",
        "run-unit-tests shell",
    }
    tasks = [
        replace(
            _task(label, tests_dir / name),
            priority=650 if label in fanout_heavy else 100,
            weight=2 if label in fanout_heavy else 1,
            group="support shell-heavy" if label in fanout_heavy else "",
            group_limit=3 if label in fanout_heavy else 0,
        )
        for label, name in named_tests
    ]
    tasks.append(
        _task("Rust build-lane cache canary", ROOT / "scripts" / "rust-build-cache-canary.sh")
    )
    if os.environ.get("HARNESS_CHECK_SCRIPTS_FULL") == "1":
        tasks.append(_task("stale-scan shell", tests_dir / "test-stale-scan.sh"))
    return _round_robin(
        (
            tasks,
            _scenario_tasks(
                "jobserver",
                tests_dir / "test-jobserver.sh",
                group="jobserver",
                group_limit=6,
                priority=500,
                priority_overrides={
                    "scenario_stalled_supervisor_does_not_hang_the_command": 1000,
                    "scenario_a_wiped_pool_does_not_wedge_its_successor": 800,
                    "scenario_second_client_gets_the_remainder": 800,
                    "scenario_sigkilled_client_returns_its_tokens": 800,
                },
                weight=2,
            ),
            _scenario_tasks(
                "version",
                tests_dir / "test-version.sh",
                group="version",
                group_limit=6,
                priority=650,
                weight=2,
            ),
        )
    )


def _recording_triage_tasks(host_os: str) -> list[Task]:
    tests_dir = ROOT / "scripts" / "e2e" / "recording-triage" / "tests"
    portable = (
        "test_assert_launch_args.sh",
        "test_assert_recording.sh",
        "test_build_fixture.sh",
        "test_e2e_copy_preserves_mtime.sh",
        "test_extract_keyframes.sh",
    )
    macos = (
        "test_act_timing.sh",
        "test_assert_act_identifiers.sh",
        "test_auto_keyframes.sh",
        "test_compare_keyframes.sh",
        "test_compare_layout.sh",
        "test_emit_checklist.sh",
        "test_frame_gaps.sh",
        "test_run_all.sh",
    )
    names = portable + (macos if host_os == "Darwin" else ())
    return [
        _task(f"recording triage: {Path(name).stem}", tests_dir / name)
        for name in names
    ]


def _swarm_iterate_tasks() -> list[Task]:
    tests_dir = ROOT / "scripts" / "swarm-iterate" / "tests"
    tasks = [
        _task(f"swarm iterate: {path.stem}", path)
        for path in sorted(tests_dir.glob("test_*.sh"))
    ]
    tasks.append(
        _task(
            "active ledger shell check",
            ROOT / "scripts" / "swarm-iterate" / "check-active-ledger.sh",
        )
    )
    return tasks


def _support_tasks(host_os: str) -> list[Task]:
    return _round_robin(
        (
            _root_python_tasks(host_os),
            _monitor_python_tasks(host_os),
            _ordinary_shell_tasks(),
            _recording_triage_tasks(host_os),
            _swarm_iterate_tasks(),
        )
    )


def build_tasks(suite: str, host_os: str | None = None) -> tuple[Task, ...]:
    selected_host = host_os or platform.system()
    release_script = ROOT / "scripts" / "tests" / "test-release-install.sh"
    cargo_script = ROOT / "scripts" / "tests" / "test-cargo-local.sh"
    if suite == "release-install":
        return tuple(
            _scenario_tasks(
                "release install",
                release_script,
                group="release install",
                group_limit=12,
                priority=600,
            )
        )
    if suite == "cargo-local":
        return tuple(
            _scenario_tasks(
                "cargo-local",
                cargo_script,
                exclusive=frozenset(
                    {"scenario_symlinked_repo_tmpdir_base_is_rejected"}
                ),
                group="cargo-local",
                group_limit=8,
                priority=600,
                weight=2,
            )
        )
    if suite == "support":
        return tuple(_support_tasks(selected_host))
    release_tasks = _scenario_tasks(
        "release install",
        release_script,
        group="release install",
        group_limit=12,
        priority=600,
    )
    cargo_tasks = _scenario_tasks(
        "cargo-local",
        cargo_script,
        exclusive=frozenset({"scenario_symlinked_repo_tmpdir_base_is_rejected"}),
        group="cargo-local",
        group_limit=8,
        priority=600,
        weight=2,
    )
    return tuple(
        _round_robin(
            (
                _support_tasks(selected_host),
                release_tasks,
                cargo_tasks,
            )
        )
    )


def _run_task_groups(
    tasks: tuple[Task, ...],
    *,
    max_workers: int,
    timeout_seconds: float,
) -> RunSummary:
    started = time.monotonic()
    with TemporaryDirectory(prefix="hst.", dir="/tmp") as directory:
        sandbox_root = Path(directory)
        try:
            prepared_tasks = _prepare_tasks(tasks, sandbox_root)
            parallel = tuple(task for task in prepared_tasks if not task.exclusive)
            exclusive = tuple(task for task in prepared_tasks if task.exclusive)
            parallel_summary = run_tasks(
                parallel,
                max_workers=max_workers,
                timeout_seconds=timeout_seconds,
                sandbox_root=sandbox_root,
                run_token=sandbox_root.name,
            )
            exclusive_summary = run_tasks(
                exclusive,
                max_workers=1,
                timeout_seconds=timeout_seconds,
                sandbox_root=sandbox_root / "exclusive",
                run_token=sandbox_root.name,
            )
        finally:
            _terminate_owned_processes(sandbox_root)
    return RunSummary(
        results=parallel_summary.results + exclusive_summary.results,
        elapsed_seconds=time.monotonic() - started,
    )


def compile_c_fixture(source: Path, output: Path) -> None:
    if output.is_file() and output.stat().st_mtime_ns >= source.stat().st_mtime_ns:
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    staged_output = output.with_name(f"{output.name}.{os.getpid()}.tmp")
    subprocess.run(
        ("cc", "-std=c99", "-O0", "-o", str(staged_output), str(source)),
        check=True,
        capture_output=True,
        text=True,
    )
    os.replace(staged_output, output)


def compile_release_fixture(output: Path) -> None:
    compile_c_fixture(
        ROOT / "scripts" / "tests" / "fixtures" / "fake-release-binary.c",
        output,
    )


def _prepare_tasks(tasks: tuple[Task, ...], sandbox_root: Path) -> tuple[Task, ...]:
    if any(_is_monitor_xcodebuild_label(task.label) for task in tasks):
        monitor_fixture = (
            ROOT / "target" / "script-tests" / "fake-monitor-build-tool"
        )
        compile_c_fixture(
            ROOT
            / "scripts"
            / "tests"
            / "fixtures"
            / "fake-monitor-build-tool.c",
            monitor_fixture,
        )
        tasks = tuple(
            replace(
                task,
                environment={
                    **task.environment,
                    "HARNESS_MONITOR_SCRIPT_TEST_TOOL_FIXTURE": str(
                        monitor_fixture
                    ),
                },
            )
            if _is_monitor_xcodebuild_label(task.label)
            else task
            for task in tasks
        )
    fsmonitor_prefix = "root macOS python: clean stale fsmonitor"
    if any(task.label.startswith(fsmonitor_prefix) for task in tasks):
        fsmonitor_fixture = (
            ROOT / "target" / "script-tests" / "fake-fsmonitor-tool"
        )
        compile_c_fixture(
            ROOT
            / "scripts"
            / "tests"
            / "fixtures"
            / "fake-fsmonitor-tool.c",
            fsmonitor_fixture,
        )
        tasks = tuple(
            replace(
                task,
                environment={
                    **task.environment,
                    "HARNESS_FSMONITOR_SCRIPT_TEST_TOOL_FIXTURE": str(
                        fsmonitor_fixture
                    ),
                },
            )
            if task.label.startswith(fsmonitor_prefix)
            else task
            for task in tasks
        )
    if not any(task.label.startswith("release install:") for task in tasks):
        return tasks
    fixture = ROOT / "target" / "script-tests" / "fake-release-binary"
    compile_release_fixture(fixture)
    real_validation_tests = (
        "adapter_probe_requires_exact_identity",
        "focused_install_rejects_corrupt_carried_binary",
        "first_panel_only_install_uses_its_own_version",
        "independent_panel_version_is_accepted",
        "legacy_adapter_probes_are_normalized_before_activation",
        "non_owned_entrypoint_is_preserved",
        "untrusted_legacy_adapter_probe_is_preserved",
    )
    full_inventory_tests = (
        "atomic_install_activates_all_binaries",
        "release_inventory_is_platform_aware",
    )
    inventory_profiles = {
        "adapter_probe_requires_exact_identity": (
            "harness-codex-acp",
            "codex",
        ),
        "aff_install_ignores_unrelated_foreign_harness": ("aff", "aff"),
        "build_group_allocates_one_budget": (
            "harness harness-daemon harness-systemd harness-codex-acp",
            "harness daemon systemd codex",
        ),
        "build_group_cancels_siblings": (
            "harness harness-daemon harness-codex-acp",
            "harness daemon codex",
        ),
        "build_group_queues_below_leaf_count": (
            "harness harness-daemon harness-bridge harness-openrouter-agent",
            "harness daemon bridge openrouter",
        ),
        "darwin_excludes_systemd_and_migrates_managed_link": (
            "harness harness-systemd",
            "harness systemd",
        ),
        "missing_build_artifact_aborts_publication": (
            "harness harness-daemon harness-mcp",
            "harness daemon mcp",
        ),
        "overlapping_build_groups_keep_separate_logs": (
            "harness harness-daemon harness-mcp",
            "harness daemon mcp",
        ),
        "pipeline_lock_spans_build_and_install": (
            "harness harness-daemon",
            "harness daemon",
        ),
        "unexpected_coordinator_exit_cleans_children_and_lock": (
            "harness harness-daemon",
            "harness daemon",
        ),
        "entrypoint_failure_rolls_back_partial_publication": (
            "harness harness-daemon",
            "harness daemon",
        ),
        "focused_install_rejects_corrupt_carried_binary": (
            "harness aff",
            "harness aff",
        ),
        "focused_install_verifies_carried_signature": (
            "harness aff",
            "harness aff",
        ),
        "first_install_activates_before_entrypoints": (
            "harness aff",
            "harness aff",
        ),
        "first_panel_only_install_uses_its_own_version": (
            "harness-panel",
            "panel",
        ),
        "harness_cli_alias_selects_only_the_cli_leaf": (
            "harness harness-daemon",
            "harness daemon",
        ),
        "independent_panel_version_is_accepted": (
            "harness harness-panel",
            "harness panel",
        ),
        "legacy_adapter_probes_are_normalized_before_activation": (
            "harness harness-codex-acp harness-openrouter-agent",
            "harness codex openrouter",
        ),
        "legacy_binaries_are_normalized_before_activation": (
            "harness aff",
            "harness aff",
        ),
        "failed_legacy_normalization_restores_direct_files": (
            "harness aff",
            "harness aff",
        ),
        "live_worker_release_survives_retention": (
            "harness harness-daemon",
            "harness daemon",
        ),
        "multi_selector_install_updates_only_requested_leaves": (
            "harness harness-daemon harness-mcp",
            "harness daemon mcp",
        ),
        "single_leaf_install_carries_the_rest_forward": (
            "harness harness-daemon aff",
            "harness daemon aff",
        ),
        "single_leaf_install_ignores_stale_release_artifact": (
            "harness harness-daemon",
            "harness daemon",
        ),
        "leaf_only_install_skips_cli_legacy_detection": (
            "harness harness-daemon",
            "harness daemon",
        ),
        "untrusted_legacy_adapter_probe_is_preserved": (
            "harness-codex-acp",
            "codex",
        ),
    }
    prepared = []
    for task in tasks:
        if task.label.startswith("release install:"):
            environment = {
                **task.environment,
                "HARNESS_RELEASE_TEST_BINARY_TEMPLATE": str(fixture),
                "HARNESS_RELEASE_TEST_PROCESS_START_MARKER": "script-test-process",
            }
            if not any(name in task.label for name in real_validation_tests):
                environment["HARNESS_INSTALL_TEST_TRUST_ARTIFACTS"] = "1"
            if not any(name in task.label for name in full_inventory_tests):
                binaries, leaves = next(
                    (
                        profile
                        for name, profile in inventory_profiles.items()
                        if name in task.label
                    ),
                    ("harness", "harness"),
                )
                environment["HARNESS_INSTALL_TEST_INVENTORY_BINARIES"] = binaries
                environment["HARNESS_INSTALL_TEST_INVENTORY_LEAVES"] = leaves
            if "darwin_excludes_systemd" in task.label:
                environment[
                    "HARNESS_INSTALL_TEST_DARWIN_INACTIVE_BINARIES"
                ] = "harness-systemd"
            weight = 1
            if any(
                name in task.label
                for name in (
                    "build_group_",
                    "darwin_excludes_systemd",
                    "missing_build_artifact",
                    "overlapping_build_groups",
                    "pipeline_lock_spans",
                    "unexpected_coordinator_exit",
                )
            ):
                weight = 2
            if "atomic_install_activates_all_binaries" in task.label:
                weight = 3
            if "legacy_adapter_probes" in task.label:
                weight = 2
            task = replace(task, environment=environment, weight=weight)
        prepared.append(task)
    return tuple(prepared)


def _positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--suite",
        choices=("all", "cargo-local", "release-install", "support"),
        default="all",
    )
    parser.add_argument(
        "--jobs",
        type=_positive_int,
        default=os.environ.get("HARNESS_SCRIPT_TEST_JOBS"),
    )
    parser.add_argument(
        "--budget-seconds",
        type=_positive_float,
        default=os.environ.get("HARNESS_SCRIPT_TEST_BUDGET_SECONDS"),
        help="fail when the suite exceeds this opt-in wall-clock budget",
    )
    parser.add_argument(
        "--task-timeout-seconds",
        type=_positive_float,
        default=os.environ.get("HARNESS_SCRIPT_TEST_TASK_TIMEOUT_SECONDS", "180"),
    )
    parser.add_argument(
        "--filter",
        default=os.environ.get("HARNESS_SCRIPT_TEST_FILTER", ""),
        help="run only tasks whose label contains this text",
    )
    return parser.parse_args()


def main() -> int:
    started = time.monotonic()
    arguments = _arguments()
    if arguments.jobs is None:
        cpu_count = os.cpu_count() or 1
        arguments.jobs = cpu_count * 2
    tasks = build_tasks(arguments.suite)
    if arguments.filter:
        tasks = tuple(task for task in tasks if arguments.filter in task.label)
        if not tasks:
            print(
                f"error: no {arguments.suite} script test matched "
                f"{arguments.filter!r}",
                file=sys.stderr,
            )
            return 2
    summary = _run_task_groups(
        tasks,
        max_workers=arguments.jobs,
        timeout_seconds=arguments.task_timeout_seconds,
    )
    elapsed_seconds = time.monotonic() - started
    failures = 0
    show_output = os.environ.get("HARNESS_SCRIPT_TEST_SHOW_OUTPUT") == "1"
    for result in summary.results:
        if result.returncode == 0:
            print(f"ok: {result.task.label} ({result.elapsed_seconds:.2f}s)")
            if show_output and result.output:
                print(result.output.rstrip())
            continue
        failures += 1
        print(
            f"error: {result.task.label} failed with status "
            f"{result.returncode} ({result.elapsed_seconds:.2f}s)",
            file=sys.stderr,
        )
        if result.output:
            print(result.output.rstrip(), file=sys.stderr)

    over_budget = (
        arguments.budget_seconds is not None
        and elapsed_seconds >= arguments.budget_seconds
    )
    if over_budget:
        failures += 1
        print(
            f"error: {arguments.suite} script tests exceeded "
            f"{arguments.budget_seconds:g}s budget "
            f"({elapsed_seconds:.2f}s)",
            file=sys.stderr,
        )
    passed = sum(result.returncode == 0 for result in summary.results)
    budget = (
        f"budget {arguments.budget_seconds:g}s"
        if arguments.budget_seconds is not None
        else "budget disabled"
    )
    print(
        f"script tests: {passed} passed, "
        f"{len(summary.results) - passed} failed in {elapsed_seconds:.2f}s "
        f"({budget}, jobs {arguments.jobs})"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
