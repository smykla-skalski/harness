---
name: github-task-issue
description: "Draft, confirm, publish, and verify small high-quality GitHub task issues for work in this repository. Use when Codex needs to turn repo context, bugs, UX findings, screenshots, or implementation notes into a scoped GitHub issue for this project, especially when the issue must stay small, its title must follow the repository semantic `type(scope): description` format with a mandatory scope, must explicitly invoke the mandatory `$humanize` skill before publication, require explicit user approval, and be verified on the rendered GitHub page after creation."
---

# GitHub Task Issue

## Overview

Create small, high-signal GitHub issues that are ready to hand to an engineer. Keep the task narrow, explicitly invoke the installed `$humanize` skill on the saved draft before publication, stop for explicit approval, publish only after that approval, and then verify the rendered GitHub issue page.

Read [references/issue-guidelines.md](references/issue-guidelines.md) before drafting or publishing. It contains the small-task quality bar, the issue template, screenshot rules, the approval contract, and the render-verification checklist.

## Modes

This skill operates in two modes.

**Fast mode (default):** Format the user's input into a well-structured issue without deep code investigation. Trust the user's description - don't second-guess or verify against the codebase. Read code only when you need to fill in specific references (file paths, function names) that the user mentioned but didn't fully specify. This mode is cheap on tokens and fast.

**Deep mode:** Full investigation before drafting. Read the relevant code, confirm the problem, trace root causes, verify the feature gap is real. Everything in the "Deep mode investigation" section below applies only in deep mode.

To select deep mode, include `deep:` as the first word in the task prompt. For example: `deep: guard-bash lets kubectl through pipes`. If the prompt does not start with `deep:`, use fast mode.

## Hard constraints

- Work only on issues for the current repository.
- Optimize for small, independently shippable work. Split broad or multi-phase work into multiple issues instead of publishing one oversized issue.
- In deep mode, ground every issue in concrete evidence: code paths, failing commands, logs, issue templates, screenshots, UX observations, or repository conventions. In fast mode, ground the issue in what the user provided.
- Do not publish anything unless the skill explicitly invoked the installed `humanize` skill on the saved draft file. In Codex, invoke `$humanize <draft-path>`. In runtimes that expose slash-command skills, invoke `/humanize <draft-path>`. Manual cleanup, paraphrasing, or simply claiming the text was humanized does not satisfy this requirement. If the skill is unavailable, stop and report the blocker instead of publishing unreviewed prose.
- Do not publish on implied consent, passive acknowledgment, or silence. Require an AskUserQuestion-style explicit approval gate with exactly two outcomes: publish now, or request changes.
- If screenshots were supplied, make sure they are incorporated into the issue body itself, not left in local notes and not moved to a follow-up comment unless the user explicitly asks for that.
- After creating the real issue, verify the rendered issue page. The task is not done until screenshots are visible and the terms that were meant to be code-formatted render as code instead of raw backticks.

## Workflow

### 0. Create workspace

Every invocation gets its own workspace directory under `./tmp/github-task-issue/` so files are organized and concurrent agents don't collide. Create it at the very start and use it for all intermediate files throughout the workflow.

Derive a short slug from the issue topic - lowercase, hyphens only, no spaces or special characters, 50 characters max. Use the most descriptive 3-6 words from the user's input.

```bash
# Example: user says "guard-bash lets kubectl through pipes"
SLUG="guard-bash-pipe-bypass"
ISSUE_WORKSPACE="./tmp/github-task-issue/${SLUG}"
mkdir -p "$ISSUE_WORKSPACE"
```

All paths below reference `$ISSUE_WORKSPACE`.

### 1. Gather context and decide whether the work is issue-sized

Inspect the repository, the relevant files, and any evidence the user provided.

