---
name: new
description: >-
  Generate test suites for suite:run by reading Kuma source code.
  Produces ready-to-run suites with manifests, validation steps, and expected outcomes
  for both Kubernetes and universal mode deployments.
  Use when creating a new test suite for a Kuma feature, converting a PR into a test plan,
  building regression tests from source code, or when the user asks for test coverage,
  a test plan, or wants to write tests for any Kuma policy or feature.
argument-hint: "<feature-name> [--repo /path/to/kuma] [--mode generate|wizard] [--from-pr PR_URL] [--from-branch BRANCH] [--suite-name NAME] [--yes|-y]"
allowed-tools: Agent, AskUserQuestion, Bash, Edit, Glob, Grep, Read, Write
user-invocable: true
disable-model-invocation: true
hooks:
  PreToolUse:
    - matcher: "AskUserQuestion"
      hooks:
        - type: command
          command: "harness hook --skill suite:new guard-question"
    - matcher: "Bash"
      hooks:
        - type: command
          command: "harness hook --skill suite:new guard-bash"
    - matcher: "Edit"
      hooks:
        - type: command
          command: "harness hook --skill suite:new guard-write"
    - matcher: "Write"
      hooks:
        - type: command
          command: "harness hook --skill suite:new guard-write"
  PostToolUse:
    - matcher: "AskUserQuestion"
      hooks:
        - type: command
          command: "harness hook --skill suite:new verify-question"
        - type: command
          command: "harness hook --skill suite:new audit"
    - matcher: "Bash"
      hooks:
        - type: command
          command: "harness hook --skill suite:new audit"
    - matcher: "Edit"
      hooks:
        - type: command
          command: "harness hook --skill suite:new verify-write"
        - type: command
          command: "harness hook --skill suite:new audit"
    - matcher: "Write"
      hooks:
        - type: command
          command: "harness hook --skill suite:new verify-write"
        - type: command
          command: "harness hook --skill suite:new audit"
  PostToolUseFailure:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "harness hook --skill suite:new audit"
  Stop:
    - hooks:
        - type: command
          command: "harness hook --skill suite:new guard-stop"
---

<!-- justify: I23 harness is installed on PATH by project SessionStart hooks, not bundled as a script -->
<!-- justify: HK-stdin harness reads hook stdin internally via its Python hook dispatcher -->
<!-- justify: HK-loop harness has internal re-entry guards in its hook dispatcher -->
<!-- justify: HK-resolve harness is installed on PATH by SessionStart hooks at runtime, not bundled as a script -->

# Kuma suite author

Generate test suites for `suite:run` by reading Kuma source code and emitting ready-to-run manifests, commands, and variant coverage.

Avoid using for running suites (use `/suite:run`), editing existing suites, or generating non-Kuma test plans, because authoring and execution need different guardrails.

All hooks route through `harness hook --skill suite:new <hook-name>`, using the bare `harness` command installed by project `SessionStart` hooks.

## Compact recovery

If Claude Code resumes this skill after compaction, trust the injected `SessionStart(compact)` handoff as the authoritative summary of the saved authoring workspace, approval phase, and cached worker outputs. Resume the exact review gate or writer/edit round described there. Do not rerun discovery or reinitialize approval unless the handoff explicitly says the saved state diverged and names the files that must be reloaded first.

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

- Data directory: !`echo "${XDG_DATA_HOME:-$HOME/.local/share}/kuma/suites"`
- Current repo root: !`git rev-parse --show-toplevel 2>/dev/null || echo "not in a git repo"`
- Existing suites: !`ls -1 "${XDG_DATA_HOME:-$HOME/.local/share}/kuma/suites" 2>/dev/null | head -20 || echo "none yet"`

## Workflow - generate mode (default, `--mode generate`)

### Step 0: Query harness capabilities

Before any other work, query what harness can do so the rest of the workflow can adapt:

```bash
harness capabilities
```

Parse the JSON output and keep it as the `CAPABILITIES` context for all later steps. Use it to:

