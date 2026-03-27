# Contents

1. [Wizard mode workflow](#wizard-mode-workflow)
2. [Hook messages](#hook-messages)
3. [Error recovery](#error-recovery)

---

# Operational guide

## Wizard mode workflow

Interactive step-by-step suite generation. Uses the same create state, workers, approval gates, and final report as generate mode. The only differences are:

1. After step 3, ask for feature name, target environment (`kubernetes`, `universal`, `both`), and scope (`full surface`, `focused aspect`) with AskUserQuestion.
2. Run the same discovery workers as generate step 6, but review variant signals one by one with AskUserQuestion options such as `Include`, `Exclude`, and `Need more evidence` instead of the batch multiSelect.
3. Present G1-G7 as a selectable list, then review each selected group in order with its cached worker evidence.
4. For each group, use AskUserQuestion with `Approve`, `Edit manifests`, `Edit validation commands`, and `Skip this group`. Save every edit round with `harness create save --kind edit-request` and rerun only the affected writer or discovery worker.
5. After individual group review completes, run the same pre-write gate, writing workers, post-write gate, and final report as generate mode.

## Hook messages

Hooks emit these codes during suite create:

| Code | Hook | Meaning |
| --- | --- | --- |
| KSA001 | guard-write | Write path is outside the suite:create surface |
| KSA002 | guard-question / verify-question / guard-write / verify-write / guard-stop | Approval state is missing, malformed, or the canonical approval prompt shape is wrong |
| KSA003 | guard-write / guard-stop | Approval is required before writing suite files or stopping after saved-suite edits |
| KSA004 | verify-write / guard-stop | Suite validation: authored manifests must pass local repo-backed validation, groups/baselines must be lists, and the suite must be complete |
| KSA006 | worker contract | Workers must save structured payloads through `harness create save` |
| KSA007 | worker contract | Worker reply must stay short and acknowledge the saved result |
| KSA008 | audit | Suites must stay user-story-first with concrete variant evidence |
| KSA009 | guard-question / verify-question / guard-bash / guard-write | The suite:create local validator decision must be resolved before real work starts |
| KSA010 | verify-question | Automatic `kubectl-validate` installation failed |

## Error recovery

- If repo resolution is ambiguous, stop and re-ask before reading code because a suite authored from the wrong worktree or branch is misleading.
- If the local-validator question is still unresolved, ask it before doing Bash work, writing files, or opening the canonical approval gates because the hooks fail closed until that one-time decision is recorded.
- If `harness create begin` was not run after deriving `SUITE_DIR`, stop and run `harness create begin --repo-root "${REPO_ROOT}" --feature "${FEATURE}" --mode interactive|bypass --suite-dir "${SUITE_DIR}" --suite-name "${SUITE_NAME}"` before launching workers because the compact worker state must exist before caching results.
- If `harness create approval-begin` was not run after deriving `SUITE_DIR`, stop and run `harness create approval-begin --mode interactive|bypass --suite-dir "${SUITE_DIR}"` before the canonical approval gates because the hooks fail closed on missing approval state.
- If a worker payload fails validation or is missing after a run, rerun only that worker and re-save its compact result instead of rereading the whole repo.
- If a worker returns raw file dumps or long prose, stop and rerun it with the compact-output contract because returning the heavy transcript defeats the architecture.
- If local manifest verification keeps failing, go back to the checked-in CRD or Go struct before saving because a broken suite wastes runner time and hides whether the bug is in Kuma or in the suite.
- If a write would land outside `${DATA_DIR}/${SUITE_NAME}`, stop and fix the target path because `suite:create` must only mutate the selected suite surface.
- If a writer worker partially completes (some group files exist, others are missing), do not blindly Write the remaining files. List the suite directory first with `ls`, Read any files that already exist on disk before overwriting them, then Write only the truly missing files directly. Subagent writes are invisible to the parent context's file tracker, so writing an existing file without reading it first triggers "File has been modified since read" errors from Claude Code.
