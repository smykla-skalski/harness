---
name: do
description: Implement a GitHub issue end to end with worktree isolation, test-first changes, explicit done-bar verification, and final push-and-close hygiene. Use when the user says "do", "implement", "work on", "pick up", "tackle", "close this issue", or provides a GitHub issue number or URL that should be implemented in this repository.
allowed-tools: Agent, Bash, Edit, Glob, Grep, Read, Write, Skill
---

# Implement GitHub issue

Implement a GitHub issue end to end for this repository: isolate the work in a dedicated worktree, use TDD, protect performance, verify a deterministic done bar, then rebase, merge, push, and close the issue.

## Philosophy

Build for the long term.

Every line you write will be maintained by humans and other agents for years. Shortcuts rot. Hacks compound. The correct fix today, even if it requires a larger refactor, is cheaper than a quick patch that leaves tech debt behind.

Treat that as a hard constraint, not a style preference.

## Hard constraints

1. **No shortcuts.** If the correct solution requires a real refactor, do the refactor instead of patching around the problem.
2. **No hacks.** Do not introduce TODO placeholders, warning suppressions, hidden incomplete paths, or cleanup debt you expect someone else to pay later.
3. **Long-term solutions only.** If the change will obviously need to be redone in a few months, keep digging until you find the version that will last.
4. **Performance is sacred.** Do not add avoidable allocations, synchronous work on async paths, unnecessary copies, or slower hot-path behavior. Measure or inspect carefully when the touched path is performance-sensitive.
5. **TDD is mandatory.** Write the failing test first, see it fail, implement the fix, and see it pass.
6. **Best practices are not optional.** Follow the repo conventions, language idioms, framework guidance, and documented patterns. If you are unsure, verify instead of guessing.
7. **No version bumps in worktrees.** Never modify `Cargo.toml` version, run `version.sh`, or touch any version surface inside a feature worktree. Multiple agents work in parallel on separate worktrees - version bumps in worktrees cause merge conflicts when branches land. The version bump happens on `main` after merge, gated behind user approval (see step 10a).

## Workflow

### 0. Parse input

Extract the GitHub issue from `$ARGUMENTS`. Accept:

- issue number: `42`, `#42`
- issue URL: `https://github.com/smykla-skalski/harness/issues/42`
- shorthand: `smykla-skalski/harness#42`

If the input is ambiguous or missing, ask the user for the number or URL before proceeding.

### 1. Read the issue

```bash
gh issue view <number> --repo smykla-skalski/harness --json title,body,labels,assignees,comments
```

Read the full issue, including comments. Understand what is being asked, why it matters, and what the acceptance criteria are. If the issue points at related issues or PRs, read those too.

### 2. Analyze and research

Before writing code, understand the problem space.

1. **Read the relevant code.** Use `Glob`, `Grep`, and `Read` to find the affected modules, their tests, and their callers. Understand the current behavior before changing it.
2. **Consult relevant installed skills.** If the change touches SwiftUI, concurrency, testing, SwiftData, or other specialized areas, load the strongest matching installed skills before deciding on the implementation. In this repo that commonly means `swiftui-pro`, `swift-concurrency`, `swift-testing-expert`, `swift-testing-pro`, and `swiftdata-pro` when those topics apply.
3. **Research unknowns.** If the implementation depends on framework behavior, API details, or patterns you are not confident about, verify them in documentation or primary sources.
4. **Identify performance-sensitive paths.** Map hot paths, frequent code paths, main-thread work, and any potentially expensive logic introduced by the change.
5. **Delegate only when explicitly wanted.** If the runtime supports parallel agents and the user explicitly asked for parallel agent work, you may delegate bounded research tasks. Otherwise do the analysis yourself.

If anything remains ambiguous after the code read, stop and ask the user before implementation.

### 3. Define the done bar

Before implementation, write down exactly what "done" means. The done bar must be deterministic and machine-verifiable.

It should cover:

- **Functional criteria**: exact tests or assertions that prove the behavior
- **Quality criteria**: formatting clean, lint clean, no new suppressions, no new warnings
- **Performance criteria**: a benchmark, audit, or concrete non-regression check when the change touches a sensitive path
- **UI criteria**: targeted UI tests and timing expectations when the change touches UI
- **Integration criteria**: repo-native test suites or commands that must stay green

Share the done bar in the conversation before implementation. If the scope or acceptance criteria are high-risk or unclear, wait for the user's confirmation before moving on.

Example:

```text
Done bar for #42:
1. `cargo test --lib workflow::runner::tests::timeout_triggers_verdict -- --exact` passes
2. `cargo test --lib workflow::runner::tests::timeout_preserves_state -- --exact` passes
3. `mise run test` reports zero failures
4. `mise run lint:fix` reports zero new warnings
5. `cargo clippy --lib` reports zero new warnings
6. No performance regression in the runner path
```

The task is not complete until every line in the done bar passes.

### 4. Create the worktree

Create an isolated worktree from local `main`. All implementation work happens there.

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
ISSUE_NUMBER="<parsed issue number>"
WORKTREE_NAME="do-${ISSUE_NUMBER}"
WORKTREE_PATH="$REPO_ROOT/.claude/worktrees/$WORKTREE_NAME"

git -C "$REPO_ROOT" worktree add -b "$WORKTREE_NAME" "$WORKTREE_PATH" main
cd "$WORKTREE_PATH"
mise trust
git log --oneline -1
git status --short
```

If the branch already exists, stop and decide whether to reuse it or pick a different deterministic name. Do not silently clobber an existing worktree.

### 5. Implement with TDD

For every logical change, follow this exact sequence.

#### 5a. Write the failing test first

Write the smallest deterministic test that captures the expected behavior, then run it and confirm it fails.

Rust example:

```bash
cargo test --lib <module>::tests::<test_name> -- --exact
```

Swift example:

```bash
xcodebuild test -scheme HarnessMonitor -only-testing <TestTarget>/<TestClass>/<testMethod>
```

If the test already passes, either the feature already exists or your test is not specific enough. Investigate before writing implementation code.

#### 5b. Implement the minimum code to pass the test

Change only what the test demands. Avoid unrelated cleanup unless it is required for the correct fix.

#### 5c. Re-run the same test

The exact test that failed must now pass.

#### 5d. Refactor while the test is green

If the implementation introduced duplication or awkward structure, refactor immediately and re-run the same targeted test.

#### 5e. Run the broader verification lane

After each logical unit of work, run the repo-native validation commands that match the change. The default Rust lane is:

```bash
mise run test
mise run lint:fix
cargo clippy --lib
```

If the change only touches a narrow area with an expensive test surface, start with the smallest targeted command that proves correctness, then widen to the done-bar lane before claiming completion.

#### 5f. Commit

Commit after each logical phase using the repo's conventional commit format:

```text
{type}({scope}): {message}
```

Each commit should be atomic and independently understandable.

### 6. UI changes: keep UI tests fast

If the implementation touches UI, write targeted UI tests that stay fast and deterministic.

Requirements:

- suppress avoidable animation noise during tests
- prefer `.firstMatch` when it avoids wide accessibility walks
- use stable state markers and deterministic navigation
- keep each test focused on one behavior
- aim for under 2 seconds per test case when practical

For `apps/harness-monitor-macos`, follow the repo rules:

- use the smallest targeted build or test command instead of the full UI suite
- keep the isolated `Harness Monitor UI Testing` host (`io.harnessmonitor.app.ui-testing`)
- keep the `-ApplePersistenceIgnoreState YES` launch argument in place
- if you add, remove, or rename Swift files, update `HarnessMonitor.xcodeproj` in the same change

### 7. Verify performance

Before calling the implementation done, verify that the change did not degrade the affected path.

For Rust changes:

- run existing benchmarks if the path already has them
- inspect hot paths for unnecessary allocations, copies, or blocking work
- verify async changes do not add sync choke points

For Swift and SwiftUI changes:

- avoid formatter allocation in view bodies
- avoid `repeatForever` on always-visible views unless it is clearly intentional
- keep state flow stable and avoid avoidable re-render loops
- run the strongest installed SwiftUI performance skill or audit flow when the change is performance-sensitive

For concurrency changes:

- verify actor isolation and Sendable correctness
- avoid unnecessary main-actor hops
- make data-race safety explicit rather than assumed

### 8. Verify the done bar

Run every command or check from the done bar and print the result explicitly.

Example:

```text
Done bar verification:
[PASS] 1. timeout_triggers_verdict test passes
[PASS] 2. timeout_preserves_state test passes
[PASS] 3. mise run test - zero failures
[PASS] 4. mise run lint:fix - zero new warnings
[PASS] 5. cargo clippy --lib - zero new warnings
[PASS] 6. No performance regression
```

Do not mark the task complete until every line is `PASS`.

If one item fails, fix that failure and re-run the relevant verification. If repeated fix-and-verify cycles stall, stop and ask the user how to proceed instead of bluffing through it.

### 9. Rebase on the latest `main`

Bring the worktree branch on top of the current local `main` before finalizing.

```bash
git fetch origin main 2>/dev/null || true
git rebase main
```

If conflicts appear:

1. read both sides and understand the intent
2. resolve to the correct combined result, not simply "ours" or "theirs"
3. run the smallest relevant tests after each resolved file or conflict cluster

After the rebase, re-run the done-bar verification.

### 10. Verify the commits on `main`

Move back to the main checkout, fast-forward `main`, and verify the commit list before pushing.

```bash
BRANCH="$(git -C "$WORKTREE_PATH" branch --show-current)"
cd "$REPO_ROOT"
git status --short
git checkout main
git merge --ff-only "$BRANCH"
git log --oneline -10
```

If the main checkout has unrelated local changes, stop and ask the user before merging or pushing. Do not mix the issue implementation with dirty state you did not create.

Show the resulting commit list and done-bar results to the user before pushing and closing the issue. If the user asks to hold or revise, go back to the worktree, make the requested changes, and repeat the rebase and merge verification.

If the user explicitly says not to push or not to close yet, stop at the last approved point and report the current state clearly.

### 10a. Version bump (on main, after merge)

After the commits land on `main`, evaluate whether the change warrants a version bump. Read the semver policy in CLAUDE.md and determine the appropriate bump level (major, minor, or patch).

Use `user approval prompt` to present the recommendation:

- Question: "The changes from #`<number>` are on `main`. I'd classify this as a `<level>` bump (`<current>` -> `<proposed>`). Want me to bump the version?"
- Option 1: **Bump version** - "Run `./scripts/version.sh set <proposed>` and commit"
- Option 2: **Skip** - "I'll handle versioning separately"
- Option 3: **Different version** - "I want a different version number"

If the user picks "Bump version":

```bash
./scripts/version.sh set <proposed>
mise run version:check
git add -A
git commit -m "chore(version): bump to <proposed>"
```

If they pick "Different version", ask for the number, then run the same commands with their value. If they pick "Skip", move on without touching any version surfaces.

This step exists because worktrees must never contain version bumps - parallel agents would create conflicting changes across worktrees. The bump always happens on `main` after the feature work has landed.

### 11. Clean up the worktree

After the user confirms the commits on `main`, remove the worktree and branch.

```bash
git worktree remove "$WORKTREE_PATH"
git branch -d "$BRANCH"
git worktree list
git branch --list "do-*"
```

### 12. Push upstream

```bash
git push upstream main
git log --oneline upstream/main -3
```

Only proceed if the user has not asked you to hold local-only changes.

### 13. Close the issue

Close the GitHub issue with a concise comment pointing at the implementing commit.

```bash
COMMIT_HASH="$(git rev-parse --short HEAD)"

