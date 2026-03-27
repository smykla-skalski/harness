---
name: create
description: Generate test suites for suite:run by reading Kuma source code. Produces ready-to-run suites with manifests, validation steps, and expected outcomes for both Kubernetes and universal mode deployments. Use when creating a new test suite for a Kuma feature, converting a PR into a test plan, building regression tests from source code, or when the user asks for test coverage, a test plan, or wants to write tests for any Kuma policy or feature.
argument-hint: <feature-name> [--repo /path/to/kuma] [--mode generate|wizard] [--from-pr PR_URL] [--from-branch BRANCH] [--suite-name NAME] [--yes|-y]
allowed-tools: Agent, AskUserQuestion, Bash, Edit, Glob, Grep, Read, Write
disable-model-invocation: true
user-invocable: true
hooks:
  PostToolUse:
  - hooks:
    - command: harness hook --agent claude suite:create verify-question
      type: command
    - command: harness hook --agent claude suite:create audit
      type: command
    matcher: AskUserQuestion
  - hooks:
    - command: harness hook --agent claude suite:create audit
      type: command
    matcher: Bash
  - hooks:
    - command: harness hook --agent claude suite:create verify-write
      type: command
    - command: harness hook --agent claude suite:create audit
      type: command
    matcher: Edit
  - hooks:
    - command: harness hook --agent claude suite:create verify-write
      type: command
    - command: harness hook --agent claude suite:create audit
      type: command
    matcher: Write
  PostToolUseFailure:
  - hooks:
    - command: harness hook --agent claude suite:create audit
      type: command
    matcher: Bash
  PreToolUse:
  - hooks:
    - command: harness hook --agent claude suite:create guard-question
      type: command
    matcher: AskUserQuestion
  - hooks:
    - command: harness hook --agent claude suite:create guard-bash
      type: command
    matcher: Bash
  - hooks:
    - command: harness hook --agent claude suite:create guard-write
      type: command
    matcher: Edit
  - hooks:
    - command: harness hook --agent claude suite:create guard-write
      type: command
    matcher: Write
  Stop:
  - hooks:
    - command: harness hook --agent claude suite:create guard-stop
      type: command
---

<!-- justify: I23 harness is installed on PATH by project SessionStart hooks, not bundled as a script -->
<!-- justify: HK-stdin harness reads hook stdin internally via its Python hook dispatcher -->
<!-- justify: HK-loop harness has internal re-entry guards in its hook dispatcher -->
<!-- justify: HK-resolve harness is installed on PATH by SessionStart hooks at runtime, not bundled as a script -->

# Kuma suite create

Generate test suites for `suite:run` by reading Kuma source code and emitting ready-to-run manifests, commands, and variant coverage.

Avoid using for running suites (use `/suite:run`), editing existing suites, or generating non-Kuma test plans, because create and execution need different guardrails.

All hooks route through `harness hook --agent claude suite:create <hook-name>`, using the bare `harness` command installed by project `SessionStart` hooks.

## Compact recovery

If Claude Code resumes this skill after compaction, trust the injected `SessionStart(compact)` handoff as the authoritative summary of the saved create workspace, approval phase, and cached worker outputs. Resume the exact review gate or writer/edit round described there. Do not rerun discovery or reinitialize approval unless the handoff explicitly says the saved state diverged and names the files that must be reloaded first.

## Arguments

Parse from `$ARGUMENTS`:

| Argument | Default | Purpose |
| --- | --- | --- |
| (positional) | - | Feature or policy name (e.g., `meshretry`, `meshtrace`) |
| `--repo` | auto-detect cwd | Path to Kuma repo checkout |
| `--mode` | `generate` | `generate` (full AI) or `wizard` (interactive step-by-step) |
| `--from-pr` | - | GitHub PR URL to scope the feature from |
| `--from-branch` | - | Git branch to diff against master for scope |
| `--suite-name` | derived from feature | Override suite name (must follow `{feature}-{scope}` pattern) |
| `--yes`, `-y` | false | Run approval state in bypass mode, skip all AskUserQuestion review loops, and skip the final copy prompt |

## Preprocessed context

- Data directory: !`echo "${XDG_DATA_HOME:-$HOME/.local/share}/harness/suites"`
- Current repo root: !`git rev-parse --show-toplevel 2>/dev/null || echo "not in a git repo"`
- Existing suites: !`ls -1 "${XDG_DATA_HOME:-$HOME/.local/share}/harness/suites" 2>/dev/null | head -20 || echo "none yet"`

## Workflow rules

