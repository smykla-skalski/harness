# Swarm E2E Iterate

Drive `swarm-full-flow` to zero open findings from Codex. Keep the loop recording-first, TDD-driven, and commit-by-commit. Treat avoidable waiting as a suite-speed defect.

## Ledger System

The ledger system spans two files so the agent never wades through closed history when triaging the next iteration:

- [_artifacts/active.md](../../../_artifacts/active.md) - active findings. Live iteration header plus every Open / `needs-verification` row. Read every iteration.
- [_artifacts/ledger.md](../../../_artifacts/ledger.md) - closed archive. Append-only. Read only when historical context is needed.

A confirmed finding is appended to `active.md`. When it closes, the move helper transfers the row atomically to `ledger.md`:

```
bash scripts/swarm-iterate/close-finding.sh <id> <short-sha>
```

`scripts/swarm-iterate/check-active-ledger.sh` (run by `rtk mise run check:scripts`) enforces the cross-file invariants. See [iteration-protocol.md](references/iteration-protocol.md) for the glossary, schemas, Move Protocol, and gate list.

## Load When Needed

- [recording-analysis.md](references/recording-analysis.md) for recording triage, thresholds, and UX/perf signatures.
- [recording-checklist.md](references/recording-checklist.md) for the proof-pass format.
- [act-marker-matrix.md](references/act-marker-matrix.md) for act-by-act surfaces and invariants.
- [iteration-protocol.md](references/iteration-protocol.md) for ledger-system glossary, schema, Move Protocol, gates, and loop termination rules.
- [council-review.md](references/council-review.md) for the per-iteration council pass: when to invoke, mode dispatch, persona selection, output handling.

## Operating Contract

Headline rules. Full Loop Protocol lives in [iteration-protocol.md](references/iteration-protocol.md#loop-protocol).

- Triage the `.mov` before logs, screenshots, `xcresult`, or persisted state.
- One recording segment maps to one app launch. Reuse one recording per iteration.
- Append only confirmed findings to `active.md`. Each row needs a recording timestamp plus one secondary artifact.
- Fix the smallest open row first. TDD required: red, fix, green, gate, signed commit, signature check, then move via `close-finding.sh`.
- Use `rtk mise run <task>` for repo commands. No raw `cargo`, raw `xcodebuild`, direct scripts, or `rtk proxy`.
- Commit with `rtk git commit -sS`; verify `rtk git log --show-signature -1` and the exact sign-off trailer.
- No version bumps inside the loop. No full UI suite.

## Loop

1. Read or initialize [_artifacts/active.md](../../../_artifacts/active.md). Consult [_artifacts/ledger.md](../../../_artifacts/ledger.md) only for historical context.
2. Run `rtk mise run e2e:swarm:full` and capture the run slug.
3. Run `rtk mise run e2e:swarm:triage:recording -- _artifacts/runs/<slug>`. The aggregator writes `recording-triage/checklist.md` plus per-detector JSONs.
4. Walk the recording chronologically, then read `_artifacts/runs/<slug>/recording-triage/checklist.md`. Promote `found` rows straight into `active.md` and only re-watch rows the emitter marked `needs-verification`.
5. Triage secondary artifacts only after the recording pass and checklist pass.
6. Refresh the `active.md` header once for this iteration (`Iteration`, `Last run slug`, `Last status`, `Last terminated at`).
7. Council review: with `active.md` frozen and non-empty, load `plugins/council/skills/council/SKILL.md`, pick mode by row count + lens spread per [council-review.md](references/council-review.md), then use Codex `spawn_agent` / `wait_agent` exactly as that skill describes. Save the synthesis to `_artifacts/runs/<slug>/council-review.md`. Skip if `active.md` carries zero data rows.
8. Append confirmed rows to `active.md`. Fix open rows one at a time, ranked by the council's Convergence + smallest-row heuristic; on close, run `bash scripts/swarm-iterate/close-finding.sh <id> <short-sha>`. Rerun until `active.md` carries zero data rows.

## Done Bar

Ship only after the latest iteration has zero new findings, `active.md` carries zero data rows, a complete checklist pass, and the gates listed in [iteration-protocol.md#done-bar](references/iteration-protocol.md#done-bar) stay green. Report iteration count, lane status, open-row count (always zero at done), closed-this-iteration count, and commits grouped by subsystem.
