# Contents

1. [Resuming a partial run](#resuming-a-partial-run)
2. [Phase 0 - environment check](#phase-0---environment-check)
3. [Phase 1 - initialize run](#phase-1---initialize-run)
4. [Phase 2 - bootstrap cluster](#phase-2---bootstrap-cluster)
5. [Phase 3 - preflight](#phase-3---preflight)
6. [Phase 4 - execute tests](#phase-4---execute-tests)
7. [Phase 5 - failure handling](#phase-5---failure-handling)
8. [Phase 6 - closeout](#phase-6---closeout)
9. [Performance toggles](#performance-toggles)

---

# Workflow

Supplementary detail for the seven-phase execution flow in `SKILL.md`. Each phase includes its code blocks so this file is self-contained when loaded independently.

## Resuming a partial run

If a previous run was interrupted, do not re-run `harness init` for that existing run. Reattach the saved run context, then check `runs/<run-id>/run-status.json` for `last_completed_group` and `next_planned_group`. Skip to the next planned group and continue from there. Do not re-run already-passed groups unless investigating a failure.

If SessionStart already restored the matching active run for `--resume <run-id>`, skip the reattach command too. Read the restored run's `run-status.json` and continue from `next_planned_group`.

Only unfinished runs can resume. If the saved run already has a final `pass` or `fail` verdict, start a new run ID instead of reattaching it.

After restore, do not treat a remembered kubeconfig path as permission to run raw `kubectl` or `kubectl --kubeconfig ...`. Keep using `harness run --phase <phase> --label <label> kubectl <args>` or `harness record --phase <phase> --label <label> -- kubectl <args>`.

## Phase 0 - environment check

Resolve persistent storage and repo root first:

```bash
DATA_DIR="$(echo "${XDG_DATA_HOME:-$HOME/.local/share}/kuma/suites")"
```

Do not create `DATA_DIR` from `suite:run`. If it does not exist, stop and ask whether the suite should be authored first or a different suite path should be used.

Resolve `REPO_ROOT`: `--repo` flag > check if cwd has `go.mod` with `kumahq/kuma` > fail with message.

Build and verify kumactl:

```bash
harness run --repo-root "${REPO_ROOT}" --phase setup --label kumactl-version \
  kumactl version
```

## Phase 1 - initialize or resume run

If SessionStart already restored the matching active run for `--resume <run-id>`, skip this phase entirely.

For a fresh run:

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-manual"
PROFILE="<resolved --profile value>"
SUITE_PATH="<resolved suite path>"
SUITE_DIR="$(dirname "${SUITE_PATH}")"
harness init \
  --suite "${SUITE_PATH}" \
  --run-id "${RUN_ID}" \
  --profile "${PROFILE}" \
  --repo-root "${REPO_ROOT}"
RUN_DIR="${SUITE_DIR}/runs/${RUN_ID}"
```

For `--resume <run-id>`, reattach the existing run instead of reinitializing it:

```bash
RUN_ID="<resume run id>"
PROFILE="<resolved --profile value>"
SUITE_PATH="<resolved suite path>"
SUITE_DIR="$(dirname "${SUITE_PATH}")"
RUN_DIR="${SUITE_DIR}/runs/${RUN_ID}"
test -f "${RUN_DIR}/run-status.json"
harness run \
  --run-id "${RUN_ID}" \
  --run-root "${SUITE_DIR}/runs" \
  --repo-root "${REPO_ROOT}" \
  --phase setup \
  --label kumactl-version \
  kumactl version
```

Suite resolution uses the two-step order (managed directory suite, literal path). Set `SUITE_DIR` and `SUITE_FILE` accordingly.

After fresh `harness init` or the explicit resume reattach command, rely on the active `current-run.json` shim for run path, suite path, profile, and later cluster context. The harness also saves that active run in project state, so fresh sessions can restore it automatically. The remaining commands must omit repeated `--run-dir`, `--run-root`, `--repo-root`, and `--kubeconfig` flags unless debugging a broken run context. Do not switch to raw `kubectl --kubeconfig ...`; the canonical tracked forms remain `harness run --phase <phase> --label <label> kubectl <args>` and `harness record --phase <phase> --label <label> -- kubectl <args>`.

**Gate**: the `Client:` line in the recorded `kumactl version` output matches the repo HEAD. A server connection warning on stderr is expected until the control plane exists.

Fill `run-metadata.json` before touching the cluster.

**Gate**: `run-metadata.json` exists and has profile, feature scope, and environment filled in.

## Phase 2 - bootstrap cluster

Read [cluster-setup.md](cluster-setup.md) before starting this phase.

Pick a profile and start the cluster:

```bash
# Single-zone:
harness cluster single-up kuma-1

# Or multi-zone:
harness cluster global-two-zones-up kuma-1 kuma-2 kuma-3 zone-1 zone-2
```

If changes modify CRDs, re-run Phase 2 bootstrap for the affected cluster profile and then rerun Phase 3 preflight. Do not use a bare `kubectl apply` during a tracked run.

**Gate**: Phase 3 preflight must pass before test execution starts.

## Phase 3 - preflight

Before spawning the preflight worker, mark the run as guarded preflight:

```bash
harness runner-state \
  --event preflight-started
```

Use the dedicated `preflight-worker`, not a generic subagent. The worker may only run:

```bash
harness preflight

harness capture \
  --label "preflight"
```

The worker must return only the canonical summary documented in `SKILL.md`. It must not inspect harness internals, CI, GitHub state, or raw context files. `harness preflight` prepares the suite once for this run. It materializes baseline manifests and group `## Configure` YAML into the active run's prepared manifests directory, validates every prepared manifest, applies baselines, writes the prepared-suite artifact, and then runs readiness checks.

For multi-zone profiles, `harness preflight` reads each baseline's `clusters` field from the suite frontmatter. Baselines with `clusters: all` are applied to every cluster in the topology (global + all zones) using `harness apply --cluster <name>` for each non-primary cluster. Baselines without a `clusters` field or with `clusters: global` are applied to the primary cluster only. This ensures zone clusters have the workloads (demo apps, collectors, test namespaces) needed for xDS inspection during Phase 4.

Do not start tests until preflight is green and the prepared-suite artifact exists.

**Gate**: preflight exits 0, the prepared-suite artifact exists, and the preflight state snapshot is saved.

## Phase 4 - execute tests

Read [validation.md](validation.md) before applying manifests.
Read [mesh-policies.md](mesh-policies.md) for Mesh\* policy targeting and debug flow.

Select a suite that matches the feature area, or copy [../examples/suite-template.md](../examples/suite-template.md) if none exists.

For directory suites (`SUITE_DIR` is set):

1. Read the suite's `suite.md` for overview, group table, baseline table, and execution contract.
2. **The test groups table is authoritative.** Every group listed in the table must be executed. Do not skip groups because they need a different cluster profile. If a group requires multi-zone but the current profile is single-zone, tear down the current cluster and bring up a multi-zone cluster before that group. If profile switching is impractical, use AskUserQuestion - do not silently skip.
3. Phase 3 already prepared the suite. Do not re-copy baseline manifests and do not re-parse group frontmatter during each group. Use the active run's prepared-suite artifact as the runtime source of truth for prepared manifests plus cluster deltas.
4. Before each group, read the group file from the suite's `groups/` directory using the file path in the group table. The group file stays authoritative for `## Consume`, `## Debug`, validation commands, and expected outcomes. The prepared-suite artifact is authoritative for prepared manifest paths plus `helm_values` and `restart_namespaces`.
5. If the prepared-suite entry for the current group includes `helm_values` or `restart_namespaces`, rerun the active Phase 2 cluster command with repeated `--helm-setting key=value` and `--restart-namespace <ns>` flags derived from the prepared-suite artifact. `harness cluster` compares the desired deploy state against the active run's `current-deploy.json`; if mode, mode args, and Helm values already match, it prints a no-op message and skips redeploy. Otherwise it redeploys, performs rollout restarts in the listed namespaces, and rewrites the deploy state.
6. Apply only the prepared group manifests listed for the current group in the prepared-suite artifact. Baselines were already applied once during Phase 3.
7. Follow the group file's validation commands and expected outcomes exactly. If something doesn't match, report it as a finding - do not silently adjust expectations.
8. After completing a group, the group file content can be dropped from context.

For single-file suites: read the entire suite file, but require the same frontmatter contract as `suite.md`.

**Deviation rule**: if any step requires diverging from the suite definition (different values, skipped step, reordered steps, extra steps, changed expected outcome), use AskUserQuestion for approval before making the change. Record every deviation in the report with what changed, why, and whether user-approved or suite-allowed.

For each test step:

1. Use prepared manifest entries from the active run's prepared-suite artifact whenever the suite already defines the manifest. Only write a new manifest to the active run's `manifests/` directory when the suite does not already provide one or the user explicitly approved a deviation. Never use `/tmp`.
2. Apply through `harness apply`. Prepared manifests reuse the preflight validation/cache; non-prepared manifests are copied, validated, and applied by the command. When a step needs more than one manifest, prefer one batched `harness apply` call over shell loops: repeat `--manifest` in the exact apply order, or pass the manifest directory to apply its immediate `.json/.yaml/.yml` files in lexicographic filename order.
3. Run kubectl verification commands through `harness run ... kubectl ...`, kumactl verification commands through `harness run ... kumactl ...`, Envoy admin captures through `harness envoy capture`, and other cluster-touching commands such as `curl` through `harness record`. Do not run these bare. These wrappers are part of the tracked run, not post-hoc loggers. For raw `kubectl`, `harness run` and `harness record` inject the tracked local `--kubeconfig`, fail closed if the active run has no tracked local kubeconfig yet, and reject kubeconfig or cluster-target override flags. Even after resume or compaction, do not replace them with raw `kubectl --kubeconfig ...`. Prefer `harness envoy route-body` or `harness envoy bootstrap` when you want the inspected Envoy output directly; omit `--file` to capture live first. Save output to `artifacts/`.
4. Run kubectl cleanup commands through `harness run ... kubectl ...`. Prefer `kubectl delete -f` against the prepared manifest files for the current group, one recorded command per manifest or resource kind. Never mix resource kinds in one `kubectl delete` command such as `kubectl delete kind-a name-a kind-b name-b`; kubectl interprets the later kinds as names of the first kind. If the suite doesn't specify the cleanup, confirm with AskUserQuestion (options: run as proposed, skip, stop). Every command that touches the cluster goes through a tracked harness wrapper.
5. Write result into the report. Every artifact path referenced must point to an existing file.

```bash
# Preferred when the whole prepared group should apply in filename order
harness apply \
  --manifest "<group-id>" \
  --step "<step-name>"

# Or keep an explicit partial order in one command
harness apply \
  --manifest "<group-id>/01.yaml" \
  --manifest "<group-id>/02.yaml" \
  --step "<step-name>"

# Record kubectl verification/cleanup commands
harness record \
  --phase "test" \
  --label "<step-label>" \
  -- kubectl <kubectl-args>

# Preferred cleanup for suite-defined resources
harness record \
  --phase "cleanup" \
  --label "cleanup-<group-id>-01" \
  -- kubectl delete -f manifests/prepared/groups/<group-id>/01.yaml

# Record other cluster-touching commands
harness record \
  --phase "test" \
  --label "<step-label>" \
  -- <command>
```

After completing each group (hard gate - do not skip any of these):

1. Finalize the group through the harness-owned report path. This one command captures the post-group pod snapshot and updates both `run-status.json` and `run-report.md`:

```bash
harness report group \
  --group-id "<group-id>" \
  --status <pass|fail|skip> \
  --capture-label "after-<group-id>" \
  [--evidence-label <record-label>] \
  [--evidence <explicit-run-artifact>] \
  [--evidence-label <additional-record-label>] \
  [--evidence <additional-explicit-run-artifact>] \
  [--note "<one-line note>"]
```

Prefer `--evidence-label` whenever the artifact came from `harness record --label ...` or `harness envoy capture --label ...`. It resolves the latest tracked artifact for that label and avoids guessed timestamped filenames.

2. Verify `run-status.json` and `run-report.md` were updated correctly before starting the next group.

On first unexpected failure, go to Phase 5.

**Gate**: all planned tests have pass/fail entries in the report. Every artifact path in the report resolves to an existing file. `run-status.json` reflects final counts.

## Phase 5 - failure handling

Read [troubleshooting.md](troubleshooting.md) for known failure modes.

1. Stop progression.
2. Capture immediate state snapshot.
3. Document expected vs observed.
4. Classify the issue (manifest, environment, product bug).
5. Continue only when classification is explicit.

For manifest validation or apply failures, switch the runner into failure triage before asking the user:

```bash
harness runner-state \
  --event failure-manifest
```

Then ask the canonical manifest-fix gate documented in `SKILL.md` and `validation.md`. `Fix in suite and this run` may edit only the exact approved suite file plus `amendments.md`.

After a `Fix in suite and this run` edit, the prepared manifest in `runs/<run-id>/manifests/prepared/` is stale - it still has the old content. Re-materialize before re-applying:

```bash
# Option A: re-apply reads from the suite source, not the stale prepared copy
harness apply --manifest <path> --step <label>

# Option B: copy the fixed source to the prepared directory manually, then apply
cp <fixed-suite-source-file> runs/<run-id>/manifests/prepared/<matching-path>
```

Do not re-apply the stale prepared copy. Either use `harness apply` which reads from the current suite source, or overwrite the prepared file first.

```bash
harness capture \
  --label "failure-<test-id>"
```

## Phase 6 - closeout

```bash
harness capture \
  --label "postrun"

harness report check

harness closeout
```

**Gate**: all of these are true before marking the run complete:

- Command log is complete (every command executed has an entry)
- Manifest index includes every apply
- Report has pass or fail for all planned tests
- Failures include triage details and artifact paths
- Every artifact path referenced in the report resolves to an existing file in the run directory
- `run-status.json` has correct final counts matching the report
- State captures exist for preflight, each completed group, and postrun
- Report compactness check passes

After all gates pass, tear down the clusters. This is the default - always clean up unless the user explicitly asks to keep clusters running or the suite metadata includes `keep_clusters: true`.

After `harness closeout`, that run is final. Do not reuse it for another cluster bootstrap or execution step. Start a new run with a new run ID instead.

```bash
# Single-zone
harness cluster single-down kuma-1

# Multi-zone (global + 2 zones)
harness cluster global-two-zones-down kuma-1 kuma-2 kuma-3
```

## Performance toggles

| Profile | `HARNESS_BUILD_IMAGES` | `HARNESS_LOAD_IMAGES` | `HARNESS_HELM_CLEAN` | Use when |
| --- | --- | --- | --- | --- |
| default (fastest functional) | 1 | 1 | 0 | Normal test runs |
| strict clean-state | 1 | 1 | 1 | Need full isolation between deploys |
| image-stable fast | 0 | 0 | 0 | Images already match code under test |

Example:

```bash
HARNESS_BUILD_IMAGES=0 HARNESS_LOAD_IMAGES=0 \
  harness cluster single-up kuma-1
```