- Never delete, rm, or overwrite existing suite directories. If `harness create begin` detects an existing suite, it will prompt for resolution.

## Workflow - generate mode (default, `--mode generate`)

### Step 0: Query harness capabilities

Before any other work, query what harness can do so the rest of the workflow can adapt:

```bash
harness setup capabilities
```

Parse the JSON output and keep it as the `CAPABILITIES` context for all later steps. Use it to:

- Prefer `readiness.profiles` when it exists. Only offer profiles whose `ready` field is `true`. If a requested profile is not ready, summarize its `blocking_checks` instead of proposing it anyway.
- `readiness.profiles` may list multiple provider variants for the same Kubernetes profile name. For suite authoring, treat a profile as usable when any entry with that profile name is ready.
- Scope `required_dependencies` to features that are both supported and ready now. Static support still comes from `features.<name>.available`, but live usability comes from `readiness.features.<name>.ready` when present.
- When building the proposal (step 7), only propose universal-mode groups if the `universal` platform is listed and the matching `readiness.platforms.universal.ready` is `true`.
- Only propose envoy admin validation steps if `features.envoy_admin.available` is true and `readiness.features.envoy_admin.ready` is either true or absent.
- Pass relevant capability facts to discovery workers so they don't suggest groups the harness can't execute.

Interpretation rules:

- `available` means harness knows how to do it in principle.
- `readiness` means the current machine, project, and repo are ready to do it now.
- Keep the normal call zero-arg. Do not add `--project-dir` or `--repo-root` here unless you are explicitly debugging broken state.

If `readiness` is absent (older harness binary), fall back to the older static logic based on `cluster_topologies`, `platforms`, and `features.*.available`.

If `harness setup capabilities` fails completely (binary too old, not installed), fall back to the hardcoded default assumption: both platforms available, all features available.

### Step 1: Local validation

Manifest validation uses `harness create validate --path <file>`, which does local-only CRD validation without cluster access. No external binary install is needed. Continue to Step 2.

### Step 2: Resolve paths

Before resolving paths, check for stale create state from a previous session:

```bash
harness create show --kind session 2>/dev/null
```

If state exists from a different feature or a previous day, run `harness create reset` to clear it before proceeding. If state exists for the same feature being authored, continue without reset.

Use the pre-resolved data directory and repo root from the preprocessed context above. Do not eagerly create `DATA_DIR` here; `harness create begin` creates the concrete suite directory when create starts.

Resolve `REPO_ROOT`: `--repo` flag > pre-resolved repo root (if in a git repo) > check if cwd has `go.mod` with `kumahq/kuma` > fail with message.

### Step 3: Check worktree and branch

Run `git rev-parse --show-toplevel` and `git branch --show-current` in `REPO_ROOT`.

Use AskUserQuestion showing the detected path and branch in the description (e.g., `~/Projects/kuma on feat/meshretry`). Options:

- "Yes, correct"
- "Switch to a different worktree or branch"

If wrong location: run `git worktree list` and `git branch --list`, then present available worktrees and branches via AskUserQuestion. After selection, update `REPO_ROOT` or run `git checkout` accordingly.

### Step 4: Scope the feature

Identify what code to read based on the input:

- **From feature name** (default): use Glob to find `pkg/plugins/policies/*<name>*/` directories. Read the API spec, plugin.go, validator.go, and test fixtures. Use Grep to search for the feature name in non-policy paths if no policy dir matches.
- **From PR URL** (`--from-pr`): run `gh pr diff <number> --repo kumahq/kuma` to identify changed files.
- **From branch** (`--from-branch`): run `git diff master...<branch> --name-only` to identify changed files.

Handle ambiguity with AskUserQuestion:

- Multiple policy dirs match the feature name - ask which one to use.
- Feature type unclear (policy vs non-policy) - ask the user.
- PR diff touches files outside the expected scope - ask whether to include them.

**Error cases**: if the feature name matches no policy dir and Grep finds nothing, ask for the exact path or a more specific name. If a PR URL returns a 404 or `gh` fails, fall back to a branch name or feature name.

### Step 5: Derive suite identity and initialize create state

Read [references/suite-structure.md](references/suite-structure.md) before deriving the suite name.

Derive the suite name following the `{feature}-{scope}` pattern before any workers run:

- Full-surface suites use `{feature}-core`; focused suites use `{feature}-{aspect}`.
- For PRs, branches, or bugfixes, derive from the affected feature area rather than the branch name.

Reject generic names like `test-suite-1`, `full`, `feature-branch`, `my-test`. The `--suite-name` flag overrides derivation.

