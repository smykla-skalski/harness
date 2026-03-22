---
name: run
description: >-
  Execute reproducible suite runs on harness-managed Kubernetes or universal Docker infrastructure
  for Kuma service mesh features. Supports local k3d Kubernetes, remote kubeconfig-backed
  Kubernetes, and universal mode containers for tracked verification runs.
argument-hint: "[suite-path] [--profile single-zone|multi-zone] [--provider local|remote] [--repo /path/to/kuma] [--run-id ID] [--resume RUN_ID]"
allowed-tools: Agent, AskUserQuestion, Bash, Edit, Glob, Read, Write
user-invocable: true
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "harness hook --skill suite:run guard-bash"
    - matcher: "AskUserQuestion"
      hooks:
        - type: command
          command: "harness hook --skill suite:run guard-question"
    - matcher: "Write"
      hooks:
        - type: command
          command: "harness hook --skill suite:run guard-write"
    - matcher: "Edit"
      hooks:
        - type: command
          command: "harness hook --skill suite:run guard-write"
  PostToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "harness hook --skill suite:run verify-bash"
        - type: command
          command: "harness hook --skill suite:run audit"
    - matcher: "AskUserQuestion"
      hooks:
        - type: command
          command: "harness hook --skill suite:run verify-question"
        - type: command
          command: "harness hook --skill suite:run audit"
    - matcher: "Write"
      hooks:
        - type: command
          command: "harness hook --skill suite:run verify-write"
        - type: command
          command: "harness hook --skill suite:run audit"
    - matcher: "Edit"
      hooks:
        - type: command
          command: "harness hook --skill suite:run verify-write"
        - type: command
          command: "harness hook --skill suite:run audit"
    - matcher: "Read"
      hooks:
        - type: command
          command: "harness hook --skill suite:run audit"
    - matcher: "Glob"
      hooks:
        - type: command
          command: "harness hook --skill suite:run audit"
    - matcher: "Agent"
      hooks:
        - type: command
          command: "harness hook --skill suite:run audit"
  PostToolUseFailure:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "harness hook --skill suite:run enrich-failure"
        - type: command
          command: "harness hook --skill suite:run audit"
  SubagentStart:
    - matcher: "preflight-worker"
      hooks:
        - type: command
          command: "harness hook --skill suite:run context-agent"
  SubagentStop:
    - matcher: "preflight-worker"
      hooks:
        - type: command
          command: "harness hook --skill suite:run validate-agent"
  Stop:
    - hooks:
        - type: command
          command: "harness hook --skill suite:run guard-stop"
---

<!-- justify: CF-side-effect Hook-enforced runner guards and AskUserQuestion gates make auto-invocation acceptable here -->

# Kuma suite runner

Execute reproducible suite runs on harness-managed Kubernetes or universal environments for any Kuma feature. Cluster creation, remote attachment, and teardown are managed through `harness setup kuma cluster` in Phase 2 and Phase 8. Before any unplanned cluster operation, use AskUserQuestion with options:

- `Approve operation` - proceed with the cluster change
- `Reject` - skip the operation
- `Stop run` - halt the run

Track every manifest, command, and artifact for full run reproducibility.

Repo-local skill package. Hooks run through `harness hook --skill suite:run <hook-name>`. `SessionStart` hooks install a repo-aware `harness` wrapper on `PATH`. Run `harness --help` for all subcommands.

## Compact recovery

After compaction, trust the `SessionStart(compact)` handoff as authoritative. Continue from the saved run directory and next-action guidance. Do not rerun `harness run start` or `harness run preflight` unless the handoff says to.

After resume, keep using tracked wrappers such as `harness run apply`, `harness run record`, `harness run report`, and `harness run envoy`. Never switch to raw `kubectl --kubeconfig ...`.

If the active run looks stale, mismatched, or partially broken, use `harness run doctor` first and `harness run repair` second. Do not hand-edit `run-status.json`, `suite-run-state.json`, or `current-run.json`.