- Decide which `profiles` to offer (only include profiles whose platform and topology appear in `cluster_topologies` and `platforms`).
- Scope `required_dependencies` to features that are actually available (e.g. only add `gateway-api-crds` if `features.gateway_api.available` is true).
- When building the proposal (step 7), only propose universal-mode groups if the `universal` platform is listed, and only propose envoy admin validation steps if `features.envoy_admin.available` is true.
- Pass relevant capability facts to discovery workers so they don't suggest groups the harness can't execute.

If `harness capabilities` fails (binary too old, not installed), fall back to the hardcoded default assumption: both platforms available, all features available.

### Step 1: Local validation

Manifest validation uses `harness authoring-validate --path <file>`, which does local-only CRD validation without cluster access. No external binary install is needed. Continue to Step 2.

### Step 2: Resolve paths

Before resolving paths, check for stale authoring state from a previous session:

```bash
harness authoring-show --kind session 2>/dev/null
```

If state exists from a different feature or a previous day, run `harness authoring-reset --skill suite:new` to clear it before proceeding. If state exists for the same feature being authored, continue without reset.

Use the pre-resolved data directory and repo root from the preprocessed context above. Do not eagerly create `DATA_DIR` here; `harness authoring-begin` creates the concrete suite directory when authoring starts.

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

### Step 5: Derive suite identity and initialize authoring state

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

If `--yes` or `-y` is set, change `APPROVAL_MODE` to `bypass` before calling `authoring-begin` and `approval-begin`.

Immediately initialize the internal authoring workspace:

```bash
harness authoring-begin \
  --skill suite:new \
  --repo-root "${REPO_ROOT}" \
  --feature "${FEATURE}" \
  --mode "${APPROVAL_MODE}" \
  --suite-dir "${SUITE_DIR}" \
  --suite-name "${SUITE_NAME}"
```

Then save the scoped file inventory from step 4 with `harness authoring-save --kind inventory`. Read [references/agent-output-format.md](references/agent-output-format.md) for the inventory payload shape.

If the suite name or directory changes later, rerun `authoring-begin` and then resave the inventory before any workers continue.

### Step 6: Launch parallel discovery workers

Read [references/code-reading-guide.md](references/code-reading-guide.md) for source navigation paths, [references/variant-detection.md](references/variant-detection.md) for signal taxonomy, and [references/agent-output-format.md](references/agent-output-format.md) for payload contracts before constructing worker prompts.

Launch these workers in parallel:

- [../../agents/coverage-reader.md](../../agents/coverage-reader.md) for G1-G7 group material and evidence coverage
- [../../agents/variant-analyzer.md](../../agents/variant-analyzer.md) for S1-S7 variant signals
- [../../agents/schema-verifier.md](../../agents/schema-verifier.md) for manifest and validation constraints

Worker contract:

- Pass `REPO_ROOT`, the scoped file list from step 4, the feature name, and only the references needed for that worker.
- Launch all discovery workers with `mode: "auto"` so they can run `harness authoring-save` via Bash without interactive approval. Background workers cannot prompt the user for tool permissions.
- Follow [references/agent-output-format.md](references/agent-output-format.md) for the exact payload schema, save path, and acknowledgement contract for each worker kind.

After all workers finish, load the saved payloads with `harness authoring-show --kind inventory|coverage|variants|schema`.

If any worker result is missing, malformed, or clearly incomplete, rerun only that worker instead of continuing with gaps.

### Step 7: Build the proposal from saved worker outputs

Read [references/suite-structure.md](references/suite-structure.md) for the format spec.
Read [examples/example-motb-core-suite.md](examples/example-motb-core-suite.md) for a worked example of the suite format.
Read [examples/example-motb-core-group.md](examples/example-motb-core-group.md) for the expected group file structure.

Build the proposal from the saved worker outputs:

- Use coverage data to decide which base groups G1-G7 have enough evidence.
- Use variant signals to propose G8+ groups and to decide which signals are strong, moderate, or weak.
- Use schema facts to constrain manifests from the start, but treat them as planning input only.
- Run `harness authoring-validate --path <file>` on authored manifests before stopping. Do not defer to a live cluster.
- When `profiles` includes `multi-zone`, set `clusters: all` on workload-deploying baselines per [references/suite-structure.md](references/suite-structure.md).
- Save the merged proposal with `harness authoring-save --kind proposal`.

