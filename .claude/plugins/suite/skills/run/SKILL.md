---
name: run
description: >-
  Execute reproducible suite runs on local k3d or universal Docker infrastructure for Kuma
  service mesh features. Use when running manual verification, testing policy changes on real
  clusters or universal mode containers, validating xDS config generation, or doing tracked
  verification runs for any Kuma feature area.
argument-hint: "[suite-path] [--profile single-zone|multi-zone] [--repo /path/to/kuma] [--run-id ID] [--resume RUN_ID]"
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

Execute reproducible suite runs on local k3d clusters for any Kuma feature. Cluster creation and teardown are managed through `harness cluster` in Phase 2 and Phase 6. Confirm with the user before any unplanned cluster operations. Track every manifest, command, and artifact for full run reproducibility.

This is a repo-local skill package. All hooks run through `harness hook --skill suite:run <hook-name>`. Project `SessionStart` hooks install a repo-aware `harness` wrapper on `PATH`, so the skill uses the bare command everywhere. Run `harness --help` for the full list of subcommands.

## Compact recovery

If Claude Code resumes this skill after compaction, trust the injected `SessionStart(compact)` handoff as the authoritative summary of the current run. That hook also restores the executable harness state for the new session. Continue from the saved run directory, prepared-suite artifact, and next-action guidance in that handoff. Do not rerun `harness init` or `harness preflight` unless the handoff explicitly says the saved state diverged and tells you to reload specific files first.

After resume or compaction, do not treat a remembered local kubeconfig as permission to run raw `kubectl` or `kubectl --kubeconfig ...`. The restored run context exists so cluster commands still go through tracked wrappers: `harness run --phase <phase> --label <label> kubectl <args>` or `harness record --phase <phase> --label <label> -- kubectl <args>`.

Claude Code may show a Stop hook summary after a normal assistant turn. If `preventedContinuation` is false, treat it as advisory runtime metadata, not proof that the user tried to exit. Never blame the user for it.

If a run was accidentally marked `aborted` while `next_planned_group` still exists, do not edit `run-status.json` or `run-report.md` manually. Use `harness runner-state --run-dir <run-dir> --event resume-run --message "Recovered from unexpected stop"` and continue from the saved next group.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| (positional) | - | Suite path or bare name. Bare names (no `/`) are looked up in `${DATA_DIR}/` first. Prompt with AskUserQuestion if omitted |
| `--profile` | `single-zone` | Cluster profile: `single-zone`, `multi-zone` |
| `--repo` | auto-detect cwd | Path to Kuma repo checkout |
| `--run-id` | timestamp-based | Override run identifier |
| `--resume` | - | Resume a partial run by its run ID |

## Preprocessed context

- Data directory: !`echo "${XDG_DATA_HOME:-$HOME/.local/share}/kuma/suites"`
- Home: !`echo "$HOME"`
- Timestamp: !`date +%Y%m%d-%H%M%S`
- Session ID: ${CLAUDE_SESSION_ID}
- Docker: !`docker info >/dev/null 2>&1 && echo "running" || echo "not running"`
- k3d: !`command -v k3d >/dev/null 2>&1 && echo "installed" || echo "MISSING"`
- kubectl: !`command -v kubectl >/dev/null 2>&1 && echo "installed" || echo "MISSING"`
- helm: !`command -v helm >/dev/null 2>&1 && echo "installed" || echo "MISSING"`

Use these pre-resolved values throughout the run. `DATA_DIR` is the suites directory above. `HOME` is the home path above. The timestamp above becomes the default `RUN_ID` suffix. The session ID tracks which Claude Code session produced this run. If the session ID is empty or contains literal `${`, use `standalone` instead. If Docker shows "not running" or any tool shows "MISSING", stop immediately and report the problem.

Read [references/validation.md](references/validation.md) for the pre-apply checklist, safe apply flow, and manifest error handling procedure.

<!-- justify: I23 harness is installed on PATH by project SessionStart hooks, not bundled as a script -->
<!-- justify: HK-stdin harness reads hook stdin internally via its Python hook dispatcher -->
<!-- justify: HK-loop harness has internal re-entry guards in its hook dispatcher -->
<!-- justify: HK-resolve harness is installed on PATH by SessionStart hooks at runtime, not bundled as a script -->
<!-- justify: P8 shared code blocks between SKILL.md and workflow.md are intentional - each file must be self-contained when loaded independently -->