- Check the current repo issue template and contributing guidance before inventing structure or tone.
- In this repository, start with `.github/ISSUE_TEMPLATE/bug_report.yml` and `CONTRIBUTING.md` when they apply.
- Decide whether the work is small enough for one issue. If the draft needs multiple unrelated outcomes, multiple subsystems, or multiple implementation phases, split it before writing.
- If there is an existing issue or a likely duplicate, surface that before drafting a new one.

In fast mode, keep context gathering lightweight - use what the user provided. Move straight to drafting. In deep mode, read the relevant source files to verify the problem and ground the issue in code-level evidence.

### 2. Deep mode investigation (deep mode only)

Skip this step entirely in fast mode.

Before writing the issue body, verify the problem or gap against the actual codebase. For bugs, find the relevant source and confirm the bug is real. For features, check whether the capability already exists. For tasks/refactors, confirm the scope matches the user's description. If the issue turns out to be invalid (already fixed, duplicate, wrong module), tell the user before drafting.

### 3. Draft the issue with a small-task bias

Use the template in [references/issue-guidelines.md](references/issue-guidelines.md).

In deep mode, reference specific file paths, function names, and line numbers from your investigation. In fast mode, use whatever the user provided and only look up specific references if needed.

- Write the title in the repository semantic format `type(scope): description` with a mandatory lowercase scope.
- Reuse the same title taxonomy as commits and PRs from `CONTRIBUTING.md`: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`, `build`, or `perf`.
- Keep the scope specific to the affected area, such as `workflow/create`, `monitor/preferences`, or `hooks/tool-result`.
- Keep the summary short and factual.
- State the problem, the intended scope, and testable acceptance criteria.
- Add non-goals when they help prevent scope creep.
- Put exact commands, file paths, flags, hook names, and config keys in backticks.
- Keep a private render checklist of every term that must render as inline code or fenced code after publication.

### 4. Incorporate screenshots correctly

If the user supplied screenshots, treat them as first-class evidence. Validate every file path before doing any upload work - files that were accessible earlier may no longer exist (temp files cleaned up, moved, or from a previous agent context).

**Validation (mandatory before upload):**

For each local file path the user provided:
1. Check the file exists and is readable.
2. If the file is missing or unreadable, gate on explicit user input:
   - If AskUserQuestion is available, use it: "The screenshot at `<path>` is no longer accessible. How should I proceed?" with options "Provide a new path" / "Skip this screenshot".
   - If AskUserQuestion is not available, ask directly in conversation with the same two outcomes.
   - Do NOT silently drop the image or guess a replacement path.
3. If the user provides a new path, validate it again (loop until resolved or skipped).

Once all paths are resolved:

- Place each screenshot near the section it supports instead of dumping all images at the end without context.
- Add one short lead-in sentence before each image so the reader knows what to look at.
- Use meaningful alt text.
- If the user already provided hosted image URLs, embed them directly.
- If the user provided local image files, upload them with `scripts/upload-image.sh` and embed the returned markdown lines where they belong in the issue body. The script validates format (png, jpg, jpeg, gif, webp, svg), checks file size, and auto-optimizes images over 5MB via `sips` before uploading. It stores the files through the Git Data API, keeps them reachable via a hidden ref, and verifies that each resulting URL returns HTTP 200.
- Ensure the issue body references GitHub-hosted image URLs, not local filesystem paths.

### 5. Save the draft and explicitly invoke the mandatory `$humanize` skill

Write the issue title to a real file before publication:

```text
$ISSUE_WORKSPACE/title.txt
```

Validate the title through the bundled script before approval or publication:

```bash
scripts/publish-issue.py validate-title \
  --title-file "$ISSUE_WORKSPACE/title.txt"