Variant review rules:

- Present strong signals pre-selected.
- Present moderate signals as selectable `[uncertain]` entries with evidence.
- Mention weak signals in the description only.

If no variants survive review, continue with G1-G7 only.

Proposal rules:

- Default every cluster-interacting command to full `harness` invocations. Only keep raw `kubectl`, `kumactl`, `curl`, or similar commands when the user explicitly asked for raw commands.
- Follow [references/suite-structure.md](references/suite-structure.md) for file ownership, naming, and manifest conventions.
- Add `gateway-api-crds` when proposed groups touch `MeshGateway`, `GatewayClass`, `Gateway`, or `HTTPRoute`.
- For universal mode suites (`--profile single-zone-universal`), use REST API format manifests and `harness apply`/`token`/`service` commands per [references/suite-structure.md](references/suite-structure.md).

### Step 8: Pre-write review gate

Build the full proposed suite in memory and, unless `--yes` or `-y` is set, run a mandatory AskUserQuestion review loop before creating `${SUITE_DIR}` or writing any files.

Use the same AskUserQuestion header as step 8 so the suite path and runner command stay visible in every review round.

Review loop rules:

- Present **all suggested groups** with multiSelect. If one prompt is too small, split it across multiple AskUserQuestion passes. Every page must still include an `All suggested groups` option for the complete inventory.
- Each group option must include a one-line description and enough context to decide whether it belongs in the suite.
- After selection, gather one comment per selected group and one general suite-level comment, save them with `harness authoring-save --kind edit-request`, and rebuild the proposal from cached worker outputs.
- Re-run only the affected discovery worker when feedback invalidates earlier coverage, variant, or schema assumptions, then resave the proposal and show the loop again until approval.
- Immediately initialize the approval state with `harness approval-begin --skill suite:new --mode interactive --suite-dir "${SUITE_DIR}"`. If `--yes` or `-y` is set, use `--mode bypass` instead. If the suite name or directory changes during the pre-write review loop, rerun `approval-begin` with the updated `SUITE_DIR` before asking the canonical pre-write approval question.
- The approval gate question must be exactly `suite:new/prewrite: approve current proposal?` with options `Approve proposal`, `Request changes`, and `Cancel`. `Approve proposal` is the only answer that unlocks writes to `${SUITE_DIR}`.
- Suite files are only written after this loop approves. `--yes` and `-y` are the only bypass.

### Step 9: Save suite through dedicated writing workers

After the pre-write review gate approves the proposal, create the suite directory:

```bash
mkdir -p "${SUITE_DIR}/baseline" "${SUITE_DIR}/groups"
```

Launch these workers after approval:

- [../../agents/suite-writer.md](../../agents/suite-writer.md) for `${SUITE_DIR}/suite.md`
- [../../agents/baseline-writer.md](../../agents/baseline-writer.md) for `${SUITE_DIR}/baseline/*.yaml`
- [../../agents/group-writer.md](../../agents/group-writer.md) for `${SUITE_DIR}/groups/g{NN}-*.md`

Writer contract:

- Pass only the saved proposal, schema facts, and the exact file ownership for that worker.
- Keep writer fan-out bounded. Do not start more than four writer workers at once.
- Launch all writer workers with `mode: "auto"` so they can write files without interactive approval. Background workers cannot prompt the user, so writes are denied without this mode.
- Require every writer that emits manifests to run `harness authoring-validate --path <file>` on its owned outputs before it stops. Use the current repo checkout as the schema source of truth; all required schemas, including CRDs, are already in this repo. Do not substitute a live-cluster check.
- When the proposal includes multi-zone profiles, pass the baseline cluster distribution from the proposal to the baseline-writer and suite-writer so they emit the object form (`- path:` with `clusters:`) in `baseline_files` frontmatter and include the Clusters column in the baseline manifests table.
- Follow [references/agent-output-format.md](references/agent-output-format.md) for `authoring-show` usage and acknowledgement rules, and [references/suite-structure.md](references/suite-structure.md) for file content requirements.