If a Stop hook summary appears with `preventedContinuation: false`, treat it as advisory. If a run was accidentally `aborted` while `next_planned_group` exists, use `harness run resume --message "Recovered from unexpected stop"` and continue.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| (positional) | - | Suite path or bare name. Bare names (no `/`) are looked up in `${DATA_DIR}/` first. Prompt with AskUserQuestion if omitted |
| `--profile` | `all` | Cluster profile: `single-zone`, `multi-zone`, `single-zone-universal`, `multi-zone-universal`, or `all`. When `all`, runs one full run per required profile. |
| `--provider` | auto | Kubernetes provider: `local` maps to k3d, `remote` maps to kubeconfig-backed remote clusters. Only applies to Kubernetes profiles. |
| `--repo` | auto-detect cwd | Path to Kuma repo checkout |
| `--run-id` | timestamp-based | Override run identifier |
| `--resume` | - | Resume a partial run by its run ID |

## Preprocessed context

- Data directory: !`echo "${XDG_DATA_HOME:-$HOME/.local/share}/harness/suites"`
- Home: !`echo "$HOME"`
- Timestamp: !`date +%Y%m%d-%H%M%S`
- Session ID: ${CLAUDE_SESSION_ID}
- Container runtime backend: !`printf '%s\n' "${HARNESS_CONTAINER_RUNTIME:-bollard}"`
- k3d: !`command -v k3d >/dev/null 2>&1 && echo "installed" || echo "MISSING"`
- kubectl: !`command -v kubectl >/dev/null 2>&1 && echo "installed" || echo "MISSING"`
- helm: !`command -v helm >/dev/null 2>&1 && echo "installed" || echo "MISSING"`

`DATA_DIR` is the suites directory. The timestamp is the default `RUN_ID` suffix. If session ID is empty or literal `${`, use `standalone`. Assume the effective container runtime backend is `bollard` unless `HARNESS_CONTAINER_RUNTIME` overrides it. `k3d` is required only for local Kubernetes provider runs.

<!-- justify: I23 harness on PATH via SessionStart hooks -->
<!-- justify: HK-stdin harness reads hook stdin internally -->
<!-- justify: HK-loop harness has re-entry guards -->
<!-- justify: HK-resolve harness on PATH via SessionStart hooks -->
<!-- justify: P8 shared code blocks are intentional for self-contained loading -->

## Non-negotiable rules

Read [references/agent-contract.md](references/agent-contract.md) in full before starting any run. Top-level summary:

- **No shell variables.** `harness run apply --manifest g02/04.yaml`, not `SD=...`. Exception: the Phase 0/1 `harness run start` setup block.
- **Harness wrappers only.** Use `harness run record` for kubectl, kumactl, curl, and other cluster-touching shell commands; use the dedicated `harness run apply`, `harness run report`, and `harness run envoy` subcommands where they fit. No raw binaries, no `python3 -c`.
- **`--delay` not `sleep`.** `harness run apply --delay 8 --manifest ...` not `sleep 8 && harness run apply`.
- **Relative paths only.** `g13/01.yaml` not `/full/path/...`. No `/tmp`, no `--validate=false`.
- **Hard gate after each group** via `harness run report group`.
- **No autonomous deviations.** AskUserQuestion before any unplanned change.
- **Never create manifests during a run.** All manifests must exist in the suite before the run starts. If a missing manifest is discovered, this is a suite:create defect - use the bug-found gate with classification "suite bug" and do not create the file.
- **Preflight before apply.** Never run `harness run apply` until preflight has completed. Preflight materializes baselines and group YAML into prepared manifests. The verify-bash hook enforces this - `harness run apply` during bootstrap or before preflight completion is denied with KSR014.
- **Stop and triage every failure.** On any unexpected result, failure, or mismatch, stop. Classify as suite bug, product bug, harness bug, or environment issue. Present classification to user via AskUserQuestion before continuing because unclassified failures corrupt the audit trail. See bug-found gate in Phase 4.
- **Commit code fixes before continuing.** After editing product code during a run, commit before re-deploying or re-testing. Use `git add <files> && git commit -m 'fix: description'`. Never iterate on uncommitted edits.
- **Never truncate verification output.** Do not pipe `make test`, `make check`, `cargo test`, `cargo clippy`, or any verification command through `tail -N` or `head -N`. Use full output or grep for specific markers (`FAIL`, `error`, `PASS`). Drawing conclusions from truncated output is unreliable - failures can be hidden above the truncation point.