## Non-negotiable rules

Read [references/agent-contract.md](references/agent-contract.md) in full before starting any run. It has 15 rules with expanded rationale. The top-level summary:

- Every cluster command through the tracked harness wrappers (`harness run ... kubectl ...` for kubectl, `harness run ... kumactl ...` for kumactl, `harness record` for `curl` and other non-wrapped commands). When the tracked command is raw `kubectl`, `harness run` and `harness record` inject the tracked local `--kubeconfig` and fail closed if no tracked local kubeconfig is available. Do not pass kubeconfig or cluster-target override flags through tracked `kubectl` commands, and never fall back to raw `kubectl --kubeconfig ...` even after resume or compaction. Bare cluster binaries bypass audit and hooks will block them. Exceptions: commands wrapped by `apply`, `capture`, `preflight`, `cluster`, `gateway`, `validate`.
- Every manifest through `harness apply`, using verbatim inline YAML. Never `/tmp`, never `--validate=false`.
- After each group: finalize through `harness report group --capture-label "after-<group-id>" ...`, then verify. Prefer `--evidence-label <label>` for artifacts created through `harness record --label <label>` or `harness envoy capture --label <label>` so the runner never guesses timestamped filenames. Hard gate.
- No autonomous deviations. Use AskUserQuestion (options: approve deviation, reject, stop run) before any change not defined in the suite. Record every deviation.
- Stop and triage on first unexpected failure. Every artifact path in the report must resolve to an existing file.

## Workflow

Read [references/workflow.md](references/workflow.md) for the authoritative detailed procedure. The section below is the entrypoint checklist; load the referenced files before acting when a phase needs deeper operational detail.

### Phase 0: Environment check

1. Set `DATA_DIR` to the pre-resolved suites directory from "Preprocessed context". Do not create it from `suite:run`; if it is missing, stop and use AskUserQuestion with options `Author suite with /suite:new` and `Provide a different suite path` (no recommendation markers or promotional labels):

```bash
DATA_DIR="<suites directory from Preprocessed context>"
```

2. Resolve `REPO_ROOT`: use `--repo` if provided, otherwise check whether cwd has `go.mod` containing `kumahq/kuma`. If neither works, use AskUserQuestion (options: provide repo path, cancel run) - the user may have a non-standard checkout location.
3. Docker status and tool availability are pre-resolved in "Preprocessed context". If Docker is "not running", tell the user to start Docker Desktop and wait. If any tool is "MISSING", list which tools are missing and suggest `make install` (installs k3d, kubectl, helm via mise).
4. No raw `kubectl` or `kumactl` path management is needed in the shell flow. Use `harness run ... kubectl ...` for kubectl checks and `harness run ... kumactl ...` for local version and inspect commands so they stay audited. Never replace that with raw `kubectl --kubeconfig ...`, even if the resumed handoff mentions a local kubeconfig path.

### Phase 1: Initialize or resume run

Resolve `SUITE_PATH` first using the suite resolution order below.

If `--resume` was passed and SessionStart already restored the matching active run, do not call `harness init` or the explicit reattach command below. Phase 1 is already complete for that run. Read `${RUN_DIR}/run-status.json` from the restored run directory and continue from `next_planned_group`.

Only unfinished runs can resume. If the saved run already reached a final `pass` or `fail` verdict, start a new `RUN_ID` instead of reattaching it.

For a fresh run, initialize it:

```bash
RUN_ID="${RUN_ID:-<timestamp from Preprocessed context>-manual}"  # override with --run-id flag
PROFILE="<resolved --profile value>"
SUITE_PATH="<resolved suite path>"
SUITE_DIR="$(dirname "${SUITE_PATH}")"
harness init \
  --suite "${SUITE_PATH}" \
  --run-id "${RUN_ID}" \
  --profile "${PROFILE}" \
  --repo-root "${REPO_ROOT}"
```

If `--resume` was passed, do not call `harness init` for that existing run. Reattach the saved run context first:

