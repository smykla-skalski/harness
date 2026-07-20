# Delivery workflows

Choose one delivery mode before creating the editing worktree, then keep that mode until delivery or an explicitly approved reconciliation.

## Select the mode

- `pr` is the default: base the work on `upstream/main`, publish a dedicated branch, complete review, wait for the user to merge, and align local state after the merge.
- `replay` delivers committed work directly into current local `main` without publishing a branch. Use it only when the user explicitly requests it or explicitly confirms the agent's proposal for a small task.
- Version bumps, documentation changes, and Git-history maintenance may qualify for `replay`, but scope and integration risk determine smallness. Explain the classification before asking for confirmation.
- Treat an explicit user request for `replay` as confirmation. If neither condition applies, use `pr`.
- Record the selected mode in substantial `.bart` implementation plans and handoffs.
- A mode may change before replay or publication. Changing to `replay` still needs explicit confirmation and a rebase onto local `main`; changing mode after replay or publication needs explicit user direction and a reconciliation plan.

## Shared contract

1. Use one dedicated session worktree and one reused build, test, and runtime lane. Keep both available until session end or explicit cleanup.
2. Inspect current state and real call sites before editing. Work in small test, implement, and verify chunks.
3. Run the smallest validation that proves each affected surface. Docs, helper scripts, and files outside an app or codebase need no unrelated app build.
4. Allow unrelated dirty files temporarily only when they remain outside the task's explicit paths. Require a clean worktree before rebase or delivery, and deliver committed state only.
5. Commit explicit paths with `git commit -sS -- <paths>`. For new files, first use `git add -N -- <new-paths>`; never use broad staging, `git commit -a`, or interactive commit selection.
6. Verify every commit with `git log --show-signature -1` and require the exact `Signed-off-by: Bart Smykla <bartek@smykla.com>` trailer.
7. Evaluate semver for every change, but change a version only with explicit user approval. Keep an approved required bump in the same delivery; treat a standalone bump as its own confirmed `replay` task.

### Signing backends

- macOS agent sessions use the configured 1Password SSH signer. Stop for the user if it is unavailable or locked.
- Linux sessions provisioned by Smycracker use only its host-wide Git signing service, agent socket at `/run/smycracker-git-signing/agent.sock`, managed public key at `/etc/smycracker/git-signing/key.pub`, signing wrapper at `/usr/local/bin/smycracker-git-signing-ssh-keygen`, and doctor at `/usr/local/bin/smycracker-git-signing-doctor`. The wrapper selects the socket without inherited Orca or shell environment; run the doctor before the first commit on a host.
- Before any provider change, Smycracker's controller preflight must verify GitHub login `bartsmykla` and the exact public key's SSH signing registration. Stop for the user if that preflight or the host doctor fails.
- Smycracker owns key creation, GitHub registration, private-key custody, loading, rotation, and revocation. Agents must never copy, export, replace, register, or revoke signing material.
- The Smycracker signing key is dedicated to signing and remains registered on GitHub account `bartsmykla` across ordinary teardown and host replacement. Before planned rotation, push and verify every outstanding commit signed by the old key. Git authentication and SSH host identities are separate trust purposes.
- On another Linux host, stop unless the user has explicitly approved a different signer whose public key is already registered on Bart's GitHub account.
- On every platform, stop if the authorized signer is absent, misconfigured, or fails verification. Never disable signing or substitute a key.

## `replay`

1. Use current local `main` as the worktree's base and integration target.
2. Finish and commit the task in the session worktree. Immediately before delivery, rebase the unpublished task range once onto current local `main`, resolve conflicts in the worktree, and rerun affected validation when the rebase materially changes the result.
3. Verify a clean worktree, the exact task range, every signature, and every sign-off.
4. From a clean local-`main` checkout, fast-forward local `main` to the verified worktree tip with `git merge --ff-only <session-branch>`. If it cannot fast-forward, reconcile in the worktree; never cherry-pick replacement commits or resolve conflicts on `main`.
5. Do not push the session branch or local `main` unless the user separately requests it, and do not rerun validation on `main` merely because the fast-forward succeeded.
6. Finish only when local `main` and the session worktree branch point to the same commit and both checkouts are clean. Keep the worktree and lane available, and report any intentional difference from `upstream/main`.

