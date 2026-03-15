# harness

Test orchestration framework for Kubernetes/Kuma. Tracks every run through a state machine, logs all commands, and blocks direct cluster access so tests are reproducible and auditable.

## How it works

A suite is a Markdown file with YAML frontmatter describing what to test - user stories, Helm values, manifest groups. A run is one execution of a suite against a real cluster.

Runs move through phases: `bootstrap` -> `preflight` -> `execution` -> `triage` -> `closeout` -> `completed`. State is persisted atomically to disk at each step, so interrupted runs can resume or be inspected after the fact.

The CLI enforces this lifecycle. Direct use of `kubectl`, `helm`, `docker`, or `k3d` is blocked - all cluster access goes through harness commands. This lets you replay or audit exactly what happened during a run.

## Install

```bash
cargo build --release
# copy target/release/harness somewhere on your PATH
```

Requires Rust 1.94+.

## Quick start

```bash
# spin up a disposable cluster
harness cluster single-up my-cluster --repo-root /path/to/repo

# create a run from a suite file
harness init --suite suites/my-feature.md --run-id run-1 --profile single-zone --repo-root /path/to/repo

# run preflight checks and prepare manifests
harness preflight --run-dir $XDG_DATA_HOME/kuma/runs/run-1

# apply manifests and record commands
harness apply --manifest manifests/app.yaml --run-dir ...
harness record --run-dir ... -- kubectl get pods

# close out
harness closeout --run-dir ...
```

## Runs and state

Run directories live under `$XDG_DATA_HOME/kuma/runs/{run-id}/`:

```
artifacts/          collected outputs
commands/           per-command logs with exit codes and timing
state/              versioned JSON workflow state
manifests/          prepared Kubernetes manifests
run-metadata.json   immutable: suite, profile, user stories
run-status.json     mutable: verdict, group pass/fail counts
run-report.md       human-readable summary
```

## Suite authoring

Harness has an interactive authoring flow for writing new suites:

```bash
harness authoring-begin --skill suite:new --repo-root /path --feature my-feature --suite-dir /path/suites
```

Authoring moves through `discovery` -> `prewrite_review` -> `writing` -> `postwrite_review` -> `complete`, with approval gates at each review step.

## Hook system

When running inside Claude Code, harness registers hooks that intercept tool calls:

- `guard-bash` - blocks direct cluster binary access
- `guard-write` - blocks writes outside the run surface
- `guard-stop` - prevents session end if a run is still in progress
- `verify-bash`, `verify-write` - post-tool audits
- `enrich-failure` - adds context to failed commands

## Development

```bash
cargo check                 # type-check
cargo build                 # build
cargo test --lib            # unit tests
cargo clippy --lib          # lint (pedantic deny)
cargo fmt                   # format
```

Pre-commit: `cargo fmt --check && cargo clippy --lib && cargo test`

Integration tests are in `tests/integration/` and cover hooks, commands, and workflows end-to-end.