## Workflow

Read [references/workflow.md](references/workflow.md) for the full procedure. The section below is the entrypoint checklist; load referenced files before acting.

### Phase 0: Environment check

0. Run `harness setup capabilities` and keep the JSON output as `CAPABILITIES` for all later phases.

   - Prefer `readiness.profiles` when present. Only run profiles whose `ready` field is `true`.
   - If the requested profile is not ready, stop before cluster work and surface the matching `blocking_checks`.
   - `readiness.profiles` may contain both `k3d` and `remote` variants for the same Kubernetes profile name. If both are ready and the user did not pass `--provider`, ask which provider to use before Phase 2.
   - Use `readiness.platforms` and `readiness.features` to decide whether the environment is usable now.
   - Keep the normal call zero-arg. Only use `--project-dir` or `--repo-root` as a last-resort debug override when state or cwd resolution is broken.
   - If `readiness` is absent (older harness binary), fall back to the older static logic based on `cluster_topologies`, `platforms`, and `features.*.available`.
   - If the binary is too old or missing, assume all features available.

1. Set `DATA_DIR` from "Preprocessed context". If missing, use AskUserQuestion with options:
   - `Create suite with /suite:create`
   - `Provide a different suite path`

2. Resolve `REPO_ROOT`: `--repo` flag > cwd `go.mod` with `kumahq/kuma` > AskUserQuestion with options:
   - `Provide repo path`
   - `Cancel run`

3. Treat `harness setup capabilities` as authoritative for container readiness. Do not infer universal readiness from `docker info` alone. For Kubernetes local provider runs, `k3d`, `kubectl`, and `helm` must all be installed. For Kubernetes remote provider runs, `kubectl` and `helm` must be installed. For universal runs, the Docker Engine must be reachable; the Docker CLI is only required when `HARNESS_CONTAINER_RUNTIME=docker-cli`.
4. All cluster commands go through tracked wrappers, never raw `kubectl` or `kumactl`.

### Phase 1: Resolve or resume run

Read [references/workflow.md](references/workflow.md) Phase 1 for the full start and resume flow.

Resolve `SUITE_PATH` using the suite resolution order: bare names check `${DATA_DIR}/${name}/suite.md` first, then literal path.

**Fresh run**: resolve `RUN_ID`, `SUITE_PATH`, `SUITE_DIR`, and `PROFILE` now. Keep them for Phase 3, where `harness run start --suite <path> --run-id <id> --profile <profile> --repo-root <repo>` will initialize the run, save `current-run.json`, and complete preflight for the active run after cluster bootstrap is ready.

**Resume** (via `--resume`): if SessionStart already restored the matching active run, keep that run id for Phase 3 and use `harness run resume` once the cluster context is ready. Otherwise plan to reattach with `harness run resume --run-id <id> --run-root <suite-dir>/runs`. Only unfinished runs can resume - start a new `RUN_ID` if the saved run has a final verdict.

After start or resume, use only context-driven `harness` commands. Do not pass `--run-dir`, `--run-root`, `--repo-root`, or `--kubeconfig` again unless debugging. Never switch to raw `kubectl --kubeconfig ...`.

If the saved run cannot be attached cleanly, inspect it with `harness run doctor` before retrying. Use `harness run repair` only for deterministic state fixes such as stale pointers or derived status drift.

**Error cases**: if the suite path does not exist, search `${DATA_DIR}/` with Glob for partial matches. Present matches via AskUserQuestion. If no matches, use AskUserQuestion with options:

- `Provide suite path`
- `Create new suite with /suite:create`

**Gate**: suite path, repo root, run id, and profile are resolved for the selected run path.

### Phase 2: Bootstrap cluster

Read [references/cluster-setup.md](references/cluster-setup.md) before starting this phase.

When `--profile all` (the default), read all group files and collect the set of required profiles. Sort groups by profile tier: standalone, single-zone Kubernetes, single-zone universal, multi-zone Kubernetes, multi-zone universal. Execute all groups for one profile before tearing down and moving to the next. Parallelizable groups within a profile can run concurrently. If suite profile ordering is non-contiguous, warn and propose a reorder.

