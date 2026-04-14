---
name: issue
description: "Create well-structured GitHub issues with semantic `type(scope): description` titles and task checklists for the harness project. Use when the user wants to file a bug, request a feature, propose a task, create a work item, track a problem, or open any kind of GitHub issue. Also use when the user says \"open an issue\", \"file a bug\", \"create a ticket\", \"track this\", or describes a problem and wants it recorded on GitHub."
argument-hint: "[--deep] [title or description of the issue]"
allowed-tools: AskUserQuestion, Bash, Glob, Grep, Read, Skill, Write
user-invocable: true
---

# GitHub issue creator

Create focused, high-quality GitHub issues for the `smykla-skalski/harness` repository.

## Modes

This skill operates in two modes. Pick the right one based on the arguments.

**Fast mode (default):** Format the user's input into a well-structured issue. Trust what the user says - don't investigate the codebase. Read code only to fill in specific references (file paths, function names) the user mentioned but didn't fully specify. Shape it into a clean issue with proper structure, semantic title, and actionable task list.

**Deep mode (`--deep` flag):** Full investigation before drafting. Read the relevant code, confirm the problem, trace root causes, verify the feature gap is real. Everything in the "Investigate the code" section below applies only in deep mode.

## Arguments

`--deep` - Run in deep mode with full code investigation before drafting. Without this flag, the skill runs in fast mode. Parse the first token after `/issue`: if it is `--deep`, enable deep mode and treat the rest as the issue description.

## Philosophy

An issue is a contract. Someone - a human or an agent running `/do` - will pick it up and follow its task list to the letter. A vague issue produces vague work. A lazy task breakdown produces shortcuts. A wrong description wastes hours of effort in the wrong direction.

Write every issue as if you are the one who will implement it next, and the only context you'll have is what's written in the issue body.

## Quality rules

1. **No vague task items.** Every task list checkbox must be specific enough that someone can start and finish it in a single session without further clarification. "Fix the bug" or "implement the feature" are never acceptable. Name the file, the function, the module.
2. **Every implementation item gets a test item.** If a task says "add X", there must be a corresponding "add test for X" item. This repo uses TDD - the issue should reflect that.
3. **Performance-sensitive changes get a performance item.** If the issue touches hot paths, view bodies, async code, or frequently called logic, include a task item for performance verification or measurement.
4. **Describe the proper fix, not the quick patch.** If the right solution requires refactoring a module, say so in the issue. Do not scope the task list to a band-aid fix to make it look smaller. The implementer needs to know the real scope upfront.
5. **Root cause over symptoms (deep mode).** For bugs in deep mode, trace the problem to its origin. "The sidebar shows stale data" is a symptom. "The sidebar reads from a cached snapshot that is not invalidated when the source changes" is the root cause. Describe both, but frame the fix around the root cause. In fast mode, use whatever framing the user provided.

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

### 1. Gather context

Understand what the user wants to track. Input might be a full description, a screenshot, a vague complaint, or just a title. Ask clarifying questions only when the intent is genuinely unclear - never interrogate, because back-and-forth delays issue creation and the user can always refine after filing.

Determine:
- What happened or what's needed (the core problem or request)
- What the user expects instead (for bugs) or what the end state looks like (for features)
- Steps to reproduce (for bugs, if applicable)
- Which area of the codebase is involved, if obvious
- Whether the user has screenshots or files to attach

In fast mode, you're done gathering after this step. Move straight to picking labels and drafting.

### 2. Investigate the code (deep mode only)

Skip this step entirely in fast mode.

Before writing a single line of the issue body, verify the problem or gap against the actual codebase. This prevents filing issues that describe non-existent behavior, target the wrong module, or propose fixes that are already implemented.

For bugs:
- Find the relevant source file and read the code path the user describes
- Confirm the bug is real and reproducible from the code, not just from the user's description
- Identify the root cause, not just the symptom

For features:
- Read the module that would be affected
- Check whether the feature (or something close) already exists
- Identify what would need to change and roughly how much code is involved

For tasks/refactors:
- Read the area being discussed
- Confirm the scope matches what the user described

If investigation reveals the issue is invalid (already fixed, already exists, wrong module), tell the user before drafting. Use `AskUserQuestion` if the findings are ambiguous.

### 3. Pick the right labels

The repo uses a `kind/` + `area/` label taxonomy. Pick the most accurate combination:

**Kind** (pick one):
- `kind/bug` - something broken
- `kind/enhancement` - new feature or improvement
- `kind/documentation` - docs-only change
- `kind/question` - needs discussion or clarification
- `kind/security` - security-related

**Area** (pick one or more if applicable):
- `area/api` - CLI commands, flags, output contracts
- `area/ci` - GitHub Actions, workflows, automation
- `area/deps` - dependency updates
- `area/docs` - documentation
- `area/testing` - test infrastructure, test suites

If a standard label doesn't fit, skip it rather than forcing one.

### 4. Draft the issue

In deep mode, use the findings from step 2 to inform every section - reference specific file paths, function names, and line numbers discovered during investigation. In fast mode, use whatever the user provided and only look up specific references (file paths, function names) if the user mentioned something you need to pin down.

Write the issue body in markdown. Structure depends on the kind:

**Bug issues:**
```
## What happened

[Plain description of the problem]

## Expected behavior

[What should happen instead]

## Steps to reproduce

1. [Step]
2. [Step]

## Environment

- harness version: [if known]
- OS: [if relevant]

## Task list

- [ ] [Specific fix task]
- [ ] [Verification task]
```

**Feature/enhancement issues:**
```
## Problem

[What's missing or inconvenient, and why it matters]

## Proposed solution

[Concrete description of what to build]

## Task list

- [ ] [Implementation task]
- [ ] [Test task]
- [ ] [Documentation task, if applicable]
```

**General task issues:**
```
## Context

[Background and motivation]

## Scope

[What's in and out of scope]

## Task list

- [ ] [Task]
- [ ] [Task]
```

Guidelines for the body:
- Every implementation task item must have a corresponding test task item. This repo uses TDD. Example: if a task says "Add timeout to `runner.rs`", the next item should be "Add test `timeout_triggers_verdict` in `runner::tests`".
- If the change touches performance-sensitive code (hot paths, view bodies, async handlers, frequently called functions), include a task item for performance verification. Example: "Verify no new allocations in sidebar view body via `/swiftui-performance-macos` audit".
- If the proper fix requires a refactor, scope the task list to include the refactor. Do not shrink the task list to avoid showing the real cost - the implementer needs to know upfront.
- Never include version bump tasks in the task list. Version bumps happen on `main` after the feature branch merges, not inside the worktree. The `/do` skill handles this separately with a user-gated step. Including a version bump task causes merge conflicts when multiple agents work in parallel.
- Use backtick-wrapped inline code for file paths, command names, function names, flag names, error messages, and any other literal code references. Double-check every technical term - if it would appear in a terminal or editor, wrap it in backticks. This matters because the post-creation verifier checks rendered `<code>` tags, so missing backticks cause verification failures.
- Keep paragraphs short. Two to three sentences max.
- Don't pad with filler. If a section has nothing useful to say, drop the section entirely.
- Reference related issues or PRs with `#number` syntax when relevant.
- Write the issue title in the same semantic format used for repo commits and PRs: `type(scope): description`, with a mandatory lowercase scope and one of `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`, `build`, or `perf`.

### 5. Incorporate screenshots

If the user provides screenshots or image files, validate every path before doing any upload work. Files that were accessible earlier in the conversation may no longer exist (temp files cleaned up, moved, or from a previous agent context). Silent fallback to "no image" is not acceptable - the user decided to include that screenshot for a reason.

**Validation (mandatory before upload):**

For each local file path the user provided:
1. Check the file exists and is readable.
2. If the file is missing or unreadable, use `AskUserQuestion` immediately:
   - Question: "The screenshot at `<path>` is no longer accessible. How should I proceed?"
   - Option 1: **Provide a new path** - "I'll give you an updated file path"
   - Option 2: **Skip this screenshot** - "Continue without this image"
   - Do NOT silently drop the image or guess a replacement path.
3. If the user picks "Provide a new path", wait for the new path and validate it again (loop until resolved or skipped).

Once all paths are resolved:

1. Place each image where it adds context to the surrounding text. Don't dump all images at the bottom - weave them into the narrative (e.g., "The error appears in the toolbar area:" followed by the image).
2. If the user provides a URL to an already-hosted image, embed it directly with `![description](url)`.
3. If the user provides a local file path, upload it using the bundled script. The script validates format (png, jpg, jpeg, gif, webp, svg), checks file size, and auto-optimizes images over 5MB via `sips` before uploading. It handles GitHub API calls, deduplicates colliding filenames, URL-encodes the final paths, and verifies each upload returns HTTP 200.