```bash
SUITE_NAME="${SUITE_NAME:-<derived-per-rules-above>}"
SUITE_DIR="${DATA_DIR}/${SUITE_NAME}"
APPROVAL_MODE="${APPROVAL_MODE:-interactive}"
```

If `--yes` or `-y` is set, change `APPROVAL_MODE` to `bypass` before calling `harness create begin` and `harness create approval-begin`.

Immediately initialize the internal create workspace:

```bash
harness create begin \
  --repo-root "${REPO_ROOT}" \
  --feature "${FEATURE}" \
  --mode "${APPROVAL_MODE}" \
  --suite-dir "${SUITE_DIR}" \
  --suite-name "${SUITE_NAME}"
```

Then save the scoped file inventory from step 4 with `harness create save --kind inventory`. Read [references/agent-output-format.md](references/agent-output-format.md) for the inventory payload shape.

If the suite name or directory changes later, rerun `harness create begin` and then resave the inventory before any workers continue.

### Step 6: Launch parallel discovery workers

Read [references/code-reading-guide.md](references/code-reading-guide.md) for source navigation paths, [references/variant-detection.md](references/variant-detection.md) for signal taxonomy, and [references/agent-output-format.md](references/agent-output-format.md) for payload contracts before constructing worker prompts.

Use the Agent tool to launch these workers in parallel:

- [../../agents/coverage-reader.md](../../agents/coverage-reader.md) for G1-G7 group material and evidence coverage
- [../../agents/variant-analyzer.md](../../agents/variant-analyzer.md) for S1-S7 variant signals
- [../../agents/schema-verifier.md](../../agents/schema-verifier.md) for manifest and validation constraints

Worker contract:

- Pass `REPO_ROOT`, the scoped file list from step 4, the feature name, and only the references needed for that worker.
- Launch all discovery workers with `mode: "auto"` so they can run `harness create save` via Bash without interactive approval. Background workers cannot prompt the user for tool permissions.
- Follow [references/agent-output-format.md](references/agent-output-format.md) for the exact payload schema, save path, and acknowledgement contract for each worker kind.

After all workers finish, load the saved payloads with `harness create show --kind inventory|coverage|variants|schema`.

If any worker result is missing, malformed, or clearly incomplete, rerun only that worker instead of continuing with gaps.

### Step 7: Build the proposal from saved worker outputs

Read [references/suite-structure.md](references/suite-structure.md) for the format spec.
Read [examples/example-motb-core-suite.md](examples/example-motb-core-suite.md) for a worked example of the suite format.
Read [examples/example-motb-core-group.md](examples/example-motb-core-group.md) for the expected group file structure.

Build the proposal from the saved worker outputs:

- Use coverage data to decide which base groups G1-G7 have enough evidence.
- Use variant signals to propose G8+ groups and to decide which signals are strong, moderate, or weak.
- Use schema facts to constrain manifests from the start, but treat them as planning input only.
- Run `harness create validate --path <file>` on authored manifests before stopping. Do not defer to a live cluster.
- When `profiles` includes `multi-zone`, set `clusters: all` on workload-deploying baselines per [references/suite-structure.md](references/suite-structure.md).
- Save the merged proposal with `harness create save --kind proposal`.
- After saving, print a full group summary so the user can review before the approval picker. For each proposed group, print:

```
## G{NN} {title}
Profile: {profile} | Platform: {platform}
Preconditions: {list}
What it tests: {2-3 sentence description of scope and method}
Manifests: {count} files ({filenames})
Success criteria: {list}
```

This summary is mandatory and must appear before the step 8 AskUserQuestion. The AskUserQuestion multiselect UI truncates descriptions, so the user needs the full picture printed as readable output first. Do not skip this summary or fold it into the AskUserQuestion options.

Group ordering rule - groups MUST be ordered by infrastructure complexity to avoid unnecessary cluster rebuilds:

1. Standalone/unit tests that need no cluster (if any)
2. Single-zone Kubernetes groups (all together)
3. Single-zone universal groups (all together)
4. Multi-zone Kubernetes groups (all together)
5. Multi-zone universal groups (all together)

Never interleave profiles - all groups for one profile must be contiguous. Within each tier, mark standalone tests that can run in parallel as parallelizable.

Variant review rules:

- Present strong signals pre-selected.
- Present moderate signals as selectable `[uncertain]` entries with evidence.
- Mention weak signals in the description only.

If no variants survive review, continue with G1-G7 only.

Proposal rules:

- `required_dependencies` must only contain harness infrastructure block names: `docker`, `compose`, `kubernetes`, `k3d`, `helm`, `envoy`, `kuma`, `build`. Application resources (otel-collector, demo-workload, postgres, redis, etc.) belong in `baseline/` manifests, not in `required_dependencies`. The runner will reject unknown requirement names at startup.
- Default every cluster-interacting command to full `harness` invocations. Only keep raw `kubectl`, `kumactl`, `curl`, or similar commands when the user explicitly asked for raw commands.
- Follow [references/suite-structure.md](references/suite-structure.md) for file ownership, naming, and manifest conventions.
- Add `gateway-api-crds` when proposed groups touch `MeshGateway`, `GatewayClass`, `Gateway`, or `HTTPRoute`.
- For universal mode suites (`--profile single-zone-universal`), use REST API format manifests and `harness run apply` plus `harness run kuma token` and `harness run kuma service` commands per [references/suite-structure.md](references/suite-structure.md).

### Step 8: Pre-write review gate

Build the full proposed suite in memory and, unless `--yes` or `-y` is set, run a mandatory AskUserQuestion review loop before creating `${SUITE_DIR}` or writing any files.

Use the same AskUserQuestion header as step 8 so the suite path and runner command stay visible in every review round.

Review loop rules:

- Present **every single group** as a structured AskUserQuestion option with multiSelect. Each option must use the `label` + `description` form so the user sees the group ID and title on the left, with profiles, preconditions, and success criteria in the description preview on the right. Do NOT summarize groups in prose text. If one prompt is too small, split across multiple AskUserQuestion passes. Every page must include an `All suggested groups` option.
- Never present the proposal as a text block followed by an approval question. The group list IS the approval question - each option is a group the user can include or exclude.
- After selection, gather one comment per selected group and one general suite-level comment, save them with `harness create save --kind edit-request`, and rebuild the proposal from cached worker outputs.
- Re-run only the affected discovery worker when feedback invalidates earlier coverage, variant, or schema assumptions, then resave the proposal and show the loop again until approval.
- Immediately initialize the approval state with `harness create approval-begin --mode interactive --suite-dir "${SUITE_DIR}"`. If `--yes` or `-y` is set, use `--mode bypass` instead. If the suite name or directory changes during the pre-write review loop, rerun `harness create approval-begin` with the updated `SUITE_DIR` before asking the canonical pre-write approval question.
- The approval gate question must be exactly `suite:create/prewrite: approve current proposal?` with options `Approve proposal`, `Request changes`, and `Cancel`. `Approve proposal` is the only answer that unlocks writes to `${SUITE_DIR}`.
- Suite files are only written after this loop approves. `--yes` and `-y` are the only bypass.

### Step 9: Save suite through dedicated writing workers

After the pre-write review gate approves the proposal, create the suite directory:

```bash
mkdir -p "${SUITE_DIR}/baseline" "${SUITE_DIR}/groups"
```

Launch these workers after approval:

- [../../agents/suite-writer.md](../../agents/suite-writer.md) for `${SUITE_DIR}/suite.md`
- [../../agents/baseline-writer.md](../../agents/baseline-writer.md) for `${SUITE_DIR}/baseline/*.yaml` - the baseline-writer must validate that Service manifests have `appProtocol` set on all ports (catches missing `appProtocol: http` on demo-app services and similar). Baseline manifests must pass `kubectl dry-run` validation (via `harness create validate`) before the suite is marked complete.
- [../../agents/group-writer.md](../../agents/group-writer.md) for `${SUITE_DIR}/groups/g{NN}-*.md` and `${SUITE_DIR}/groups/g{NN}/*.yaml`

Read [references/agent-output-format.md](references/agent-output-format.md) for the writer launch contract, fan-out limits, manifest validation rules, recovery sequence, and [references/suite-structure.md](references/suite-structure.md) for the manifest completeness rule and file content requirements.

### Step 10: Post-write review gate

Unless `--yes` or `-y` is set, immediately re-open AskUserQuestion after the suite is saved.

Every AskUserQuestion in this loop must include the suite path and runner command in the description:

- `Suite path: ${SUITE_DIR}/`
- `Run command: /suite:run ${SUITE_NAME}`

Before the AskUserQuestion approval picker, print a full readable summary of the saved suite so the user can review what they are approving. For each group, print:

```
## G{NN} {title}
Profile: {profile} | Platform: {platform}
Preconditions: {list}
What it tests: {2-3 sentence description of scope and method}
Manifests: {count} files ({filenames})
Success criteria: {list}
```