For each profile, execute a full run (Phase 1-8) with only the groups matching that profile. When transitioning between profiles, overlap teardown and setup: run the old cluster's teardown with `run_in_background: true` while starting the next cluster in foreground. Artifacts are already captured so teardown is safe to background.

Present the execution plan via AskUserQuestion with options:

- `Run all profiles` - execute every required profile sequentially
- `Select profiles` - user picks which profiles to run
- `Single profile only` - run only the first required profile

Select the cluster topology based on the profile being executed. For Kubernetes profiles, also select the provider:

```bash
# Kubernetes single-zone, local k3d (--profile single-zone --provider local):
harness setup kuma cluster single-up kuma-1

# Kubernetes multi-zone, local k3d (--profile multi-zone --provider local):
harness setup kuma cluster global-two-zones-up kuma-1 kuma-2 kuma-3 zone-1 zone-2

# Kubernetes single-zone, remote kubeconfigs (--profile single-zone --provider remote):
harness setup kuma cluster \
  --provider remote \
  --remote name=kuma-1,kubeconfig=/path/to/kuma-1.yaml[,context=kuma-1] \
  --push-prefix ghcr.io/acme/kuma \
  --push-tag branch-dev \
  single-up kuma-1

# Kubernetes multi-zone, remote kubeconfigs (--profile multi-zone --provider remote):
harness setup kuma cluster \
  --provider remote \
  --remote name=kuma-1,kubeconfig=/path/to/kuma-1.yaml[,context=global] \
  --remote name=kuma-2,kubeconfig=/path/to/kuma-2.yaml[,context=zone-1] \
  --remote name=kuma-3,kubeconfig=/path/to/kuma-3.yaml[,context=zone-2] \
  --push-prefix ghcr.io/acme/kuma \
  --push-tag branch-dev \
  global-two-zones-up kuma-1 kuma-2 kuma-3 zone-1 zone-2

# Universal single-zone (--profile single-zone-universal):
harness setup kuma cluster --platform universal single-up test-cp

# Universal multi-zone (--profile multi-zone-universal):
harness setup kuma cluster --platform universal global-zone-up global-cp zone-cp zone-1
```

Read [references/universal-setup.md](references/universal-setup.md) for the universal mode lifecycle, including Docker container management, `harness run kuma token`, and `harness run kuma service` for service containers.

If changes modify CRDs, re-run Phase 2 bootstrap and then re-run `harness run preflight` plus `harness run capture --label "preflight"` for the active run before continuing. If the suite references gateways (MeshGateway, GatewayClass, HTTPRoute, Gateway), install CRDs with `harness setup gateway` and verify with `harness setup gateway --check-only`. In remote mode, pass the tracked generated kubeconfig path to `harness setup gateway --kubeconfig ...` so teardown can uninstall what harness installed later.

**Gate**: cluster bootstrap is ready for `harness run start` or `harness run resume`.

### Phase 3: Start or resume tracked run

**Fresh run**: call `harness run start --suite <path> --run-id <id> --profile <profile> --repo-root <repo>`, then save the preflight snapshot with `harness run capture --label "preflight"`.

**Resume**: if SessionStart already restored the matching active run, use `harness run resume` directly. Otherwise reattach with `harness run resume --run-id <id> --run-root <suite-dir>/runs`. If the cluster topology was rebuilt or CRDs changed since the saved run last preflighted, re-run `harness run preflight` and `harness run capture --label "preflight"` before execution resumes.

If start, resume, or refresh preflight fails, use AskUserQuestion with options:

- `Retry preflight`
- `Fix the issue manually`
- `Stop the run`

Before choosing manual fixes for suspected run-state drift, check `harness run doctor`. If the findings are deterministic, run `harness run repair` and then retry the failing harness command.

Do not start tests until the active run is attached, the prepared-suite artifact exists, and the preflight snapshot is saved.

### Phase 4: Execute tests

Read [references/workflow.md](references/workflow.md) Phase 4 section in full before starting tests - it has the complete step-by-step procedure with code blocks and per-group gates.

