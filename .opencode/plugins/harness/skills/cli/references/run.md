# `run` references

## `run` subcommand map

| Command | Purpose |
| --- | --- |
| `start` | Start a tracked run |
| `init` | Initialize tracked run state |
| `preflight` | Run preflight checks |
| `capture` | Capture run evidence |
| `record` | Record a command in the run log |
| `restart-namespace` | Restart workloads in a namespace |
| `apply` | Apply manifests into the run flow |
| `validate` | Validate manifests |
| `doctor` | Diagnose tracked run state and pointers |
| `repair` | Repair deterministic run state and current-run pointers |
| `runner-state` | Print or apply explicit workflow events |
| `resume` | Reattach to or resume an unfinished run |
| `finish` | Mark execution finished |
| `closeout` | Run closeout steps |
| `report` | Report-writing helpers |
| `diff` | Compare run artifacts |
| `envoy` | Envoy inspection helpers |
| `kuma` | Kuma-focused helpers |
| `status` | Print the current run status report |
| `logs` | View run-managed logs |
| `cluster-check` | Inspect cluster readiness for the run |
| `task` | Wait for or tail task output files |

Sources: `cargo run --quiet -- run --help`; `src/app/cli.rs:42-68`.

## Recovery loop

| Step | Command | What it tells or fixes | Recovery flags worth knowing |
| --- | --- | --- | --- |
| 1 | `harness run resume` | Reattach to an unfinished run; records `status: resumed` or `status: attached` and prints `next:` guidance | `--message <MESSAGE>` adds a resume note; `--run-dir`, `--run-id`, `--run-root` select the run |
| 2 | `harness run status` | Dumps the current structured status report for the resolved run | `--run-dir`, `--run-id`, `--run-root` |
| 3 | `harness run doctor` | Diagnoses run state and pointer health; exits `0` when healthy, `2` when checks fail | `--json` for machine-readable output plus the shared run selectors |
| 4 | `harness run repair` | Repairs deterministic run state and the current-run pointer | `--json` for machine-readable output plus the shared run selectors |
| 5 | `harness run doctor` | Re-run diagnostics to confirm repair results | Same as step 3 |

Sources: `cargo run --quiet -- run resume --help`; `cargo run --quiet -- run status --help`; `cargo run --quiet -- run doctor --help`; `cargo run --quiet -- run repair --help`; `src/run/commands/resume.rs:15-40`; `src/run/commands/status.rs:15-33`; `src/run/commands/doctor.rs:15-84`; `src/run/commands/repair.rs:16-34`.

## Shared run selectors

| Flag | Meaning |
| --- | --- |
| `--run-dir <RUN_DIR>` | Point at one exact run directory |
| `--run-id <RUN_ID>` | Resolve a run from session context |
| `--run-root <RUN_ROOT>` | Change the parent directory used to resolve `--run-id` |

For recovery commands, resolution is: `--run-dir` first; otherwise `--run-root` + `--run-id`; otherwise the current-run pointer. `--run-id` without `--run-root` errors instead of searching fallback roots.

Sources: `cargo run --quiet -- run resume --help`; `src/run/args.rs:5-17`; `src/run/resolve.rs:17-55`.

## Recovery-adjacent commands

| Command | When to reach for it | Key surface |
| --- | --- | --- |
| `harness run runner-state` | Inspect the current workflow phase or push an explicit event into runner state | `--event <EVENT>`, `--suite-target <SUITE_TARGET>`, `--message <MESSAGE>`, shared run selectors |
| `harness run report` | Validate report compactness or finalize one completed group | Subcommands: `check`, `group` |
| `harness run task` | Wait for background task completion or tail task output files | Subcommands: `wait`, `tail` |

`runner-state --event` currently accepts: `cluster-prepared`, `preflight-started`, `preflight-captured`, `preflight-failed`, `failure-manifest`, `manifest-fix-run-only`, `manifest-fix-suite-and-run`, `manifest-fix-skip-step`, `manifest-fix-stop-run`, `suite-fix-resumed`, `abort`, `suspend`, `resume-run`, `closeout-started`, `run-completed`.

Sources: `cargo run --quiet -- run runner-state --help`; `cargo run --quiet -- run report --help`; `cargo run --quiet -- run task --help`; `src/run/commands/runner_state.rs:21-70`; `src/run/commands/report.rs`; `src/run/commands/task.rs`.
