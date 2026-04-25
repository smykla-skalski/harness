# Iteration Protocol

Load this before running the lane, changing the ledger, fixing rows, committing, or deciding the loop is done.

## Contents

- [Loop Protocol](#loop-protocol)
- [Fix Protocol](#fix-protocol)
- [Ledger Schema](#ledger-schema)
- [Escape Hatches](#escape-hatches)
- [Commands](#commands)
- [Anti-Patterns](#anti-patterns)
- [Version Policy](#version-policy)
- [Done Bar](#done-bar)

## Loop Protocol

1. State read. Read `tmp/e2e-triage/ledger.md`. If absent, initialize with the schema below. Increment iteration counter.
2. Run the lane: `rtk mise run e2e:swarm:full`. Capture exit status and run slug. If the lane crashes before producing a recording, file a high-severity row, fix the bootstrap break, and restart the iteration.
3. Recording-first triage: `rtk mise run e2e:swarm:triage:recording -- tmp/e2e-triage/runs/<slug>`. Walk [references/recording-analysis.md](recording-analysis.md) against keyframes and emitted JSON.
4. Promote candidates only with recording timestamp range plus secondary artifact reference. Mark unsure rows `needs-verification` and re-watch before promotion.
5. Test failure triage. Use the existing `xcresult` exports and tie each failure to a recording timestamp segment.
6. Logs and persisted-state triage. Walk daemon, act-driver, xcodebuild, screen-recording logs, `context/state-root`, and `context/sync-root`.
7. Ledger update. Persist confirmed findings. Never delete past rows.
8. Fix every Open item in dependency order, smallest first.
9. Loop or terminate. Rerun if any fixes landed or any Open rows remain. Terminate only when an iteration produces zero new findings, ledger has zero Open rows, and gates are green.

## Fix Protocol

For each Open row:

1. Reproduce against artifacts and cite the recording timestamp range.
2. Write a failing Rust unit, Swift XCTest, or e2e contract test.
3. Confirm red.
4. Implement the smallest correct fix.
5. Confirm green on the targeted test.
6. Run the right gate: Rust -> `rtk mise run check`; Swift -> `rtk mise run monitor:macos:lint` plus `XCODE_ONLY_TESTING=... rtk mise run monitor:macos:test`; cross-stack -> both.
7. Commit with `rtk git commit -sS`.
8. Verify signature with `rtk git log --show-signature -1`.
9. Verify exact trailer: `Signed-off-by: Bart Smykla <bartek@smykla.com>`.
10. Update ledger row to Closed with iteration closed and commit hash.

## Ledger Schema

`tmp/e2e-triage/ledger.md` is append-only markdown:

```markdown
# Swarm e2e iteration ledger

- Iteration: <N>
- Last run slug: <slug>
- Last status: <passed|failed>
- Last terminated at: <UTC timestamp>

| ID | Status | Severity | Subsystem | Iteration found | Iteration closed | Recording timestamps | Current behavior | Desired behavior | Evidence | Fix commit |
|----|--------|----------|-----------|-----------------|------------------|----------------------|------------------|------------------|----------|------------|
| L-0001 | Open | high | review-state | 1 | - | mm:ss-mm:ss (launch 2) | <observed> | <expected> | <paths> | - |
```

Severities:
- `critical`: blocks the loop or breaks supervisor trust.
- `high`: visible UX failure or correctness lie.
- `medium`: polish/perf regression noticeable to a careful user.
- `low`: cosmetic, accessibility tightening, or density nudge.

## Escape Hatches

- Lane build fails before artifacts: file high-severity row, fix bootstrap, restart iteration.
- 1Password unavailable for commit signing: hard stop, ask user, wait. Never substitute another key or strip `-S`.
- Required runtime missing per `e2e:swarm:probe-runtimes`: hard stop and surface to user.
- Manual recording playback required: pause and ask user with timestamp range.
- Conflicting parallel agent owns a touched file: switch scope; if blocked more than 5 minutes, ask user.
- User-specified safety budget exceeded: stop with ledger summary and ask user to extend, terminate, or hand off.

## Commands

| Need | Command |
|------|---------|
| Run lane | `rtk mise run e2e:swarm:full` |
| Recording triage | `rtk mise run e2e:swarm:triage:recording -- <run-dir>` |
| Recording triage tests | `rtk mise run e2e:swarm:triage:recording:test` |
| Scoped XCTest | `XCODE_ONLY_TESTING=Target/Class/method rtk mise run monitor:macos:test` |
| Swift gate | `rtk mise run monitor:macos:lint` |
| Rust gate | `rtk mise run check` |
| Rust integration suite | `rtk mise run test:integration` |
| Recording playback | `rtk qlmanage -p tmp/e2e-triage/runs/<slug>/swarm-full-flow.mov` |
| ffprobe duration | `rtk ffprobe -v error -show_entries format=duration -of csv=p=0 <recording>` |
| xcresult tests | `rtk xcrun xcresulttool get test-results summary --path <bundle> --compact` |

`rtk proxy` is forbidden. Redirect full output to a file only when filtered output hides required debug information. Lint and validation output must not be piped through `grep`, `head`, or `tail`.

## Anti-Patterns

- Skipping recording triage when tests pass.
- Closing rows from logs alone.
- Batching unrelated fixes into one commit.
- Suppressing lints to land faster.
- Running the full UI suite.
- Bumping versions inside iteration.
- Rerunning the lane without a fix landed first.
- Using `rtk proxy`.
- Adding a Python pipeline where the Swift CLI fits.
- Using `exec` in new shell wrappers.
- Sharing a worktree across parallel implementer subagents.

## Version Policy

Version bumps land on `main` only after the loop terminates. Inside the loop, reject diffs touching `Cargo.toml`, `testkit/Cargo.toml`, `Cargo.lock` package entries for `harness` or `harness-testkit`, `apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift`, or `apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`.

After termination, report recommended semver level: `patch`, `minor`, or `major`. The user runs `rtk mise run version:set -- <ver>`.

## Done Bar

A clean-baseline dry run is shippable only with zero new findings, zero Open rows, and these commands passing:

```bash
rtk mise run e2e:swarm:triage:recording:test
rtk mise run monitor:macos:tools:test:e2e
rtk mise run test:integration
rtk mise run check
rtk mise run monitor:macos:lint
```

Final report includes iteration count, lane status, new/closed/open finding counts, and short commit hashes grouped by subsystem.
