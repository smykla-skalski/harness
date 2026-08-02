# Delivery workflows

Choose one delivery mode before creating the editing worktree, then keep that mode until delivery or an explicitly approved reconciliation.

## Contents

- Select the mode
- Shared contract
- Signing backends
- `replay`
- `pr`
- Large features and PR series
- Prepare and publish
- Ready and merge
- Close out
- Realign
- Cleanup
- `pr with review`
- The loop
- Reviewer variants
- Adding a reviewer variant
- Working alongside other sessions

## Select the mode

- `pr` is the default: base the work on `upstream/main`, publish a dedicated branch, open the PR ready for review, wait for the user to merge, and align local state after the merge. No reviewer loop runs, and the PR is never a draft.
- `pr with review` is `pr` plus one reviewer loop. Use it when the user asks for a review or names a reviewer. The PR opens as a draft and becomes ready only after that reviewer reports a clean pass.
- `replay` delivers committed work directly into current local `main` without publishing a branch. Use it only when the user explicitly requests it or explicitly confirms the agent's proposal for a small task.
- Version bumps, documentation changes, and Git-history maintenance may qualify for `replay`, but scope and integration risk determine smallness. Explain the classification before asking for confirmation.
- Treat an explicit user request for `replay`, or for a review, as confirmation of that mode. If neither applies, use `pr`.
- Record the selected mode in substantial `.bart` implementation plans and handoffs, and name the reviewer with it, for example `pr with review (copilot)`.
- A mode may change before replay or publication. Changing to `replay` still needs explicit confirmation and a rebase onto local `main`. Changing mode after replay or publication needs explicit user direction and a reconciliation plan.
- Adding a review to an already published `pr` is the one exception. Convert the PR back to a draft with `gh pr ready --undo`, run the loop, and mark it ready again when it clears.

## Shared contract

1. Use one dedicated session worktree and one reused build, test, and runtime lane. Keep both available until session end or explicit cleanup.
2. Inspect current state and real call sites before editing. Work in small test, implement, and verify chunks.
3. Run focused tests and the smallest owning `mise` check task for every component or crate the change touched. Do not require `mise run check:full` or validate untouched surfaces. Docs, helper scripts, and files outside an app or codebase need no unrelated app build.
4. Allow unrelated dirty files temporarily only when they remain outside the task's explicit paths. Require a clean worktree before rebase or delivery, and deliver committed state only.
5. Commit explicit paths with `git commit -sS -- <paths>`. For new files, first use `git add -N -- <new-paths>`. Never use broad staging, `git commit -a`, or interactive commit selection.
6. Verify every commit with `git log --show-signature -1` and require the exact `Signed-off-by: Bart Smykla <bartek@smykla.com>` trailer.
7. Evaluate semver for every change, but change a version only with explicit user approval. Keep an approved required bump in the same delivery, and treat a standalone bump as its own confirmed `replay` task.

### Signing backends

- macOS agent sessions use the configured 1Password SSH signer. Stop for the user if it is unavailable or locked.
- Linux sessions provisioned by Smycracker use only its host-wide Git signing service, agent socket at `/run/smycracker-git-signing/agent.sock`, managed public key at `/etc/smycracker/git-signing/key.pub`, signing wrapper at `/usr/local/bin/smycracker-git-signing-ssh-keygen`, and doctor at `/usr/local/bin/smycracker-git-signing-doctor`. The wrapper selects the socket without inherited Orca or shell environment. Run the doctor before the first commit on a host.
- Before any provider change, Smycracker's controller preflight must verify GitHub login `bartsmykla` and the exact public key's SSH signing registration. Stop for the user if that preflight or the host doctor fails.
- Smycracker owns key creation, GitHub registration, private-key custody, loading, rotation, and revocation. Agents must never copy, export, replace, register, or revoke signing material.
- The Smycracker signing key is dedicated to signing and remains registered on GitHub account `bartsmykla` across ordinary teardown and host replacement. Before planned rotation, push and verify every outstanding commit signed by the old key. Git authentication and SSH host identities are separate trust purposes.
- On another Linux host, stop unless the user has explicitly approved a different signer whose public key is already registered on Bart's GitHub account.
- On every platform, stop if the authorized signer is absent, misconfigured, or fails verification. Never disable signing or substitute a key.

## `replay`