```bash
RUN_ID="${RESUME_ID}"
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

Use the explicit reattach command only when no restored active run already matches `${RUN_ID}`.

Then read `${RUN_DIR}/run-status.json` for `last_completed_group` and skip to the next planned group.

Fresh `harness init` writes the session-scoped `current-run.json` shim with the resolved run paths, suite path, and profile, and also saves the active run in project state so fresh sessions can restore it automatically. The explicit `harness run --run-id ... --run-root ...` resume command rehydrates that same active run context from the existing run directory. After this phase, use only context-driven `harness` commands. Do not pass `--run-dir`, `--run-root`, `--repo-root`, or `--kubeconfig` again unless debugging a broken run context. In particular, do not switch to raw `kubectl --kubeconfig ...`; keep using `harness run --phase <phase> --label <label> kubectl <args>` or `harness record --phase <phase> --label <label> -- kubectl <args>`.

Record the local `kumactl` version through the harness audit path before touching the cluster. On a resume path, the command above already did that and restored the active run context.

```bash
harness run --repo-root "${REPO_ROOT}" --phase setup --label kumactl-version \
  kumactl version
```

The local binary check may print a server connection warning on stderr before the control plane exists. That warning is expected here; use the `Client:` line to confirm the built binary matches the repo HEAD.

Suite resolution for bare names (no `/`):

1. Directory suite: check `${DATA_DIR}/${name}/suite.md`
2. Literal path

**Error cases**: if the suite path does not exist, use Glob to search `${DATA_DIR}/` for partial matches (e.g., `*retry*`). Present matches via AskUserQuestion. If no matches exist, use AskUserQuestion with options `Provide suite path` and `Author new suite with /suite:new`. Do not add recommendation markers, promotional labels, or structured option descriptions.

Fill `run-metadata.json` with profile, feature scope, and the recorded `kumactl` version before touching the cluster.

**Gate**: `run-metadata.json` exists with profile, feature scope, and environment filled in.

### Phase 2: Bootstrap cluster

Read [references/cluster-setup.md](references/cluster-setup.md) before starting this phase.

Select the cluster topology based on the `--profile` flag (default: `single-zone`):

```bash
# Kubernetes single-zone (--profile single-zone):
harness cluster single-up kuma-1

# Kubernetes multi-zone (--profile multi-zone):
harness cluster global-two-zones-up kuma-1 kuma-2 kuma-3 zone-1 zone-2

# Universal single-zone (--profile single-zone-universal):
harness cluster --platform universal single-up test-cp

# Universal multi-zone (--profile multi-zone-universal):
harness cluster --platform universal global-zone-up global-cp zone-cp zone-1
```

Universal mode uses Docker containers instead of k3d. Policies use REST API format (type/name/mesh). See [references/universal-setup.md](references/universal-setup.md) for the full lifecycle.

For universal mode service containers use `harness token` and `harness service`:
```bash
harness token dataplane --name demo-app --mesh default
harness service up demo-app --image kuma-dp:latest --port 5050
harness service down demo-app
```

If changes modify CRDs, re-run Phase 2 bootstrap for the affected cluster profile and then rerun Phase 3 preflight. Do not use a bare `kubectl apply` during a tracked run.

If the suite references builtin gateways (MeshGateway, GatewayClass, HTTPRoute, Gateway), install Gateway API CRDs. Check the suite metadata `required dependencies` and group files for these resource kinds.

```bash
harness gateway
```

**Gate**: Phase 3 preflight must pass before test execution starts. If Gateway API CRDs were required, verify with:

```bash
harness gateway --check-only
```

### Phase 3: Preflight (spawned agent)

Before spawning the preflight worker, mark the run as being in the guarded preflight phase:

```bash
harness runner-state \
  --event preflight-started