gh issue close <number> --repo smykla-skalski/harness \
  --comment "Implemented in #${COMMIT_HASH}"
```

If the work spans multiple commits, reference the final one on `main`.

## Uncertainty protocol

If you hit ambiguous requirements, unfamiliar behavior, multiple valid approaches with meaningful tradeoffs, unclear performance implications, or scope uncertainty, stop and ask the user before guessing.

Present the best option first, include the tradeoff, and proceed only after the ambiguity is resolved.

## Examples

<example>
Input: `$do 42` where issue `#42` is "Add --timeout flag to suite:run"

Done bar:
1. `cargo test --lib workflow::runner::tests::timeout_triggers_verdict -- --exact` passes
2. `cargo test --lib workflow::runner::tests::timeout_preserves_partial_state -- --exact` passes
3. `cargo test --lib cli::tests::timeout_flag_parses -- --exact` passes
4. `mise run test` reports zero failures
5. `cargo clippy --lib` reports zero new warnings

Workflow: read issue, read `workflow/runner.rs` and `cli.rs`, define the done bar, create worktree `do-42`, write the failing timeout transition test, implement the runner change, add the CLI flag, run the full lane, verify the done bar, rebase, merge, push, and close with `Implemented in #abc1234`.
</example>

<example>
Input: `$do 58` where issue `#58` is "Sidebar session card shows stale title after rename"

Done bar:
1. UI test `SidebarTests/testSessionTitleUpdatesAfterRename` passes in under 2 seconds
2. `mise run test` reports zero failures
3. No new avoidable view-body allocations were introduced
4. No unnecessary always-visible animation loops were introduced

Workflow: read issue, consult the installed SwiftUI and concurrency skills, trace the sidebar data flow, define the done bar, create worktree `do-58`, write the failing UI test, fix the observation path, verify the test stays fast, run the full lane, verify the done bar, rebase, merge, push, and close with `Implemented in #def5678`.
</example>
