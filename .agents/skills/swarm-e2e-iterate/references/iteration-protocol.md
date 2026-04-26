# Swarm e2e iteration ledger

The ledger lives in two files. `_artifacts/active.md` carries the live header plus every Open and `needs-verification` row. `_artifacts/ledger.md` is the append-only archive of Closed rows. The two files never share a row.

## Loop Protocol

- Recording-first triage: start from the `.mov` before any other artifact.
- Read `_artifacts/active.md` before any iteration. Read `_artifacts/ledger.md` only to recall history.
- After the recording pass, complete the checklist proof loop in `references/recording-checklist.md` with one terse verdict line per item.
- Record the run slug and iteration count in the `active.md` header.
- Append confirmed findings to `active.md` only.
- Never delete archive history in `ledger.md`.
- One row per committed fix. The fix moves the row from `active.md` to `ledger.md` (see Move Protocol).

## Fix Protocol

1. Write the smallest failing test.
2. Confirm red.
3. Implement the smallest fix.
4. Confirm green on the targeted test.
5. Run the required gate.
6. Commit with `rtk git commit -sS`.
7. Verify signature with `rtk git log --show-signature -1`.
8. Keep the sign-off trailer exactly `Signed-off-by: Bart Smykla <bartek@smykla.com>`.
9. Move the row per the Move Protocol below.

## Move Protocol

Run as a single atomic edit per row so neither file double-counts:

1. In `active.md`, set `Status` to `Closed`, fill `Iteration closed` with the current iteration, and fill `Fix commit` with the short SHA from step 6 of the Fix Protocol.
2. Cut the now-Closed row out of `active.md`.
3. Append the same row to the bottom of the table in `_artifacts/ledger.md`. Order in `ledger.md` is append-only by closure time; do not re-sort.
4. Update the `active.md` header (`Iteration`, `Last run slug`, `Last status`, `Last terminated at`) to reflect the run that produced or closed the row.
5. Re-read both files and confirm the row appears exactly once in `ledger.md` and not at all in `active.md`.

If the test stays red, the gate fails, or signature verification fails, do not move the row. Leave it Open in `active.md` and return control or retry.

## Escape Hatches

- `needs-verification` keeps the row in `active.md` until evidence is complete.
- Return control for missing runtime.
- Return control for signing failure (1Password unavailable -> hard stop).

## Anti-Patterns

- Closing rows from logs alone.
- Batching unrelated fixes.
- Running the full UI suite.
- Editing rows in `ledger.md` after they land - history is append-only.
- Leaving a Closed row in `active.md` or duplicating a row across both files.

## Version Policy

- Do not bump versions inside the loop.
- Recommend semver only after termination.

## Done Bar

`active.md` carries zero data rows and these gates stay green:

- `rtk mise run e2e:swarm:triage:recording:test`
- `rtk mise run monitor:macos:tools:test:e2e`
- `rtk mise run test:integration`
- `rtk mise run check`
- `rtk mise run monitor:macos:lint`

## File Schemas

Both files share the same column schema. The header lines in `active.md` track live iteration state; `ledger.md` carries no header beyond the title.

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