**Uploading local images:**

```bash
# Single image
"${CLAUDE_SKILL_DIR}/scripts/upload-image.sh" /path/to/screenshot.png
# Output: ![screenshot](https://github.com/.../screenshot.png?raw=true)

# Multiple images (batched into one commit)
"${CLAUDE_SKILL_DIR}/scripts/upload-image.sh" screenshot1.png screenshot2.png error.jpg

# Override the 5MB auto-optimization threshold
"${CLAUDE_SKILL_DIR}/scripts/upload-image.sh" --max-size 2097152 large-screenshot.png
```

The script outputs one markdown image reference per line on stdout. Capture the output and embed each line where it belongs in the issue body. The URLs are permanent (tied to a commit SHA, not a branch).

If the script exits non-zero, one or more uploads failed verification - check stderr for details. Images that exceed the size limit are automatically resized (halving dimensions iteratively) until they fit. The script prints optimization info to stderr so you can report what happened to the user.

### 6. Humanize the content

This step is mandatory because AI-generated prose patterns (significance inflation, synonym cycling, hedging stacks) erode credibility when visible in a public issue tracker. Before showing the draft to the user, strip AI writing patterns so the issue reads like a human wrote it.

1. Write the issue title to `$ISSUE_WORKSPACE/title.txt`.
2. Validate it before approval or publication:
   ```
   "${CLAUDE_SKILL_DIR}/scripts/publish-issue.py" validate-title \
     --title-file "$ISSUE_WORKSPACE/title.txt"
   ```
3. Write the issue body to `$ISSUE_WORKSPACE/draft.md`.
4. Invoke the humanize skill on that file:
   ```
   Skill("humanize", args: "$ISSUE_WORKSPACE/draft.md")
   ```
5. Save the render checklist to `$ISSUE_WORKSPACE/render_checklist.txt`, one expected code term per line.
6. Read the humanized file back and verify that backtick-wrapped code terms, markdown structure, and task list formatting survived intact. Humanize targets prose, not formatting, but shell-style backtick references can occasionally get rewritten. If any code terms lost their backticks, restore them.

Note: `$ISSUE_WORKSPACE/title.txt`, `$ISSUE_WORKSPACE/draft.md`, and `$ISSUE_WORKSPACE/render_checklist.txt` are scoped to this invocation, so no other agent can interfere with them mid-workflow.

### 7. User review gate

Before publishing anything, the user must approve the issue. Use `AskUserQuestion` with a preview showing the full draft:

- Question: "Ready to create this issue?" (include title and labels in the question text)
- Option 1: **Create issue** - "Publish to GitHub as shown"
- Option 2: **Request changes** - "I have feedback on what to adjust"
- The `preview` field on Option 1 should contain the full issue body so the user can read it before deciding.

If the user picks "Request changes", they'll provide notes. Apply their feedback, re-run `"${CLAUDE_SKILL_DIR}/scripts/publish-issue.py" validate-title --title-file "$ISSUE_WORKSPACE/title.txt"` if the title changed, re-run `/humanize` on any substantially rewritten sections, and present via `AskUserQuestion` again. Loop until they approve.

### 8. Create the issue

Once approved, write the final body to `$ISSUE_WORKSPACE/body_final.md` and create the issue through the bundled wrapper:

```bash
"${CLAUDE_SKILL_DIR}/scripts/publish-issue.py" create \
  --repo smykla-skalski/harness \
  --title-file "$ISSUE_WORKSPACE/title.txt" \
  --label "<label1>" \
  --label "<label2>" \
  --body-file "$ISSUE_WORKSPACE/body_final.md"
```

Capture the issue URL and number from the output.

### 9. Post-creation verification

This step is mandatory because GitHub's markdown renderer silently breaks backtick formatting, task list checkboxes, and image embeds in ways that aren't visible in the raw source. After the issue is live on GitHub, verify it renders correctly:

```bash
"${CLAUDE_SKILL_DIR}/scripts/verify-issue-render.py" \
  --repo smykla-skalski/harness \
  --issue "<number>" \
  --expected-title-file "$ISSUE_WORKSPACE/title.txt" \
  --body-file "$ISSUE_WORKSPACE/body_final.md" \
  --expected-code-file $ISSUE_WORKSPACE/render_checklist.txt
```

