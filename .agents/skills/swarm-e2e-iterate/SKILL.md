---
name: swarm-e2e-iterate
description: Use when driving the Harness Monitor swarm full-flow e2e through recording-first triage, suite-speed analysis, TDD fixes, signed commits, and reruns until zero open findings remain.
allowed-tools: Bash, Read, Edit, Write, Skill, Agent
---

# Swarm E2E Iterate

Drive `swarm-full-flow` to zero open findings. Each iteration runs one lane, reviews the `.mov` before every other artifact, records confirmed findings in the append-only ledger, fixes open rows with TDD, commits each fix separately, and reruns until a clean iteration produces no new rows and no open rows remain. Treat avoidable waiting as a defect in the app or in the loop when it lengthens the run, the recording, or the iteration.

## Load Only When Needed

- Before triaging a recording or promoting any UI/UX/performance finding, read [references/recording-analysis.md](references/recording-analysis.md) for detection recipes, thresholds, per-launch checklist, UX heuristics, and right/wrong signatures.
- Before writing the post-analysis proof pass, read [references/recording-checklist.md](references/recording-checklist.md) for the required item-by-item report format.
- Before promoting any swarm-specific finding tied to an act marker, read [references/act-marker-matrix.md](references/act-marker-matrix.md) for the act-by-act expected Monitor surface, marker payload, and whole-run invariants.
- Before running the lane, changing the ledger, fixing rows, committing, or deciding the loop can terminate, read [references/iteration-protocol.md](references/iteration-protocol.md) for the loop protocol, ledger schema, gates, escape hatches, and command table.

Use Bash for repo commands, Read for artifacts and references, Agent only when handing the loop to the dedicated subagent, and Edit or Write only for the current ledger row and the smallest fix that closes it.

The iteration ledger lives at [_artifacts/ledger.md](../../../_artifacts/ledger.md). Run output lives under [_artifacts/runs/](../../../_artifacts/runs/).

## Suite-Speed Lens

- Look for any period of waiting where the next safe action could have started immediately.
- Treat unnecessary idle time, dead head or tail, repeated relaunches, slow handoffs, and delayed assertions as suite-speed regressions when they make the iteration slower or the recording longer.
- Prefer fixes that remove waiting, shorten the capture, or let the loop continue sooner instead of accepting a slower path.
- Log suite-speed issues separately when the product is correct but the test path is not.

## Documentation Output

- Any file or path mentioned in generated notes, summaries, or handoffs must use markdown link format.
- Prefer one standalone link per path.

## Hard Rules

1. Recording handling is mandatory. No iteration completes without producing and processing the `.mov`.
2. Recording triage is first, single-threaded, and never parallelized with logs, `xcresult`, screenshots, or persisted state.
3. A ledger row must cite a recording timestamp range plus at least one secondary artifact reference.
4. After the chronological recording pass, run the checklist proof loop in [references/recording-checklist.md](references/recording-checklist.md). Every item gets a short verdict, a proof reference, and a clear found or not-found outcome.
5. One recording segment maps to one app launch. Cross-launch idle dead time is itself a finding.
6. Reuse one recording per iteration. Rerun the lane only after a fix lands or after a bootstrap repair is required.
7. Real findings only. If unsure, mark `needs-verification` and re-watch before promotion.
8. TDD is mandatory: failing test, confirm red, implement, confirm green, gate, signed commit, signature check.
9. Fix the smallest independently committable row first. Do not batch unrelated fixes.
10. Rust gate is `rtk mise run check`. Swift gate is `rtk mise run monitor:macos:lint` plus the relevant scoped build/test lane. Cross-stack changes run both.
11. Do not bump versions inside the loop. Recommend semver only after termination.
12. Do not run the full UI suite. Use `XCODE_ONLY_TESTING=Target/Class/method` for targeted XCTest runs.
13. All repo workflow commands go through `rtk mise run <task>` or `rtk mise run <task> -- <args>`. Do not use raw `cargo`, raw `xcodebuild`, direct scripts, or `rtk proxy`.
14. Every commit uses `rtk git commit -sS`. Verify `rtk git log --show-signature -1` and the exact `Signed-off-by: Bart Smykla <bartek@smykla.com>` trailer. If 1Password is unavailable, hard stop and wait.

## Iteration Summary

1. Read or initialize [_artifacts/ledger.md](../../../_artifacts/ledger.md).
2. Run `rtk mise run e2e:swarm:full`; capture exit status and run slug.
3. Run recording triage: `rtk mise run e2e:swarm:triage:recording -- _artifacts/runs/<slug>`.
4. Walk the recording chronologically against [references/recording-analysis.md](references/recording-analysis.md).
5. Run the checklist proof loop from [references/recording-checklist.md](references/recording-checklist.md). Write one terse line per item with the proof artifact, the verdict, and whether it found a problem.
6. Triage `xcresult`, logs, screenshots, hierarchy dumps, and persisted state only after the recording pass and checklist pass.
7. Append confirmed rows to the ledger. Never delete history.
8. Fix every Open row in dependency order with the TDD and commit rules above.
9. Rerun from step 2 if any fix landed or any Open row remains.
10. Stop only when the latest iteration has zero new findings, the ledger has zero Open rows, the checklist pass is complete, and all touched gates are green.

## Finding Promotion

Promote a candidate only when all fields are known:

- status and severity,
- subsystem,
- iteration found,
- recording timestamp range,
- current behavior,
- desired behavior,
- evidence paths or log references,
- fix commit after closure.

Use severities from [references/iteration-protocol.md](references/iteration-protocol.md). Do not close rows from logs alone.

## Example Inputs

<example>
Input: The latest run passed, but `swarm-full-flow.mov` shows a 6-second frozen tail after app exit and `screen-recording.log` confirms the process ended earlier.
Output: Append one Open recording-artifact row with the timestamp range plus the log path. Do not inspect secondary artifacts first or mark the iteration clean.
</example>

<example>
Input: Ledger row `L-0042` is Open for a review-state badge regression with recording timestamps and `xcresult` evidence.
Output: Reproduce `L-0042`, write a failing targeted test, land the smallest signed fix commit, close `L-0042` with the commit hash, and rerun the lane.
</example>

<example>
Input: The recording shows 9 seconds of idle waiting where the next safe action could have started immediately.
Output: Append one Open suite-speed row with the timestamp range, the recording proof, and the smallest change that removes the wait or shortens the iteration.
</example>

<example>
Input: The latest iteration produced zero new rows and the ledger has zero Open rows.
Output: Run the done-bar verification set from [references/iteration-protocol.md](references/iteration-protocol.md), then report iteration count, lane status, open-row count, and commits grouped by subsystem.
</example>

## Done Bar

Before calling the loop shippable, run the verification set in [references/iteration-protocol.md](references/iteration-protocol.md): recording triage tests, e2e helper tests, Rust integration tests, Rust check, and Swift lint. Report iteration count, open-row count, and commits grouped by subsystem.