Read [references/validation.md](references/validation.md) for the pre-apply checklist and safe apply flow before applying manifests.
Read [references/mesh-policies.md](references/mesh-policies.md) for policy create rules when the suite tests any `Mesh*` policy.
Read [examples/suite-template.md](examples/suite-template.md) when creating a new suite. Read [examples/example-motb-core-suite.md](examples/example-motb-core-suite.md) for a worked example of the expected format.

Key principles (workflow.md has the details):

1. **The test groups table is authoritative.** Execute every listed group. Do not mark a group as skip without first calling AskUserQuestion with options:
   - `Switch cluster profile`
   - `Fix prerequisites`
   - `Skip group`
   - `Stop run`
2. **Prepared-suite artifact** from Phase 3 is the runtime source of truth for manifest paths and cluster deltas. Do not re-parse group frontmatter.
3. **Group files remain authoritative** for `## Consume`, `## Debug`, and expected outcomes. Read before executing, drop after completing.
4. **Apply through `harness run apply`**, verify/cleanup through `harness run record`. During Phase 4 execution, every `harness run record` command must include `--gid <group-id>` so the command log and audit trail stay group-scoped. Use `harness run report group --group-id <id> ...` to finalize a group and `harness run envoy` for Envoy admin captures. Batch manifests with repeated `--manifest` or pass the group directory. Never mix resource kinds in one `kubectl delete` command. If the suite does not specify cleanup, use AskUserQuestion with options:
   - `Run proposed cleanup`
   - `Skip cleanup`
   - `Stop run`
5. **Hard gate after each group** via `harness run report group --group-id <id> --status <pass|fail|skip> --capture-label "after-<id>"`. Use `--evidence-label` for tracked artifacts.

### Bug-found gate

On any unexpected result or failure, stop and triage before continuing. This gate is mandatory because unclassified failures corrupt the run's audit trail.

**Step 1 - Classify** as: **suite bug** (wrong manifest/expectations), **product bug** (Kuma vs spec), **harness bug** (infra misconfiguration), or **environment issue** (timing/resources).

**Step 2 - Report.** `harness run runner-state --event failure-manifest`, then AskUserQuestion with `suite:run/bug-found: [classification] - [description]`. Options:

- `Fix now` - pause run, fix based on classification, resume
- `Continue and fix later` - record with classification, mark group failed, continue
- `Stop run`

Do not continue past a failure without presenting it to the user first. On first failure, go to Phase 5.

**Gate**: all planned tests have pass/fail entries in the report. Every artifact path in the report resolves to an existing file. `run-status.json` reflects final counts.

### Phase 5: Failure handling

Read [references/troubleshooting.md](references/troubleshooting.md) for known failure modes.

1. Stop progression, capture state with `harness run capture`, classify as manifest/environment/product bug.
2. For manifest failures, enter triage (`harness run runner-state --event failure-manifest`), then AskUserQuestion with first line `suite:run/manifest-fix: how should this failure be handled?`. Include suite target path and error message. Options:
   - `Fix for this run only`
   - `Fix in suite and this run`
   - `Skip this step`
   - `Stop run`
3. `Fix in suite and this run` edits only the exact suite file plus `amendments.md`. After editing, use `harness run apply` which reads from suite source, not the stale prepared copy.
4. At most one re-run attempt per failure. See [references/workflow.md](references/workflow.md) and [references/validation.md](references/validation.md) for the full failure matrix.

### Phase 6: Closeout

```bash
harness run capture \
  --label "postrun"

harness run report check

harness run finish
```

**Gate**: command log complete, manifest index complete, all tests have pass/fail, every artifact path resolves to an existing file, `run-status.json` has correct final counts, state captures exist for preflight + each group + postrun, compactness check passes.

After all gates pass, proceed to Phase 7 (retrospective) before tearing down clusters.

After `harness run finish`, that run is final. Do not reuse it for another cluster bootstrap or execution step. Start a new run with a new `RUN_ID` instead.

### Phase 7: Retrospective

After closeout, spawn parallel subagents (compliance auditor, manifest reviewer, coverage analyzer, findings summarizer, process advisor) to analyze the completed run. Present the assembled retrospective to the user via AskUserQuestion with options:

- `Save as-is` - save to `{run_dir}/retrospective.md`
- `Request changes` - user provides feedback, regenerate specific sections. Loop until user confirms or 3 iterations are reached, then save current draft
- `Discard` - do not save

Read [references/workflow.md](references/workflow.md) Phase 7 section for the full agent specifications and assembly procedure.

**Gate**: retrospective saved or explicitly discarded by user before proceeding to cluster teardown.

### Phase 8: Cluster teardown

Tear down the clusters created in Phase 2. Use the matching `harness setup kuma cluster` teardown command for the active profile. Read [references/workflow.md](references/workflow.md) Phase 8 section for the per-profile teardown commands.

## Performance toggles

Override env vars on `harness setup kuma cluster` calls: `HARNESS_BUILD_IMAGES=0 HARNESS_LOAD_IMAGES=0` skips rebuilds, `HARNESS_HELM_CLEAN=1` adds full isolation, `HARNESS_DOCKER_PRUNE=0` skips image cleanup (not recommended). Remote provider runs do not support `--no-load`.

## Report compactness thresholds

`harness run report check` enforces: max 220 lines, max 4 code blocks. Store raw output in `artifacts/` and reference file paths.

## Hook messages

Hook codes:

| Code | Hook | Meaning |
| --- | --- | --- |
| KSR005 | guard-bash | Cluster binaries and Envoy admin calls must go through harness wrappers |
| KSR006 | verify-bash | Expected artifact missing after command |
| KSR007 | guard-stop | Run closeout incomplete: missing state capture or pending verdict |
| KSR008 | guard-write | Write path is outside the tracked run surface |
| KSR011 | audit | Suite-runner runs must stay user-story-first and tracked |
| KSR012 | enrich-failure | Current run verdict status |
| KSR013 | runner state hooks | Runner state is missing or invalid |
| KSR014 | guard-question/guard-bash/context-agent | Required runner phase or approval is missing |
| KSR015 | validate-agent | Preflight worker reply or saved artifacts are invalid |

## Bundled resources

**References** (read when entering the relevant phase):

- [references/agent-contract.md](references/agent-contract.md) - agent rules, failure policy, artifacts
- [references/workflow.md](references/workflow.md) - phase details with verification gates
- [references/cluster-setup.md](references/cluster-setup.md) - local k3d and remote Kubernetes profiles, kubeconfig handling, deploy commands
- [references/mesh-policies.md](references/mesh-policies.md) - Mesh\* policy create, targeting, debug flow
- [references/validation.md](references/validation.md) - pre-apply checklist, safe apply flow
- [references/troubleshooting.md](references/troubleshooting.md) - known failure modes and fixes

**harness commands** (context-aware after `run start` or `run resume`): `setup capabilities`, `setup kuma cluster`, `setup gateway`, `run start`, `run finish`, `run resume`, `run doctor`, `run repair`, `run init`, `run preflight`, `run runner-state`, `run apply`, `run validate`, `run capture`, `run record`, `run report group`, `run envoy {capture,route-body,bootstrap}`, `run diff`, `run kuma cli {find,build}`, and `hook`. All commands accept `--delay <seconds>` to wait before executing. Run `harness --help` for details.

**Templates** (in `assets/`): `run-metadata.template.json`, `run-status.template.json`, `command-log.template.md`, `manifest-index.template.md`, `run-report.template.md`

**Examples**: [examples/suite-template.md](examples/suite-template.md), [examples/example-motb-core-suite.md](examples/example-motb-core-suite.md)

## Example invocations

<example description="Run a suite by bare name (auto-detects repo root)">
```bash
/suite:run meshretry-basic
```
</example>

<example description="Run with explicit repo and multi-zone profile">
```bash
/suite:run my-suite.md --profile multi-zone --repo ~/Projects/kuma
```
</example>

<example description="Run a Kubernetes suite against remote clusters">
```bash
/suite:run my-suite.md --profile multi-zone --provider remote --repo ~/Projects/kuma
```
</example>

<example description="Resume a partial run">
```bash
/suite:run --resume 20260304-180131-manual
```
</example>
