# Contents

1. [Non-negotiable rules](#non-negotiable-rules)
2. [Operating mode](#operating-mode)
3. [Persistent data directory](#persistent-data-directory)
4. [Local kumactl setup](#local-kumactl-setup)
5. [Run status tracking](#run-status-tracking)
6. [Artifacts to collect per test case](#artifacts-to-collect-per-test-case)
7. [Failure policy](#failure-policy)
8. [Bug triage protocol](#bug-triage-protocol)
9. [Reproducibility minimum bar](#reproducibility-minimum-bar)

---

# Agent contract

Rules for any AI agent executing manual tests with this harness.

## Non-negotiable rules

1. Use locally built `kumactl` from `build/` only. Never the system binary.
2. Apply every manifest through `harness run apply`. All manifest paths are relative - harness resolves them from the suite and run directories automatically. Use `harness run apply --manifest g02/04.yaml --step my-step`, not shell variable construction like `SD=... && harness run apply --manifest ${SD}/g02/04.yaml`. Never construct shell variables (`SD=`, `SUITE_DIR=`, `KUBECONFIG=`, `PATH=`, `REPO_ROOT=`) in Bash commands to build paths. Never use `export`. The only exception is the Phase 0/1 start flow where `harness run start` needs explicit flags.
3. Do not run bare kubectl, kumactl, or curl commands against the cluster. Use `harness run record --phase <phase> --label <label> --gid <group-id> -- kubectl <args>` for kubectl, `harness run record --phase <phase> --label <label> --gid <group-id> -- kumactl <args>` for kumactl, and `harness run record --phase <phase> --label <label> --gid <group-id> -- <command>` for `curl` and other non-wrapped commands so they stay audited during Phase 4 execution. Use `harness run envoy ...` for Envoy admin endpoints. Prefer one-command live inspection such as `harness run envoy capture --grep ...`, `harness run envoy capture --type-contains ...`, `harness run envoy route-body`, or `harness run envoy bootstrap` instead of capture-then-read flows. For raw `kubectl`, `harness run record` injects the tracked local `--kubeconfig` and must fail closed instead of using ambient kube context when the active run has no tracked local kubeconfig yet. Do not pass kubeconfig or cluster-target override flags through tracked `kubectl` commands, and do not fall back to raw `kubectl --kubeconfig ...` after resume or compaction. The only other exceptions are commands already wrapped by `harness` subcommands such as `apply`, `capture`, `preflight`, `cluster`, `gateway`, and `validate`. Outside the execution phase, omit `--gid`. Any bare `kubectl`, `kumactl`, or `curl` command is wrong.
4. `harness run start` is the normal suite preparation step for a fresh run. It initializes the run, materializes baseline manifests and group `## Configure` YAML into the active run's prepared manifests directory, validates them, applies baselines once, and writes the prepared-suite artifact. `harness run preflight` is the recovery path when an already-created run needs those artifacts refreshed after cluster drift. Do not redo that work during every group.
5. Capture cluster state snapshots before and after each test group. This is a hard gate - do not start the next group until the state capture for the completed group is saved.
6. Stop and triage on first unexpected failure.
7. Keep reports concise - store raw output in `artifacts/`, reference file paths.
8. Never create manifests in `/tmp` or any location outside the active run's `manifests/` directory. When the suite already provides a prepared manifest in the active run's prepared manifests directory, reuse that path instead of copying it a second time.
9. When a suite group provides inline manifest YAML, use it verbatim. Do not change names, namespaces, labels, or any fields. If a manifest fails validation or apply, follow the manifest error handling flow in [validation.md](validation.md): move the runner into failure triage, ask the exact canonical AskUserQuestion gate, and only allow `Fix in suite and this run` to touch the approved suite file plus `amendments.md`. Never silently fix a manifest - the error might indicate a real product bug.
10. Every artifact path written in the report must resolve to an existing file in the run directory. Before closeout, verify every path. A report that references missing files is a broken run.
11. Update `run-status.json` after every completed group with `last_completed_group`, `next_planned_group`, counts, and timestamp. This is a hard gate - do not start the next group without updating status first.
12. During Phase 4, do not re-parse group frontmatter. Use the active run's prepared-suite artifact as the runtime source of truth for prepared manifest paths plus `helm_values` and `restart_namespaces`.
13. No autonomous deviations. Any divergence from the suite definition - different manifest values, skipped steps, reordered steps, extra steps, modified expected outcomes - requires explicit user approval via AskUserQuestion before the change is made. The only exception is when the suite definition itself explicitly marks a decision as agent-discretionary (e.g., "agent may choose" or "optional"). Even suite-allowed deviations must be recorded. Record every deviation in the report as a "Deviation" entry with: (a) what was changed, (b) why, (c) whether it was user-approved or suite-allowed, and (d) the exact user response if user-approved.
14. **The test groups table is the execution plan.** Every group listed in the suite's test groups table must be executed. Do not skip groups because they need a different cluster profile than what's currently running. If a group requires multi-zone, tear down single-zone and bring up multi-zone. If that's impractical, ask the user via AskUserQuestion with options [Switch cluster profile, Fix prerequisites, Skip group, Stop run]. Only the `skipped groups` field in suite metadata lists groups that are excluded. Do not mark a group as skip without explicit user approval through AskUserQuestion. Skipping without approval invalidates the entire run.
15. **Commit code fixes before continuing.** When a test reveals a product bug and you fix it in the source code, commit the fix before continuing with the next test group. This prevents losing fixes on context compaction or session restart, and keeps the git history clean. The commit should only include the fix files (not local dev workarounds like commented-out CPU limits). Use the repo's commit conventions (`type(scope): description`, `-sS` flags). Do not bundle unrelated fixes into one commit - each distinct bug gets its own commit.
16. A Stop hook summary with `preventedContinuation: false` is advisory runtime metadata, not proof that the user asked to exit. Do not blame the user for it, do not mark the run `aborted` just to satisfy it, and do not edit `run-status.json` or `run-report.md` manually. If a run was already marked `aborted` by mistake and `next_planned_group` still exists, recover it through `harness run resume`.
17. **Never use `python3 -c` or `python -c` for JSON parsing or any other purpose.** Use `jq` for inline JSON filtering, or use `harness run envoy` commands for Envoy admin output. For Envoy config_dump inspection, prefer `harness run envoy capture --type-contains <type> --grep <pattern>` which captures and filters in one tracked command. Piping command output through python bypasses auditability and is always wrong.
18. **Never truncate verification output.** When running `make test`, `make check`, `cargo test`, `cargo clippy`, or any verification command, capture full output. Never pipe through `tail -N` or `head -N`. If output is long, grep for FAIL/error markers instead. Drawing conclusions from truncated output is unreliable because failures can be hidden above the truncation point.
19. **Execute groups in profile-contiguous order.** Never tear down a cluster and rebuild the same profile later. When `--profile all`, sort groups so all groups for one profile run together before moving to the next profile. Order: standalone/no-cluster, single-zone Kubernetes, single-zone universal, multi-zone Kubernetes, multi-zone universal. When transitioning between profiles, overlap teardown and setup by running teardown in background (`run_in_background: true`) while starting the next cluster in foreground.

## Operating mode

- Be systematic, not fast.
- Favor reproducibility over speed.
- Keep one source of truth per run in the active suite's `runs/<run-id>/` directory.
- Treat missing artifacts as "test not executed".

## Persistent data directory

All run artifacts and authored suites are stored in a persistent data directory outside the repo:

```
${XDG_DATA_HOME:-$HOME/.local/share}/harness/
├── contexts/                # Session-scoped current-run and hook snapshots
└── suites/                  # Created test suites (by suite:create)
    └── motb-core/           # Directory-format suite
        ├── suite.md
        ├── baseline/
        │   └── *.yaml
        ├── groups/
        │   └── g{NN}-*.md
        └── runs/            # Test run artifacts (by suite:run)
            └── <run-id>/
```

## Local kumactl setup

```bash
harness run record --repo-root "${REPO_ROOT}" --phase setup --label kumactl-version \
  -- kumactl version
```

Record `kumactl version` output in the run report. Before the control plane exists, `kumactl version` may print a server connection warning on stderr; use the `Client:` line to verify the local binary version.

For Mesh\* policy create, matching, and debug commands, follow
[mesh-policies.md](mesh-policies.md).

## Run status tracking

After each test group, run `harness run report group --group-id <group-id> --status <pass|fail|skip> [--evidence-label <record-label>] [--evidence <run-artifact>] [...]`. Prefer `--evidence-label` when the artifact came from `harness run record --label ...` or `harness run envoy capture --label ...` so the runner resolves the latest tracked artifact instead of guessing a timestamped filename. The command updates `run-status.json` and `run-report.md` together with:

- `last_completed_group`: the group just finished (e.g. "G3")
- `next_planned_group`: the next group to execute (e.g. "G4")
- `counts`: running pass/fail/skipped totals
- `last_updated_utc`: timestamp

This enables resuming partial runs. See [workflow.md](workflow.md) (resuming a partial run).

## Artifacts to collect per test case

- Manifest file copy in `runs/<run-id>/manifests/*.yaml`
- Command output logs in `runs/<run-id>/commands/*.txt` for every recorded command (inspect, curl, delete, etc.)
- Command log entry in `runs/<run-id>/commands/command-log.md` for every command executed
- State capture in `runs/<run-id>/state/` after each group completion
- Result and interpretation in `runs/<run-id>/run-report.md`

Every verification command (`kumactl inspect`, `curl`, `kubectl get`) must produce an artifact file. Every cleanup command (`kubectl delete`) must have a command log entry. For suite-defined resources, prefer `kubectl delete -f` against the run's prepared manifest files and keep cleanup to one manifest or one resource kind per recorded command. Do not collapse multiple resource kinds into one bare `kubectl delete kind-a name-a kind-b name-b ...` call. If a command was worth running, it was worth recording through the tracked harness wrapper.

## Failure policy

On unexpected behavior:

1. Stop advancing the suite.
2. Re-run the failing step once to check determinism.
3. Snapshot cluster state immediately.
4. Classify the failure: manifest issue, environment issue, or product bug.
5. Continue only when classification is explicit in the report.

Never mark a test as pass with unresolved ambiguity.

## Bug triage protocol

When a bug is suspected, report:

- Exact manifest used and its SHA256
- Exact command sequence
- Observed vs expected output
- Scope assessment (single policy, all policies, one mode, all modes)
- Suggested next isolation step

## Reproducibility minimum bar

A run is complete only when all of these are present:

- Cluster profile used
- Kubeconfig paths used
- Local build/deploy commands
- Full manifest set
- Full command log
- Test report with pass/fail and artifact pointers
