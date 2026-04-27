# Swarm e2e iteration ledger

The ledger system spans two files. `_artifacts/active.md` carries the live header plus every Open and `needs-verification` row. `_artifacts/ledger.md` is the append-only archive of Closed rows. The two files never share a row.

## Glossary

- **ledger system** - both files together (the active findings file plus the closed archive).
- **active findings** - rows in `_artifacts/active.md`. Status is `Open` or `needs-verification`.
- **closed archive** - rows in `_artifacts/ledger.md`. Status is `Closed`. Append-only.
- **the ledger** - legacy term. When ambiguous, prefer "active findings" or "closed archive".

## Loop Protocol

- Recording-first triage: start from the `.mov` before any other artifact.
- Read `_artifacts/active.md` before any iteration. Read `_artifacts/ledger.md` only to recall history.
- After the recording pass, complete the checklist proof loop in `references/recording-checklist.md` with one terse verdict line per item.
- Refresh the `active.md` header (`Iteration`, `Last run slug`, `Last status`, `Last terminated at`) once per iteration, after the lane settles. Header state is iteration-scoped, not row-scoped.
- Append confirmed findings to `active.md` only.
- Never delete archive history in `ledger.md`.
- One row per committed fix. The fix moves the row from `active.md` to `ledger.md` via the Move Protocol.

## Fix Protocol

1. Write the smallest failing test.
2. Confirm red.
3. Implement the smallest fix.
4. Confirm green on the targeted test.
5. Run the gate matching the change scope: Rust -> `rtk mise run check`; Swift -> `rtk mise run monitor:macos:lint` plus the relevant build/test lane (see `apps/harness-monitor-macos/CLAUDE.md`); cross-stack -> both.
6. Commit with `rtk git commit -sS`.
7. Verify signature with `rtk git log --show-signature -1`.
8. Keep the sign-off trailer exactly `Signed-off-by: Bart Smykla <bartek@smykla.com>`.
9. Move the row per the Move Protocol below.

## Move Protocol

Per row, after a successful Fix Protocol pass, run:

```
bash scripts/swarm-iterate/close-finding.sh <id> <short-sha>
```

The helper performs the move as a single transaction:

1. Reads the matching `| <id> |` row from `_artifacts/active.md`.
2. Rewrites `Status` to `Closed`, fills `Iteration closed` from the `active.md` header, fills `Fix commit` with `<short-sha>`.
3. Appends the rewritten row to `_artifacts/ledger.md`.
4. Deletes the original row from `active.md`.
5. Re-reads both files and asserts `<id>` appears exactly once in `ledger.md` and not at all in `active.md`. Exits non-zero on any invariant break, leaving the prior good state on disk.

If the test stays red, the gate fails, or signature verification fails, do not run the move helper. Leave the row Open in `active.md` and return control or retry.

Manual move (no helper) follows the same five steps but is discouraged because the writes are not atomic.

## Escape Hatches

- `needs-verification` keeps the row in `active.md` until evidence is complete.
- Return control for missing runtime.
- Return control for signing failure (1Password unavailable -> hard stop).

## Anti-Patterns

- Closing rows from logs alone.
- Batching unrelated fixes.
- Running the full UI suite.
- Editing rows in `ledger.md` after they land - history is append-only.
- Leaving a Closed row in `active.md` or duplicating a row across both files. `scripts/swarm-iterate/check-active-ledger.sh` (run by `rtk mise run check:scripts`) catches both deterministically.

## Version Policy

- Do not bump versions inside the loop.
- Recommend semver only after termination.

## Done Bar

`active.md` carries zero data rows and these gates stay green:

- `rtk mise run e2e:swarm:triage:recording:test`
- `rtk mise run monitor:macos:tools:test:e2e`
- `rtk mise run test:integration`
- `rtk mise run check`
- `rtk mise run check:scripts` (covers ledger-system invariants)
- `rtk mise run monitor:macos:lint`

## File Schemas

Both files share the same column schema. The header lines in `active.md` track live iteration state; `ledger.md` carries no header beyond the title.

### Column vocabulary

- `ID`: `L-####` zero-padded sequential identifier, unique within each file and across the ledger system.
- `Status`: `Open`, `needs-verification`, or `Closed`. `active.md` rows are `Open` or `needs-verification`; `ledger.md` rows are `Closed`.
- `Severity`: `low`, `medium`, `high`, or `critical`.
- `Subsystem`: short kebab-case identifier scoped to the affected component (`recording-control`, `act-driver`, `swarm-orchestrator`, `perf-hitch-budget`, etc.).
- `Iteration found` / `Iteration closed`: integer matching the `Iteration` header at the time. `Iteration closed` is `-` while Open.
- `Recording timestamps`: `mm:ss-mm:ss (launch N)` for a windowed event, or `n/a (<reason>)` when no recording exists.
- `Current behavior` / `Desired behavior`: prose. Code identifiers in backticks; preserve exact error text in backticks too.
- `Evidence`: semicolon-separated list of artifact paths (under `_artifacts/runs/<slug>/...` or repo source paths). At least one secondary artifact alongside the recording reference.
- `Fix commit`: short SHA from the Fix Protocol commit, or `-` while Open.

### `_artifacts/active.md`

```
# Swarm e2e active findings

- Iteration: <N>
- Last run slug: <slug>
- Last status: <one-line summary>
- Last terminated at: <ISO-8601 UTC>

| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |
|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|
<one row per Open or needs-verification finding>
```

### `_artifacts/ledger.md`

```
# Swarm e2e ledger (closed findings archive)

Append-only. Rows arrive from `active.md` after the Move Protocol. Never edit, reorder, or delete past rows.

| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |
|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|
<one row per Closed finding>
```

## Canonical Example

A new finding promoted to `active.md`:

| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |
|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|
| L-0001 | Open | high | review-state | 1 | - | mm:ss-mm:ss (launch 2) | stale badge | live badge | recording.mov | - |