### Step 10: Post-write review gate

Unless `--yes` or `-y` is set, immediately re-open AskUserQuestion after the suite is saved.

Every AskUserQuestion in this loop must include the suite path and runner command in the description:

- `Suite path: ${SUITE_DIR}/`
- `Run command: /suite:run ${SUITE_NAME}`

Post-write loop rules:

- Show the saved suite summary with metadata, groups, dependencies, and current files on disk.
- Ask whether anything should change, be added, or is already correct.
- If the user requests changes, collect targeted comments plus one general suite-level comment, save them with `harness authoring-save --kind edit-request`, and rerun only the affected writer workers. Rerun a discovery worker only if the requested change invalidates the cached evidence.
- Apply tiny deterministic single-file fixes directly with `Edit` instead of respawning a writer worker. Keep broader or multi-file changes in the writer-worker path.
- Reuse the saved authoring payloads for edit rounds. Do not reread the whole repo when the existing cached summaries are still valid.
- Re-open the same AskUserQuestion flow after every edit round until the user explicitly approves the suite.
- The approval gate question must be exactly `suite:new/postwrite: approve saved suite?` with options `Approve suite`, `Request changes`, and `Cancel`. `Approve suite` is the only answer that unlocks a successful stop after suite files were written.
- After final approval, show one last AskUserQuestion with the exact question `suite:new/copy: copy run command?` and the exact options `Copy command` and `Skip`. Do not offer the suite path as a copy target because the prompt already exposes it for manual copying.

### Step 11: Report

Print the saved path and suggest how to run it:

```
Suite saved to: ${SUITE_DIR}/
Run with: /suite:run ${SUITE_NAME}
```

## Workflow - wizard mode

Read [references/operational-guide.md](references/operational-guide.md) for wizard mode. Same state, workers, and gates as generate mode - review loop presents items individually instead of batch multiSelect.

## Hook messages

Read [references/operational-guide.md](references/operational-guide.md) for hook codes KSA001-KSA010 emitted during suite authoring.

## Error recovery

Read [references/operational-guide.md](references/operational-guide.md) for error recovery procedures.

## Example invocations

<example>
Generate a full test suite for the MeshRetry policy from a local repo checkout:
```bash
/suite:new meshretry --repo ~/Projects/kuma
```
Produces `meshretry-core/` with G1-G7 plus retry backend variants.
</example>

<example>
Scope test coverage from a PR diff:
```bash
/suite:new meshexternalservice --from-pr https://github.com/kumahq/kuma/pull/15571
```
Reads the PR diff, then generates groups only for affected code paths.
</example>

<example>
Generate from a feature branch:
```bash
/suite:new motb --from-branch feat/implement-motb --repo ~/Projects/kuma
```
Diffs the branch against master, then detects variant signals from the changed code.
</example>

<example>
Interactive wizard for step-by-step review:
```bash
/suite:new meshtrace --mode wizard --repo ~/Projects/kuma
```
Walks through each group interactively before moving to the next.
</example>

<example>
Override the derived suite name:
```bash
/suite:new meshretry --suite-name meshretry-timeout-edge-cases
```
Uses the custom name instead of deriving it from the feature. Must follow `{feature}-{scope}`.
</example>

<example>
Generate non-interactively for scripted use:
```bash
/suite:new motb --repo ~/Projects/kuma --yes
```
Skips the interactive review loops and the final copy prompt.
</example>

<example>
Input: `/suite:new meshtrace --repo ~/Projects/kuma`

Output structure:
```
~/.local/share/kuma/suites/meshtrace-core/
├── suite.md
├── baseline/
│   ├── namespace.yaml
│   └── demo-app.yaml
└── groups/
    ├── g01-crud.md
    ├── g02-validation.md
    ├── g03-runtime.md
    ├── g04-e2e.md
    ├── g05-edge.md
    ├── g06-multizone.md
    ├── g07-compat.md
    ├── g08-zipkin.md
    └── g09-otel.md
```
</example>
