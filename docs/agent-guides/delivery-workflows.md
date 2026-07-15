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

1. Use current local `main` as the worktree's base and integration target. Before integration, confirm that no active PR reservation blocks replay.
2. Finish and commit the task in the session worktree. Immediately before delivery, rebase the unpublished task range once onto current local `main`, resolve conflicts in the worktree, and rerun affected validation when the rebase materially changes the result.
3. Verify a clean worktree, the exact task range, every signature, and every sign-off.
4. Acquire the shared integration lock, recheck that no PR reservation exists, and require the local `main` checkout to be clean.
5. From the local-main checkout, fast-forward local `main` to the verified worktree tip with `git merge --ff-only <session-branch>`. If it cannot fast-forward, release the lock and reconcile in the worktree; never cherry-pick replacement commits or resolve conflicts on `main`.
6. Release the integration lock. Do not push the session branch or local `main` unless the user separately requests it, and do not rerun validation on `main` merely because the fast-forward succeeded.
7. Finish only when local `main` and the session worktree branch point to the same commit and both checkouts are clean. Keep the worktree and lane available, and report any intentional difference from `upstream/main`.

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
9. Give every slice its own dedicated branch, reservation, complete PR review loop, and terminal state. Within one session, reuse that session's worktree and build, test, and runtime lane across serial slices.
10. Recalculate the review budget before publication and the first Copilot request. Reslice when a sound boundary exists; when the smallest self-contained slice still exceeds the budget, stop for explicit user approval and record why an artificial split would be worse. Do not add an automated size gate.
11. After each merge, record the exact merged contract and commit, then reassess the remaining boundaries, estimates, overlap, and validation before implementation continues.
12. Use the final slice to prove the complete acceptance path and finish only whole-feature documentation, versioning, and integration not required by an earlier outcome; never use it to repair an earlier slice or defer that slice's obligations. A closed-unmerged prerequisite blocks dependent work, and the feature is complete only after every planned slice merges, required validation and cleanup finish, and local `main`, `upstream/main`, and the reusable worktree align.

### Prepare and publish

1. Fetch and prune `upstream`, then require a clean `local main == upstream/main`. Fast-forward clean local `main` if it is behind `upstream/main`; stop for direction if local `main` is ahead or diverged.
2. Create the session worktree and dedicated branch from `upstream/main`, create its delivery reservation, and leave local `main` untouched until post-merge closeout.
3. Rebase the completed branch onto current `upstream/main` before its first push, resolve conflicts in the worktree, run affected validation, and verify the signed task range.
4. Push the dedicated branch and open a draft PR. After publication, prefer additive signed fix commits; use `--force-with-lease` only when an unavoidable rebase rewrites this session-owned branch after its expected remote tip has been verified. Never plain-force or rewrite a shared branch.
5. Include every approved required version bump in the reviewed branch.

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
3. After each fix push, silently resolve only the conversations addressed by that push. Post no replies. Resolve an incorrect, stale, or duplicate finding only after evidence proves that no change is needed.
4. Re-request Copilot and repeat without a fixed round limit until it reviews the exact current head and reports no new comments.
5. If the head, PR body, feedback, or required checks change, invalidate the prior result and resume the loop. Escalate only a genuine impasse, a recurring already-addressed finding, or persistent Copilot or API failure; keep the PR draft while blocked.

### Ready, merge, and close out

1. Require an accurate two-section PR body, an exact-head Copilot review with no new comments, zero unresolved conversations, and green required checks.
2. Mark the PR ready for review only after every gate passes, notify the user, and monitor until the user merges or closes it. Never merge the PR as the agent.
3. After a user merge, acquire the integration lock, fetch and prune `upstream`, verify the recorded PR head against the worktree's old head, and require both local checkouts to be clean. Treat unpublished local commits as reconcilable only when they are a stable, signed, signed-off range owned by completed `replay` work; stop for the user if any unpublished commit falls outside that range or fails a precondition.
4. Fast-forward clean local `main` to `upstream/main` when no local replay range exists. Otherwise rebase and re-sign only that range onto merged `upstream/main`, preserve its sign-offs, and wait for the user to push the resulting fast-forward; never cherry-pick the PR commit on top of the local range or reset those commits away. Do not rerun validation on `main` merely because reconciliation succeeded.
5. Fetch and prune after any user push, require `local main == upstream/main`, then detach the session worktree at current `main`, force-move only its session-owned local branch to `main`, switch back to that branch, and remove stale upstream tracking. Let GitHub delete the remote branch and let fetch pruning remove its remote-tracking ref.
6. Release the reservation and integration lock only when worktree HEAD, local `main`, and `upstream/main` are the same commit and the worktree is clean. Keep the reusable worktree and lane available.
7. If the PR closes without merge, verify that state through GitHub, leave local `main` unchanged, preserve the branch, commits, tracking, worktree, and lane, record the task as undelivered, and release the reservation. Revision needs a new reservation; abandonment or cleanup needs explicit user direction.

## Integration coordination

- The shared state root is `$(git rev-parse --path-format=absolute --git-common-dir)/harness` so every linked worktree sees the same state.
- Serialize each local-`main` mutation by atomically creating `delivery-lock/`, recording its owner, and removing it immediately after the mutation. If the directory already exists, inspect its owner and wait or coordinate; never delete another live owner's lock.
- A PR task creates `delivery-reservations/<session-id>.json` after the equality preflight and retains it through merge alignment or verified closure without merge. Record the owner session and worktree, branch, base commit, PR number when known, and creation time.
- PR development may proceed concurrently, but every `replay` integration waits while any other active PR reservation exists. Never remove a reservation because of age alone; first verify merge, closure, or explicit abandonment.