1. Use current local `main` as the worktree's base and integration target.
2. Finish and commit the task in the session worktree. Immediately before delivery, rebase the unpublished task range once onto current local `main`, resolve conflicts in the worktree, and rerun affected validation when the rebase materially changes the result.
3. Verify a clean worktree, the exact task range, every signature, and every sign-off.
4. From a clean local-`main` checkout, fast-forward local `main` to the verified worktree tip with `git merge --ff-only <session-branch>`. If it cannot fast-forward, reconcile in the worktree. Never cherry-pick replacement commits or resolve conflicts on `main`.
5. Do not push the session branch or local `main` unless the user separately requests it, and do not rerun validation on `main` merely because the fast-forward succeeded.
6. Finish only when local `main` and the session worktree branch point to the same commit and both checkouts are clean. Keep the worktree and lane available, and report any intentional difference from `upstream/main`.

## `pr`

### Large features and PR series

When a feature is expected to exceed about 5,000 reviewable changed lines, record an ordered PR-series plan before implementation. Treat 5,000 lines as a soft per-PR ceiling, never a quota, hard product limit, or reason to pad a smaller coherent slice. The budget applies in both PR modes, since it exists to keep a diff reviewable rather than to feed one particular reviewer.

1. Find the merge base of the intended PR base and proposed branch head, then compute the proposed PR diff from that merge base to the branch head. Count additions plus deletions in text files eligible for GitHub Copilot code review under its [documented excluded-file rules](https://docs.github.com/en/copilot/reference/review-excluded-files), which serve as the yardstick whether or not a reviewer runs, then subtract any generated, vendored, lockfile, snapshot, or other explicitly mechanical lines that remain in that eligible set. Use the resulting authored, eligible text volume for the approximately 5,000-line budget. Report the complete diff, budget count, subtracted mechanical volume, and binary changes separately. Never classify authored work as mechanical to hide an oversized diff, and never separate required derived output from its source.
2. Record each planned PR's outcome, predecessor, owned behavior and surfaces, estimated reviewable lines, planned overlap, validation, non-goals, and status.
3. Give each slice one durable outcome and leave the repository buildable, tested, and operationally safe when it merges. Include the tests, documentation, migrations, compatibility behavior, cleanup, and approved version change required by that outcome. No test or runtime path may depend on an unmerged future PR.
4. Use a foundation slice only when it establishes a stable, tested, independently useful boundary. Forbid dormant scaffolding, placeholders, half-exposed behavior, temporary review-only adapters, deferred known fixes, and other work planned for replacement.
5. Let later slices consume or extend a stable earlier contract, but never knowingly repair, replace, rename, remove, or substantially redesign it. Combine, reorder, or redesign the boundary before publication when the plan predicts such rework. Judge overlap by behavior rather than filenames: small additive integration in the same file is valid, but each behavior, migration, and schema transition needs one owning PR.
6. Obtain explicit user approval for an operationally necessary staged transition such as expand, migrate, and contract. Record every production-safe intermediate state and planned removal before implementation. Staged rollout needs do not justify ordinary implementation churn.
7. Deliver dependent or semantically overlapping slices serially. Complete the mode's review gate, user merge, and normal closeout before implementing the next slice from current `upstream/main`. Read-only planning may continue while waiting.
8. Run slices in parallel only as separate agent sessions, each with its own worktree and lane, and only when they share no code contract, migration, runtime dependency, or semantic ownership and remain correct and mergeable in either order.
9. Give every slice its own dedicated branch, its own run through the mode's gate, and its own terminal state. Within one session, reuse that session's worktree and build, test, and runtime lane across serial slices.
10. Recalculate the review budget before publication, and again before the first review request when the mode has a reviewer. Reslice when a sound boundary exists. When the smallest self-contained slice still exceeds the budget, stop for explicit user approval and record why an artificial split would be worse. Do not add an automated size gate.
11. After each merge, record the exact merged contract and commit, then reassess the remaining boundaries, estimates, overlap, and validation before implementation continues.
12. Use the final slice to prove the complete acceptance path and finish only whole-feature documentation, versioning, and integration not required by an earlier outcome. Never use it to repair an earlier slice or defer that slice's obligations. A closed-unmerged prerequisite blocks dependent work, and the feature is complete only after every planned slice merges, required validation and cleanup finish, and local `main`, `upstream/main`, and the reusable worktree align.

### Prepare and publish

1. Fetch and prune `upstream`, then require a clean `local main == upstream/main`. Fast-forward clean local `main` if it is behind `upstream/main`. Stop for direction if local `main` is ahead or diverged.
2. Create the session worktree and dedicated branch from `upstream/main`, and leave local `main` untouched until post-merge closeout.
3. Rebase the completed branch onto current `upstream/main` before its first push, resolve conflicts in the worktree, run affected validation, and verify the signed task range.
4. Push the dedicated branch and open the PR: ready for review in `pr`, a draft in `pr with review`. The merge squashes the branch into one commit, so add signed fix commits instead of rewriting history. Use `--force-with-lease` only for an unavoidable rebase onto `upstream/main`, after verifying the expected remote tip. Never plain-force or rewrite a shared branch.
5. Include every approved required version bump in the delivered branch.

The PR title becomes the commit title on `main`, so write it as a commit message: `{type}({scope}): {message}`, 50 characters or fewer. GitHub appends ` (#<number>)`.

Use only this PR-body shape:

```markdown
## Motivation
<Two or three direct sentences stating the prior problem and why it matters.>

## Implementation
- <Three to six outcome-oriented one-sentence bullets, with material validation in the final bullet.>

Closes #<issue>
```

Use a factual technical tone and describe outcomes, not files or chronology. Add no other sections, checklists, or boilerplate, and keep each paragraph or bullet on one physical line.

The closing line is optional. Add it only when the task actually worked on a real issue that this PR finishes. Confirm the issue exists and matches the change with `gh issue view <issue>` before writing the line, and never guess or invent a number. Omit it when no such issue exists, and mention an issue this PR only advances as plain `#<issue>` text inside a bullet so the merge leaves it open.

### Ready and merge

1. In `pr`, the gate is an accurate PR body in the shape above, affected validation run on the delivered tree, and zero unresolved conversations. The PR is already ready for review, so publication and this gate are the same step.
2. In `pr with review`, add a current-tree clean pass from the configured reviewer, then mark the PR ready with `gh pr ready <PR_NUMBER>`.
3. Do not add GitHub Actions checks to a PR. Never poll `gh pr checks`, `gh run list`, or the status-check API, never wait on a workflow, and never report a missing, disabled, or pending check as a blocker. Delivery is gated on the mode's own gate and the user's merge, and a run that goes hunting for checks stalls the handoff over state that does not gate anything.
4. Notify the user once the gate passes and monitor until the user merges or closes the PR. Never merge the PR as the agent.

### Close out

This repository allows squash merges only. The session branch collapses into one new commit on `upstream/main`, so its own commits never reach `main` and the branch can never fast-forward onto it. Closeout realigns local state instead of integrating anything. The exception is a worktree and branch that existed only to deliver one standalone, non-umbrella issue or task, where closeout removes them and their build caches instead. A worktree kept alive for an umbrella's remaining slices or another follow-up in the same PR series always takes the realign path. When it is unclear whether more work is coming, default to realign and ask before removing anything.

Confirm the PR merged before either path, then check that `<main-checkout>` is on `main`, `<worktree>` is on `<session-branch>`, both are clean, and local `main` carries no unpublished `replay` commits. Reconcile those first, as described below.

#### Realign

```bash
git -C <main-checkout> fetch --prune upstream
git -C <main-checkout> merge --ff-only upstream/main
git -C <worktree> reset --hard main
git -C <worktree> branch --unset-upstream <session-branch> || true  # no-op on a rerun
```

That is the whole realign path. The squash commit on `main` already carries every change the `reset --hard` discards. Do not rerun validation on `main`, and keep the worktree and lane available.

It deliberately skips three things:

- No signature check on the merge. GitHub creates the squash commit and signs it with its own key, so a local signature check cannot verify it. That is expected. The signing contract covers commits the agent writes.
- No remote branch deletion. GitHub deletes it on merge and `fetch --prune` drops the tracking ref.
- No head comparison. A merged PR is proof enough.

#### Cleanup

Reclaim this session's two build caches first, because `git worktree remove` deletes the only name that maps the shared lane back to this session. `mise run clean:lanes` reclaims neither: it covers `xcode-derived-lanes/` and always keeps the current worktree.

- `<worktree>/target` - direct `cargo` and `cargo nextest` output.
- `<main-checkout>/target/dev/wt-<worktree-name>-<hash>-v<format>` - everything from `scripts/cargo-local.sh`, which every `mise run test:*` task uses. Sits outside the worktree and is usually the larger.

Every other session holds its own `target/dev/wt-*` lane, so ask `cargo-local.sh` for this one rather than matching a name by eye, and clear any target-dir override first, since the script honours one and would otherwise answer with the redirect. A lease is named `<segment>-<pid>` and holds that PID inside, and a running build's lane must survive, so the delete stands down while one of those PIDs is alive. Mirror `segment_is_leased` in `clean-build-caches.sh`: require the filename to match the PID it carries, and count a PID that fails `kill -0` but still appears in `ps` as alive, since a build owned by another user cannot be signalled. Judging by the file alone instead would let a lease from a crashed build block reclamation for good, stranding the lane just as surely as never running this step.

```bash
# assumes: PR merged, <worktree> clean
lane=$(env -u CARGO_TARGET_DIR -u HARNESS_CARGO_TARGET_DIR \
  "<worktree>/scripts/cargo-local.sh" --print-target-dir)
held=$(for f in "<main-checkout>"/target/.cargo-local/leases/"$(basename "$lane")"-*; do
  pid=$(cat "$f" 2>/dev/null) || continue
  [ "${f##*/}" = "$(basename "$lane")-$pid" ] || continue
  kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1 && echo held
done)
[ -z "$held" ] && rm -rf "<worktree>/target" "$lane"   # a running build keeps its lane
```

Then remove the worktree and the branch:

```bash
git -C <main-checkout> fetch --prune upstream
git -C <main-checkout> merge --ff-only upstream/main
git -C <main-checkout> worktree remove <worktree>
git -C <main-checkout> branch -D <session-branch>
```

Use `-D`, not `-d`: the squash commit means the local branch's commits are never an ancestor of `main`, so the safe delete refuses. Skip a separate remote delete. GitHub already removed the remote branch on merge, and `fetch --prune` already dropped the local tracking ref. Confirm with `git ls-remote --heads upstream <session-branch>` if in doubt.

When unpublished local `replay` commits sit on `main`, rebase and re-sign only that range onto merged `upstream/main`, preserve its sign-offs, and wait for the user to push. Never cherry-pick the squash commit on top of that range or reset those commits away. Stop for the user if any unpublished commit falls outside a stable, signed, signed-off replay range.

If the PR closes without merging, verify that state through GitHub, leave `main`, the branch, its tracking, the worktree, and the lane untouched, and record the task as undelivered. Abandonment or cleanup needs explicit user direction.

## `pr with review`

Everything in `pr` applies, with two differences. The PR opens as a draft, and it becomes ready only after the configured reviewer reports a clean pass on the current tree.

One reviewer per delivery. When the user asks for a review without naming a reviewer, use `copilot` and say so.

### The loop

These rules hold for every reviewer. The variant supplies the commands, the reading, and the definition of a clean pass.

1. Request the review immediately after the first push, then wait for a result whose reviewed commit carries the current tree. A review of an older tree does not count. A review still counts when the head SHA moved but the tree did not, as after a rebase or a commit-message or sign-off rewrite. Confirm with `git rev-parse <reviewed-sha>^{tree}` against `git rev-parse <head-sha>^{tree}`.
2. Implement every valid fix the findings and any unresolved conversation call for, run affected validation, commit the explicit paths with signing and sign-off, and push.
3. After each fix push, resolve only the conversations that push addressed. A fix needs no reply.
4. Answer an incorrect finding before resuming other work, then resolve the thread. Give the evidence, not the verdict: the command that proves it and the mechanism behind it. Write one or two plain sentences, and drop the polite filler, bullets, and trailing period. Never silently resolve a wrong finding, because a silent resolve reads as a real defect quietly ignored and leaves the next reader no record of why nothing changed.
5. Re-request and repeat without a fixed round limit until the variant's clean pass holds.
6. If the tree or the feedback changes, invalidate the prior result and resume the loop. Editing the PR title or body never invalidates a review, because the review covers the code change and not the metadata around it.
7. Escalate on the variant's own terms, and keep the PR a draft while blocked.

### Reviewer variants

- [`copilot`](pr-reviewers/copilot.md) - the only variant today.

### Adding a reviewer variant

Add one file under `pr-reviewers/`, link it in the list above, and answer these five questions there. Change nothing else about the mode.

1. The request command, and the re-request command when it differs.
2. Where the findings appear and how to read them, including any surface the obvious API call misses.
3. Triage rules specific to that reviewer.
4. What a clean pass means for it.
5. What counts as reviewer failure worth escalating rather than retrying.

Reviewers that are agents rather than GitHub bots use the same file shape and answer the same five questions.

## Working alongside other sessions

Several worktrees share one local `main`. Read real Git state before you move it: `git worktree list` shows what else is checked out and on which branch, and `git status` shows whether the main checkout is clean.

Fast-forwarding local `main` to `upstream/main` is convergent, so it stays correct no matter what else is running. Every other move of `main` can surprise another session, so require a clean main checkout, take the smallest step that delivers the work, and stop for the user when the repository does not look the way you expect.
