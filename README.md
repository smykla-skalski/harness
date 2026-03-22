# harness

`harness` is a CLI for running Kubernetes and Kuma tests.

It helps you:

- start a disposable test environment
- create a test suite
- run that suite step by step
- keep a record of what happened

If you use it with Claude Code, harness also installs hooks that block unsafe shortcuts, such as talking to a cluster directly outside the tracked workflow.

If you want the internal structure, see [ARCHITECTURE.md](ARCHITECTURE.md). This README is about day-to-day use.

## What the main commands do

Most people only need these four command groups:

- `harness setup` prepares local environments and session state
- `harness create` helps you build a new suite
- `harness run` executes a suite
- `harness observe` scans logs and points out mistakes or failures

You will also see `hook`, `session-start`, `session-stop`, and `pre-compact`. Those are mostly for editor and hook integration. You usually do not run them by hand.

## The basic idea

- A **suite** is the test definition. It usually lives in a `suite.md` file.
- A **create session** is the guided flow for writing a new suite.
- A **run** is one execution of a suite against a real cluster.
- **observe** helps explain what went wrong after or during a session.

In order:

1. `setup`
2. `create`
3. `run`
4. `observe`

## Install

If you are building from source:

```bash
mise run install
```

That builds a release binary and installs `harness` to `~/.local/bin`.

Requirements:

- Rust `1.94+`

## A normal run

This is the usual flow when you already have a suite.

```bash
REPO=/path/to/repo
SUITE=$REPO/suites/my-feature
RUN_ID=my-feature-001

# 1. Start a disposable cluster
harness setup kuma cluster single-up dev --repo-root "$REPO"

# 2. Start the tracked run and prepare it
harness run start --suite "$SUITE" --run-id "$RUN_ID" --profile single-zone --repo-root "$REPO"

# 3. Apply or record work through harness
harness run apply --manifest manifests/app.yaml
harness run record -- kubectl get pods -A

# 4. Finish the run
harness run finish
```

Harness stores the run state on disk, so you can inspect it later and the command history stays attached to the run instead of disappearing into shell history.

If you need to pick an unfinished run back up, use `harness run resume --run-id <id> --run-root <path>` or just `harness run resume` when the current run pointer is already active.

## Creating a suite

Use `create` when you are writing a new suite or changing one.

```bash
REPO=/path/to/repo
SUITE_DIR=$REPO/suites/my-feature

harness create begin \
  --repo-root "$REPO" \
  --feature my-feature \
  --mode interactive \
  --suite-dir "$SUITE_DIR" \
  --suite-name my-feature

harness create approval-begin \
  --mode interactive \
  --suite-dir "$SUITE_DIR"

harness create show --kind session
harness create validate
```

Useful create commands:

- `harness create begin` starts the create workspace
- `harness create approval-begin` starts the approval state used by hooks
- `harness create show` prints the current create state
- `harness create save` saves progress
- `harness create validate` checks the suite content
- `harness create reset` clears the current create state

## Rules

- Use harness commands for cluster work. Do not go around it with direct `kubectl`, `helm`, `docker`, `k3d`, or similar calls.
- Treat the run directory as the source of truth for a run.
- Treat the suite directory as the source of truth for a suite.
- Use `observe` when something feels off instead of guessing from memory.

## Where harness stores things

Harness uses XDG-style state directories.

- suites: `$XDG_DATA_HOME/harness/suites/`
- runs: `$XDG_DATA_HOME/harness/runs/<run-id>/`
- session context: `$XDG_DATA_HOME/harness/contexts/<session-hash>/`

A run directory usually contains:

- `artifacts/` for collected output
- `commands/` for recorded command logs
- `manifests/` for prepared manifests
- `suite-run-state.json` for runner state
- `run-report.md` for the human-readable report

The create approval state lives in `.harness/suite-create-state.json`.

## When you get stuck

Start here:

- `harness observe scan` to classify problems in session logs
- `run-report.md` in the run directory for the high-level result
- `commands/` in the run directory for the exact command history

If the run state is stale or broken, start a fresh tracked run with `harness run start` instead of trying to patch state files by hand.

## For contributors

The main checks are:

```bash
mise run check
mise run test
```

If you need the full internal map, use [ARCHITECTURE.md](ARCHITECTURE.md).