Check for these specific problems:
- **Broken title format**: the live title no longer matches the approved title or no longer passes semantic `type(scope): description` validation.
- **Broken images**: image markdown exists in the body but the live HTML has too few image tags or the underlying image URLs do not return HTTP 200.
- **Broken code formatting**: expected terms from `$ISSUE_WORKSPACE/render_checklist.txt` are not present inside `<code>` tags in the live rendered HTML.
- **Broken task lists**: the number of rendered checkboxes does not match the markdown task list items.
- **Broken issue links**: if the issue body intentionally uses `#123` references, rerun the verifier with `--check-issue-links` and confirm they render as links.

If any rendering issues are found, fix them immediately by patching the issue body:

```bash
"${CLAUDE_SKILL_DIR}/scripts/publish-issue.py" edit \
  --repo smykla-skalski/harness \
  --issue "<number>" \
  --title-file "$ISSUE_WORKSPACE/title.txt" \
  --body-file "$ISSUE_WORKSPACE/body_fixed.md"
```

Then verify again.

Report the issue URL to the user when everything checks out.

## Shell safety

Never pass markdown containing backticks through shell string interpolation. The shell treats backtick-wrapped text as command substitution and silently corrupts the output. This is the single most common failure mode.

```bash
# Good - --body-file bypasses shell entirely
gh issue create --title "Fix the bug" --body-file "$ISSUE_WORKSPACE/body.md"

# Bad - shell expands backticks as commands
gh issue create --body "some `code` here"
```

Always use `--body-file <path>` for both `gh issue create` and `gh issue edit` to prevent shell expansion of backticks in the markdown content.

<example>
Input: "the guard-bash hook lets kubectl through when it's inside a pipe"

Output:
- Title: `guard-bash` fails to block `kubectl` inside pipe chains
- Labels: `kind/bug`, `area/api`
- Body:

## What happened

`guard-bash` only checks the first command in a pipeline. Running `echo ns | kubectl get pods -n -` bypasses the binary deny list because the hook splits on whitespace and inspects `argv[0]` of the full command string, missing piped commands.

## Expected behavior

`guard-bash` blocks any denied binary (`kubectl`, `helm`, `docker`, etc.) regardless of position in a pipe chain or subshell.

## Task list

- [ ] Update `guard-bash` pipe detection in `rules.rs` to scan all pipeline segments
- [ ] Add integration test covering `cmd | kubectl`, `$(kubectl ...)`, and backtick subshell forms
- [ ] Verify existing tests still pass after the change
</example>

<example>
Input: "add a --timeout flag to suite:run so long tests don't hang forever"

Output:
- Title: Add `--timeout` flag to `suite:run`
- Labels: `kind/enhancement`, `area/api`
- Body:

## Problem

When a test hangs (container pull stall, deadlocked CP), `suite:run` waits indefinitely. The only recovery is manual Ctrl-C, which skips the verdict phase and leaves the run in an incomplete state.

## Proposed solution

Add `--timeout <duration>` flag to `suite:run`. When the timeout expires, transition the run to the `verdict` phase with a `timeout` failure reason. Default to no timeout for backward compatibility.

## Task list

- [ ] Add `--timeout` flag to the `suite:run` CLI definition in `src/cli.rs`
- [ ] Wire timeout into the runner state machine in `workflow/runner.rs`
- [ ] Emit a structured timeout event so reports show the elapsed duration
- [ ] Add integration test with a short timeout and a deliberately slow test fixture
- [ ] Document the flag in the suite:run skill
</example>

<example>
Input: "the README doesn't mention how to run integration tests separately from unit tests"

Output:
- Title: Document integration vs unit test commands in README
- Labels: `kind/documentation`, `area/docs`
- Body:

## Context

The README shows `mise run test` for running tests but doesn't explain that integration tests and unit tests are separate targets. New contributors run the full suite and hit slow integration tests when they only wanted fast unit feedback.

## Scope

README testing section only. The `CLAUDE.md` already documents this - the gap is in the contributor-facing README.

## Task list

- [ ] Add `mise run test:unit` and `mise run test:slow` commands to the README testing section
- [ ] Explain that integration tests run single-threaded and why (`--test-threads=1` for env safety)
- [ ] Add a note about `cargo test --lib cli::tests` for running a specific module
</example>