Also include the suite metadata (name, feature, profiles, dependencies) and baseline files. This summary is mandatory and must appear before the post-write AskUserQuestion. The AskUserQuestion picker truncates descriptions, so the user needs the full picture printed as readable output first. Do not skip this summary or fold it into the AskUserQuestion options.

Post-write loop rules:

- Show the saved suite summary with metadata, groups, dependencies, and current files on disk.
- Ask whether anything should change, be added, or is already correct.
- If the user requests changes, collect targeted comments plus one general suite-level comment, save them with `harness create save --kind edit-request`, and rerun only the affected writer workers. Rerun a discovery worker only if the requested change invalidates the cached evidence.
- Apply tiny deterministic single-file fixes directly with `Edit` instead of respawning a writer worker. Keep broader or multi-file changes in the writer-worker path.
- Reuse the saved create payloads for edit rounds. Do not reread the whole repo when the existing cached summaries are still valid.
- Re-open the same AskUserQuestion flow after every edit round until the user explicitly approves the suite.
- The approval gate question must be exactly `suite:create/postwrite: approve saved suite?` with options `Approve suite`, `Request changes`, and `Cancel`. `Approve suite` is the only answer that unlocks a successful stop after suite files were written.
- After final approval, show one last AskUserQuestion with the exact question `suite:create/copy: copy run command?` and the exact options `Copy command` and `Skip`. Do not offer the suite path as a copy target because the prompt already exposes it for manual copying.

### Step 11: Report

Print the saved path and suggest how to run it:

```
Suite saved to: ${SUITE_DIR}/
Run with: /suite:run ${SUITE_NAME}
```

## Workflow - wizard mode

Read [references/operational-guide.md](references/operational-guide.md) for wizard mode. Same state, workers, and gates as generate mode - review loop presents items individually instead of batch multiSelect.

## Hook messages

Read [references/operational-guide.md](references/operational-guide.md) for hook codes KSA001-KSA010 emitted during suite create.

## Error recovery

Read [references/operational-guide.md](references/operational-guide.md) for error recovery procedures.

## Example invocations

<example>
Generate a full test suite for the MeshRetry policy from a local repo checkout:
```bash
/suite:create meshretry --repo ~/Projects/kuma
```
Produces `meshretry-core/` with G1-G7 plus retry backend variants.
</example>

<example>
Scope test coverage from a PR diff:
```bash
/suite:create meshexternalservice --from-pr https://github.com/kumahq/kuma/pull/15571
```
Reads the PR diff, then generates groups only for affected code paths.
</example>

<example>
Generate from a feature branch:
```bash
/suite:create motb --from-branch feat/implement-motb --repo ~/Projects/kuma
```
Diffs the branch against master, then detects variant signals from the changed code.
</example>

<example>
Interactive wizard for step-by-step review:
```bash
/suite:create meshtrace --mode wizard --repo ~/Projects/kuma
```
Walks through each group interactively before moving to the next.
</example>

<example>
Override the derived suite name:
```bash
/suite:create meshretry --suite-name meshretry-timeout-edge-cases
```
Uses the custom name instead of deriving it from the feature. Must follow `{feature}-{scope}`.
</example>

<example>
Generate non-interactively for scripted use:
```bash
/suite:create motb --repo ~/Projects/kuma --yes
```
Skips the interactive review loops and the final copy prompt.
</example>

<example>
Input: `/suite:create meshtrace --repo ~/Projects/kuma`

Output structure:
```
~/.local/share/harness/suites/meshtrace-core/
├── suite.md
├── baseline/
│   ├── namespace.yaml
│   └── demo-app.yaml
└── groups/
    ├── g01-crud.md
    ├── g01/
    │   ├── 01-create.yaml
    │   └── 02-update.yaml
    ├── g02-validation.md
    ├── g02/
    │   ├── 01-invalid-enum.yaml
    │   └── 02-missing-field.yaml
    ├── g03-runtime.md
    ├── g03/
    │   └── 01-policy.yaml
    ├── g04-e2e.md
    ├── g04/
    │   └── 01-policy.yaml
    ├── g05-edge.md
    ├── g05/
    │   └── 01-dangling-ref.yaml
    ├── g06-multizone.md
    ├── g06/
    │   └── 01-policy.yaml
    ├── g07-compat.md
    ├── g07/
    │   └── 01-legacy.yaml
    ├── g08-zipkin.md
    ├── g08/
    │   └── 01-zipkin-backend.yaml
    ├── g09-otel.md
    └── g09/
        └── 01-otel-backend.yaml
```
</example>
