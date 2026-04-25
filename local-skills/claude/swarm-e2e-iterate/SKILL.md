---
name: swarm-e2e-iterate
description: Use when driving the Harness Monitor swarm full-flow e2e through repeated recording-first triage, TDD fixes, signed commits, and reruns until zero open findings remain.
allowed-tools: Bash, Read, Edit, Write, Skill, Agent
---

# Swarm E2E Iterate

Drive `swarm-full-flow` to zero open findings. Each iteration runs one lane, reviews the `.mov` before every other artifact, records confirmed findings in the append-only ledger, fixes open rows with TDD, commits each fix separately, and reruns until a clean iteration produces no new rows and no open rows remain.

## Load Only When Needed

- Before triaging a recording or promoting any UI/UX/performance finding, read [references/recording-analysis.md](references/recording-analysis.md) for detailed recording recipes and UX heuristics.
- Before running the lane, changing the ledger, fixing rows, committing, or deciding the loop can terminate, read [references/iteration-protocol.md](references/iteration-protocol.md) for the loop protocol, ledger schema, gates, escape hatches, and command table.
- When delegating the loop to the dedicated subagent, read [agent.md](agent.md) for the subagent contract.

Use Bash for repo commands, Read for artifacts and references, Agent only when handing the loop to the dedicated subagent, and Edit or Write only for the current ledger row and the smallest fix that closes it.

## Hard Rules

1. Recording handling is mandatory. No iteration completes without producing and processing the `.mov`.
2. Recording triage is first, single-threaded, and never parallelized with logs, `xcresult`, screenshots, or persisted state.
3. A ledger row must cite a recording timestamp range plus at least one secondary artifact reference.
4. One recording segment maps to one app launch. Cross-launch idle dead time is itself a finding.
5. Reuse one recording per iteration. Rerun the lane only after a fix lands or after a bootstrap repair is required.
6. Real findings only. If unsure, mark `needs-verification` and re-watch before promotion.
7. TDD is mandatory: failing test, confirm red, implement, confirm green, gate, signed commit, signature check.
8. Fix the smallest independently committable row first. Do not batch unrelated fixes.
9. Rust gate is `rtk mise run check`. Swift gate is `rtk mise run monitor:macos:lint` plus the relevant scoped build/test lane. Cross-stack changes run both.
10. Do not bump versions inside the loop. Recommend semver only after termination.
11. Do not run the full UI suite. Use `XCODE_ONLY_TESTING=Target/Class/method` for targeted XCTest runs.
12. All repo workflow commands go through `rtk mise run <task>` or `rtk mise run <task> -- <args>`. Do not use raw `cargo`, raw `xcodebuild`, direct scripts, or `rtk proxy`.
13. Every commit uses `rtk git commit -sS`. Verify `rtk git log --show-signature -1` and the exact `Signed-off-by: Bart Smykla <bartek@smykla.com>` trailer. If 1Password is unavailable, hard stop and wait.

## Iteration Summary

1. Read or initialize `tmp/e2e-triage/ledger.md`.
2. Run `rtk mise run e2e:swarm:full`; capture exit status and run slug.
3. Run recording triage: `rtk mise run e2e:swarm:triage:recording -- tmp/e2e-triage/runs/<slug>`.
4. Walk the recording chronologically against [references/recording-analysis.md](references/recording-analysis.md).
5. Triage `xcresult`, logs, screenshots, hierarchy dumps, and persisted state only after the recording pass.
6. Append confirmed rows to the ledger. Never delete history.
7. Fix every Open row in dependency order with the TDD and commit rules above.
8. Rerun from step 2 if any fix landed or any Open row remains.
9. Stop only when the latest iteration has zero new findings, the ledger has zero Open rows, and all touched gates are green.

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
Input: The latest iteration produced zero new rows and the ledger has zero Open rows.
Output: Run the done-bar verification set from [references/iteration-protocol.md](references/iteration-protocol.md), then report iteration count, lane status, open-row count, and commits grouped by subsystem.
</example>

## Done Bar

Before calling the loop shippable, run the verification set in [references/iteration-protocol.md](references/iteration-protocol.md): recording triage tests, e2e helper tests, Rust integration tests, Rust check, and Swift lint. Report iteration count, open-row count, and commits grouped by subsystem.
