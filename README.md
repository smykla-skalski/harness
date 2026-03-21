# harness

Test orchestration framework for Kubernetes/Kuma. Tracks every run through a state machine, logs all commands, and blocks direct cluster access so tests are reproducible and auditable.

Architecture map: [`ARCHITECTURE.md`](ARCHITECTURE.md)

## How it works

A suite is a Markdown file with YAML frontmatter describing what to test - user stories, Helm values, manifest groups. A run is one execution of a suite against a real cluster.

Runs move through phases: `bootstrap` -> `preflight` -> `execution` -> `triage` -> `closeout` -> `completed`. Runner state is persisted atomically in `suite-run-state.json` using schema version `2`, so interrupted runs can resume or be inspected after the fact.

The CLI enforces this lifecycle. Direct use of `kubectl`, `helm`, `docker`, or `k3d` is blocked - all cluster access goes through harness commands. This lets you replay or audit exactly what happened during a run. Suite create uses a separate approval workflow stored in `.harness/suite-create-state.json`, also on schema version `2`.

## Install

```bash
cargo build --release
# copy target/release/harness somewhere on your PATH
```

Requires Rust 1.94+.

## Quick start

```bash
# spin up a disposable cluster
harness setup kuma cluster single-up my-cluster --repo-root /path/to/repo

# create a run from a suite file
harness run init --suite suites/my-feature.md --run-id run-1 --profile single-zone --repo-root /path/to/repo

# run preflight checks and prepare manifests
harness run preflight --run-dir $XDG_DATA_HOME/harness/runs/run-1

# apply manifests and record commands
harness run apply --manifest manifests/app.yaml --run-dir ...
harness run record --run-dir ... -- kubectl get pods

# close out
harness run closeout --run-dir ...
```

## Runs and state

Run directories live under `$XDG_DATA_HOME/harness/runs/{run-id}/`:

```
artifacts/          collected outputs
commands/           per-command logs with exit codes and timing
manifests/          prepared Kubernetes manifests
state/              auxiliary component state such as `cluster.json`
suite-run-state.json schema-versioned runner workflow state (current schema: 2)
run-metadata.json   immutable: suite, profile, user stories
run-status.json     mutable: verdict, group pass/fail counts
run-report.md       human-readable summary
```

Older `suite-run-state.json` files are rejected. Delete the file or re-run `harness run init` to regenerate the runner state.

## Suite create

Harness has a two-part create flow for writing new suites: `create begin` creates the session workspace for `suite:create`, and `create approval-begin` initializes the approval workflow state that review hooks read.

```bash
harness create begin --skill suite:create --repo-root /path/to/repo --feature my-feature --mode interactive --suite-dir /path/to/repo/suites/my-feature --suite-name my-feature
harness create approval-begin --skill suite:create --mode interactive --suite-dir /path/to/repo/suites/my-feature
```

Create moves through `discovery` -> `prewrite_review` -> `writing` -> `postwrite_review` -> `complete`, with approval gates at each review step. Use `harness create save`, `harness create show`, `harness create reset`, and `harness create validate` during the session. The approval state lives in `.harness/suite-create-state.json` on schema version `2`; older files are rejected and must be regenerated with `harness create approval-begin`.

## Hook system

When running inside Claude Code, harness registers 11 hooks that intercept tool calls:

- Pre-tool guards: `guard-bash`, `guard-write`, `guard-question`
- Post-tool verifies: `verify-bash`, `verify-write`, `verify-question`, `audit`
- Failure enrichment: `enrich-failure`
- Subagent gates: `context-agent`, `validate-agent`
- Blocking: `guard-stop`

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