## `pr`

### Large features and PR series

When a feature is expected to exceed about 5,000 Copilot-reviewable changed lines, record an ordered PR-series plan before implementation. Treat 5,000 lines as a soft per-PR ceiling, never a quota, hard product limit, or reason to pad a smaller coherent slice.

1. Find the merge base of the intended PR base and proposed branch head, then compute the proposed PR diff from that merge base to the branch head. Count additions plus deletions in text files eligible for GitHub Copilot code review under its [documented excluded-file rules](https://docs.github.com/en/copilot/reference/review-excluded-files), then subtract any generated, vendored, lockfile, snapshot, or other explicitly mechanical lines that remain in that eligible set. Use the resulting authored, Copilot-eligible text volume for the approximately 5,000-line budget. Report the complete diff, budget count, subtracted mechanical volume, and binary changes separately; never classify authored work as mechanical to hide an oversized diff or separate required derived output from its source.
2. Record each planned PR's outcome, predecessor, owned behavior and surfaces, estimated reviewable lines, planned overlap, validation, non-goals, and status.
3. Give each slice one durable outcome and leave the repository buildable, tested, and operationally safe when it merges. Include the tests, documentation, migrations, compatibility behavior, cleanup, and approved version change required by that outcome; no test or runtime path may depend on an unmerged future PR.
4. Use a foundation slice only when it establishes a stable, tested, independently useful boundary. Forbid dormant scaffolding, placeholders, half-exposed behavior, temporary review-only adapters, deferred known fixes, and other work planned for replacement.
5. Let later slices consume or extend a stable earlier contract, but never knowingly repair, replace, rename, remove, or substantially redesign it. Combine, reorder, or redesign the boundary before publication when the plan predicts such rework. Judge overlap by behavior rather than filenames: small additive integration in the same file is valid, but each behavior, migration, and schema transition needs one owning PR.
6. Obtain explicit user approval for an operationally necessary staged transition such as expand, migrate, and contract. Record every production-safe intermediate state and planned removal before implementation; staged rollout needs do not justify ordinary implementation churn.
7. Deliver dependent or semantically overlapping slices serially. Complete exact-head Copilot review, user merge, and normal closeout before implementing the next slice from current `upstream/main`; read-only planning may continue while waiting.
8. Run slices in parallel only as separate agent sessions, each with its own worktree and lane, and only when they share no code contract, migration, runtime dependency, or semantic ownership and remain correct and mergeable in either order.
9. Give every slice its own dedicated branch, complete PR review loop, and terminal state. Within one session, reuse that session's worktree and build, test, and runtime lane across serial slices.
10. Recalculate the review budget before publication and the first Copilot request. Reslice when a sound boundary exists; when the smallest self-contained slice still exceeds the budget, stop for explicit user approval and record why an artificial split would be worse. Do not add an automated size gate.
11. After each merge, record the exact merged contract and commit, then reassess the remaining boundaries, estimates, overlap, and validation before implementation continues.
12. Use the final slice to prove the complete acceptance path and finish only whole-feature documentation, versioning, and integration not required by an earlier outcome; never use it to repair an earlier slice or defer that slice's obligations. A closed-unmerged prerequisite blocks dependent work, and the feature is complete only after every planned slice merges, required validation and cleanup finish, and local `main`, `upstream/main`, and the reusable worktree align.

### Prepare and publish

1. Fetch and prune `upstream`, then require a clean `local main == upstream/main`. Fast-forward clean local `main` if it is behind `upstream/main`; stop for direction if local `main` is ahead or diverged.
2. Create the session worktree and dedicated branch from `upstream/main`, and leave local `main` untouched until post-merge closeout.
3. Rebase the completed branch onto current `upstream/main` before its first push, resolve conflicts in the worktree, run affected validation, and verify the signed task range.
4. Push the dedicated branch and open a draft PR. The merge squashes the branch into one commit, so add signed fix commits instead of rewriting history; use `--force-with-lease` only for an unavoidable rebase onto `upstream/main`, after verifying the expected remote tip. Never plain-force or rewrite a shared branch.
5. Include every approved required version bump in the reviewed branch.

The PR title becomes the commit title on `main`, so write it as a commit message: `{type}({scope}): {message}`, 50 characters or fewer. GitHub appends ` (#<number>)`.

Use only this PR-body shape:

```markdown
## Motivation
<Two or three direct sentences stating the prior problem and why it matters.>

## Implementation
- <Three to six outcome-oriented one-sentence bullets, with material validation in the final bullet.>
```

Use a factual technical tone and describe outcomes, not files or chronology. Add no other sections, checklists, or boilerplate, and keep each paragraph or bullet on one physical line.

### Copilot review loop

Immediately request Copilot review, and use the same command for every re-request:

```bash
gh api --method POST repos/smykla-skalski/harness/pulls/<PR_NUMBER>/requested_reviewers -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

1. Wait for a Copilot review whose reviewed commit is the exact current head; a review of an older head does not count.
2. Inspect every remark and unresolved conversation. Implement valid fixes, run affected validation, commit the explicit paths with signing and sign-off, and push.
3. After each fix push, resolve only the conversations that push addressed. A fix needs no reply.
4. Answer an incorrect finding before resuming other work, then resolve the thread. Give the evidence, not the verdict: the command that proves it and the mechanism behind it. Write one or two plain sentences, and drop the polite filler, bullets, and trailing period. Never silently resolve a wrong finding, because a silent resolve reads as a real defect quietly ignored and leaves the next reader no record of why nothing changed.
5. Re-request Copilot and repeat without a fixed round limit until it reviews the exact current head and reports no new comments.
6. If the head, PR body, feedback, or required checks change, invalidate the prior result and resume the loop. Escalate only a genuine impasse, a recurring already-addressed finding, or persistent Copilot or API failure; keep the PR draft while blocked.

### Ready and merge

1. Require an accurate two-section PR body, an exact-head Copilot review with no new comments, zero unresolved conversations, and green required checks.
2. Mark the PR ready for review only after every gate passes, notify the user, and monitor until the user merges or closes it. Never merge the PR as the agent.

### Close out

This repository allows squash merges only. The branch collapses into one new commit on `upstream/main`, so its commits never reach `main` and it can never fast-forward. Closeout realigns local state instead of integrating anything.

Confirm the PR merged, then check that `<main-checkout>` is on `main`, `<worktree>` is on `<session-branch>`, both are clean, and local `main` carries no unpublished `replay` commits (reconcile those first, as described below):

```bash
git -C <main-checkout> fetch --prune upstream
git -C <main-checkout> merge --ff-only upstream/main
git -C <worktree> reset --hard main
git -C <worktree> branch --unset-upstream <session-branch>
```

That is the whole closeout. The squash commit on `main` already carries every change the `reset --hard` discards. Do not rerun validation on `main`, and keep the worktree and lane available.

It deliberately skips three things:

- No signature check on the merge. GitHub creates the squash commit and signs it with its own key, so a local signature check cannot verify it. That is expected. The signing contract covers commits the agent writes.
- No remote branch deletion. GitHub deletes it on merge and `fetch --prune` drops the tracking ref.
- No head comparison. A merged PR is proof enough.

When unpublished local `replay` commits sit on `main`, rebase and re-sign only that range onto merged `upstream/main`, preserve its sign-offs, and wait for the user to push. Never cherry-pick the squash commit on top of that range or reset those commits away. Stop for the user if any unpublished commit falls outside a stable, signed, signed-off replay range.

If the PR closes without merging, verify that state through GitHub, leave `main`, the branch, its tracking, the worktree, and the lane untouched, and record the task as undelivered. Abandonment or cleanup needs explicit user direction.

## Working alongside other sessions

Several worktrees share one local `main`. Read real Git state before you move it: `git worktree list` shows what else is checked out and on which branch, and `git status` shows whether the main checkout is clean.

Fast-forwarding local `main` to `upstream/main` is convergent, so it stays correct no matter what else is running. Every other move of `main` can surprise another session, so require a clean main checkout, take the smallest step that delivers the work, and stop for the user when the repository does not look the way you expect.