```

If the title fails validation, fix it before continuing.

Write the issue draft to a real file before publication:

```text
$ISSUE_WORKSPACE/draft.md
```

Then explicitly invoke the installed `humanize` skill on that saved draft file.

- Use `$humanize $ISSUE_WORKSPACE/draft.md` in Codex.
- Do not treat manual rewriting as equivalent to this step. The skill invocation itself is required.
- If the title changes after user feedback, rerun `scripts/publish-issue.py validate-title --title-file "$ISSUE_WORKSPACE/title.txt"` before re-asking for approval.
- If the draft changes after user feedback, invoke `$humanize $ISSUE_WORKSPACE/draft.md` again before re-asking for approval.
- Re-read the humanized draft and confirm the meaning stayed technically correct.
- Save the private render checklist:

```text
$ISSUE_WORKSPACE/render_checklist.txt
```

- Keep one expected inline-code term per line in that checklist file. Use it during render verification.
- Do not ask for approval until the title validation and `$humanize` steps have completed successfully.

### 6. Gate publication with explicit user approval

Preferred contract:

- If the runtime exposes `AskUserQuestion`, use it.
- Present exactly two choices:
  - `Create issue`: publish the current draft as-is.
  - `Request changes`: do not publish; ask the user what should be changed or added.
- If the runtime does not expose `AskUserQuestion`, ask the user directly in the main conversation with the same two outcomes and wait for the answer. Do not publish until the user clearly chooses the publish path.

When the user requests changes:

- update the title and draft as needed
- rerun `scripts/publish-issue.py validate-title --title-file "$ISSUE_WORKSPACE/title.txt"` if the title changed
- rerun `$humanize <draft-path>` if the draft changed
- show the revised draft
- ask for approval again

### 7. Publish using the right path

Create and edit issues through the bundled wrapper, not via ad-hoc shell interpolation:

```bash
scripts/publish-issue.py create \
  --title-file "$ISSUE_WORKSPACE/title.txt" \
  --body-file "$ISSUE_WORKSPACE/draft.md" \
  --label "kind/bug" \
  --label "area/api"
```

- Use repeated `--label` flags when labels apply.
- Reuse existing labels or issue-template conventions when they clearly apply. Do not invent labels blindly.
- For edits after publication, use:

```bash
scripts/publish-issue.py edit \
  --issue "<issue-number-or-url>" \
  --title-file "$ISSUE_WORKSPACE/title.txt" \
  --body-file "$ISSUE_WORKSPACE/draft.md"
```

### 8. Verify the rendered GitHub issue page

Verify the live issue through the GitHub rendered HTML returned by the issue API:

```bash
scripts/verify-issue-render.py \
  --issue "<issue-number-or-url>" \
  --expected-title-file "$ISSUE_WORKSPACE/title.txt" \
  --body-file "$ISSUE_WORKSPACE/draft.md" \
  --expected-code-file "$ISSUE_WORKSPACE/render_checklist.txt"
```

- Confirm the title matches the approved title file and still passes the semantic `type(scope): description` validation.
- Confirm the section structure matches the approved draft.
- Confirm every screenshot renders as an image tag and that each referenced image URL is reachable.
- Confirm every item in the private render checklist is rendered inside code tags, not as raw backticks in plain text.
- Confirm task lists render as checkboxes.
- If you intentionally used `#123` issue references, add `--check-issue-links` to verify they rendered as links.

If any check fails, edit the live issue with `scripts/publish-issue.py edit ...` and re-run `scripts/verify-issue-render.py`.

## Failure Handling

- If the task is too large for one issue, stop and propose a split before drafting further.
- If the title does not pass `scripts/publish-issue.py validate-title`, stop and fix it before approval or publication.
- If the `humanize` skill cannot be explicitly invoked on the draft file, stop before publication.
- If explicit approval is missing, stop before publication.
- If screenshot upload fails, do not pretend the issue is complete. Retry or stop and explain the blocker.
- If `scripts/verify-issue-render.py` fails, the issue is not done. Fix the live body and verify again.

## Deliverables

Before publication:

- the final humanized draft
- the approval prompt

After publication:

- the issue URL and number
- a short verification note that confirms screenshot visibility and markdown/code rendering