```

Spawn the dedicated `preflight-worker`. It must be the checked-in worker with tools limited to `Read` and `Bash`. Do not use a generic subagent here.

The worker prompt must include:

1. The absolute path to [references/cluster-setup.md](references/cluster-setup.md) with instruction to read it
2. The absolute path to [references/validation.md](references/validation.md) with instruction to read it
3. The exact two commands to run: `harness preflight` and then `harness capture --label "preflight"`
4. An explicit instruction not to inspect harness internals, suite internals, CI, or GitHub state
5. The exact reply shape:

```text
suite:run/preflight: pass
Prepared suite: <absolute path>
State capture: <absolute path>
Warnings: none
```

On failure, the worker must instead return:

```text
suite:run/preflight: fail
Prepared suite: missing
State capture: missing
Blocker: <brief reason>
```

If the worker returns `fail`, report the blocker and use AskUserQuestion (options: retry preflight, fix the issue manually, stop the run) before proceeding. Do not start tests until the worker returns `pass`.

### Phase 4: Execute tests

Read [references/workflow.md](references/workflow.md) Phase 4 section in full before starting tests - it has the complete step-by-step procedure with code blocks and per-group gates.

Read [references/validation.md](references/validation.md) for the pre-apply checklist and safe apply flow before applying manifests.
Read [references/mesh-policies.md](references/mesh-policies.md) for policy authoring rules when the suite tests any `Mesh*` policy.
Read [examples/suite-template.md](examples/suite-template.md) when creating a new suite. Read [examples/example-motb-core-suite.md](examples/example-motb-core-suite.md) for a worked example of the expected format.

Key principles (workflow.md has the details):

1. **The test groups table is authoritative.** Execute every listed group. If a group requires a different cluster profile, tear down and rebuild - do not silently skip. If impractical, use AskUserQuestion (options: switch profile, skip group, stop run).
2. **Use the prepared-suite artifact** from Phase 3 as the runtime source of truth for manifest paths and cluster deltas (`helm_values`, `restart_namespaces`). Do not re-parse group frontmatter or re-copy baselines.
3. **Group files remain authoritative** for `## Consume`, `## Debug`, expected outcomes, and artifact expectations. Read each group file before executing it, drop it from context after completing it.
4. **Apply through `harness apply`**, verify and clean up through `harness record`. When a step needs more than one manifest, prefer one batched `harness apply` call over shell loops: either repeat `--manifest` in the exact apply order or pass the group directory (for example `<group-id>`) to apply that directory's immediate `.json/.yaml/.yml` files in lexicographic filename order. Use `harness envoy` for Envoy admin work. `harness envoy capture` can save a full artifact, and `harness envoy capture --type-contains ...`, `harness envoy capture --grep ...`, `harness envoy route-body`, and `harness envoy bootstrap` can capture and inspect in one command. Prefer those one-command inspect forms when you want the filtered Envoy output directly instead of reading a saved file afterward. For cleanup, prefer `kubectl delete -f` against the prepared manifest files for that group, one recorded command per manifest or resource kind. Never mix resource kinds in one `kubectl delete` command such as `kubectl delete kind-a name-a kind-b name-b`; kubectl treats the later kinds as names of the first kind.
5. **Hard gate after each group**: run `harness report group --group-id <group-id> --status <pass|fail|skip> --capture-label "after-<group-id>" [--evidence-label <record-label>] [--evidence <explicit-run-artifact>] [...]`, verify the updated `run-status.json` and `run-report.md`, then move on. Use `--evidence-label` whenever the artifact came from `harness record --label ...` or `harness envoy capture --label ...`.

```bash
# Preferred when the whole prepared group should apply in filename order
harness apply \
  --manifest <group-id> \
  --step <step-name>

# Or keep an explicit partial order in one command
harness apply \
  --manifest <group-id>/01.yaml \
  --manifest <group-id>/02.yaml \
  --step <step-name>
```

On first unexpected failure, go to Phase 5.

**Gate**: all planned tests have pass/fail entries in the report. Every artifact path in the report resolves to an existing file. `run-status.json` reflects final counts.

### Phase 5: Failure handling

Read [references/troubleshooting.md](references/troubleshooting.md) for known failure modes.

1. Stop progression.
2. Capture an immediate state snapshot with `harness capture`.
3. Classify the issue as manifest, environment, or product bug.
4. For manifest validation or apply failures, move the runner into failure triage before asking the canonical repair gate:

```bash
harness runner-state \
  --event failure-manifest
```

Then use AskUserQuestion with this exact first line:

```text
suite:run/manifest-fix: how should this failure be handled?
```

The question body must also include:

- `Suite target: <relative path within the suite>`
- the validation or apply error message

The options must be exactly:

- `Fix for this run only`
- `Fix in suite and this run`
- `Skip this step`
- `Stop run`

`Fix in suite and this run` unlocks edits only for that exact suite file plus `amendments.md`. Harness code, plugin code, `.claude/skills`, `.claude/agents`, and unrelated repo files are never editable from `suite:run`.
5. Allow at most one re-run attempt per failure. After the re-run, either resume at the next group or stop the run based on the user's choice.

