# Swarm e2e iteration ledger

## Loop Protocol

- Recording-first triage: start from the `.mov` before any other artifact.
- Read the ledger before any iteration.
- Record the run slug and iteration count.
- Append confirmed findings only.
- Never delete history.
- One row per committed fix.

## Fix Protocol

1. Write the smallest failing test.
2. Confirm red.
3. Implement the smallest fix.
4. Confirm green on the targeted test.
5. Run the required gate.
6. Verify signature with `rtk git log --show-signature -1`.
7. Commit with `rtk git commit -sS`.
8. Keep the sign-off trailer exactly `Signed-off-by: Bart Smykla <bartek@smykla.com>`.

## Escape Hatches

- `needs-verification` when evidence is incomplete.
- Return control for missing runtime.
- Return control for signing failure.

## Anti-Patterns

- Closing rows from logs alone.
- Batching unrelated fixes.
- Running the full UI suite.

## Version Policy

- Do not bump versions inside the loop.
- Recommend semver only after termination.

## Done Bar

- `rtk mise run e2e:swarm:triage:recording:test`
- `rtk mise run monitor:macos:tools:test:e2e`
- `rtk mise run test:integration`
- `rtk mise run check`
- `rtk mise run monitor:macos:lint`

## Canonical Example

| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |
|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|
| L-0001 | Open | high | review-state | 1 | - | mm:ss-mm:ss (launch 2) | stale badge | live badge | recording.mov | - |