The detailed failure matrix and user-choice branches live in [references/workflow.md](references/workflow.md), [references/validation.md](references/validation.md), and [references/troubleshooting.md](references/troubleshooting.md).

### Phase 6: Closeout

```bash
harness capture \
  --label "postrun"

harness report check

harness closeout
```

**Gate**: command log complete (every command has an entry), manifest index complete, all tests have pass/fail, every artifact path in the report resolves to an existing file, `run-status.json` has correct final counts, state captures exist for preflight + each completed group + postrun, compactness check passes.

After all gates pass, tear down the clusters. This is the default - always clean up unless the user explicitly asks to keep clusters running or the suite metadata includes `keep_clusters: true`.

After `harness closeout`, that run is final. Do not reuse it for another cluster bootstrap or execution step. Start a new run with a new `RUN_ID` instead.

```bash
# Kubernetes single-zone
harness cluster single-down kuma-1

# Kubernetes multi-zone (global + 2 zones)
harness cluster global-two-zones-down kuma-1 kuma-2 kuma-3

# Universal single-zone
harness cluster --platform universal single-down test-cp

# Universal multi-zone
harness cluster --platform universal global-zone-down global-cp zone-cp
```

## Performance toggles

Override env vars on `harness cluster` calls: `HARNESS_BUILD_IMAGES=0 HARNESS_LOAD_IMAGES=0` skips rebuilds, `HARNESS_HELM_CLEAN=1` adds full isolation, `HARNESS_DOCKER_PRUNE=0` skips image cleanup (not recommended).

## Report compactness thresholds

`harness report check` enforces: max 220 lines, max 4 code blocks. Store raw output in `artifacts/` and reference file paths.

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
- [references/cluster-setup.md](references/cluster-setup.md) - k3d profiles, kubeconfig, deploy commands
- [references/mesh-policies.md](references/mesh-policies.md) - Mesh\* policy authoring, targeting, debug flow
- [references/validation.md](references/validation.md) - pre-apply checklist, safe apply flow
- [references/troubleshooting.md](references/troubleshooting.md) - known failure modes and fixes

**harness commands** (run via Bash, context-aware after `init`):

- `init` - create run directory and current-run shim
- `preflight` - prepare suite once, verify cluster readiness
- `cluster` - start/stop/deploy k3d clusters by profile
- `validate` - server-side dry-run before apply
- `apply` - apply with validation, copy, and logging
- `capture` - snapshot cluster state
- `record` - log ad-hoc command (captures stdout to file, do not pipe output)
- `envoy` - capture or inspect Envoy artifacts such as config dumps and bootstrap payloads
- `diff` - key-by-key JSON diff (exit 0=identical, 1=different, 2=error)
- `gateway` - install Gateway API CRDs (version from go.mod)
- `kumactl find` / `kumactl build` - locate or build local kumactl
- `report check` - verify report size limits
- `hook` - runtime guardrails (guard-bash, guard-question, guard-write, verify-bash, verify-question, verify-write, audit, enrich-failure, context-agent, validate-agent, guard-stop)

**Templates** (in `assets/`, used by `harness init`):

- `run-metadata.template.json`, `run-status.template.json`, `command-log.template.md`, `manifest-index.template.md`, `run-report.template.md`

**Examples** (read when authoring or understanding suite format):

- [examples/suite-template.md](examples/suite-template.md) - generic test suite template
- [examples/example-motb-core-suite.md](examples/example-motb-core-suite.md) - worked MOTB suite example

## Example invocations

<example description="Run a suite from persistent storage using an explicit repo path">
```bash
/suite:run meshretry-basic --repo ~/Projects/kuma
```
</example>

<example description="Run a suite from inside the kuma repo (auto-detects repo root)">
```bash
/suite:run meshretry-basic
```
</example>

<example description="Run a suite by explicit file path">
```bash
/suite:run /path/to/my-suite.md --repo ~/Projects/kuma
```
</example>

<example description="Run a suite with multi-zone cluster profile">
```bash
/suite:run my-suite.md --profile multi-zone
```
</example>

<example description="Resume a partial run by its run ID">
```bash
/suite:run --resume 20260304-180131-manual --repo ~/Projects/kuma
```
</example>

<example description="Run a suite with a custom run identifier">
```bash
/suite:run my-suite.md --run-id motb-validation-v2
```
</example>
