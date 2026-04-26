# Swarm E2E Iterate

Drive `swarm-full-flow` to zero open findings. Keep the loop recording-first, TDD-driven, and commit-by-commit. Treat avoidable waiting as a suite-speed defect.

## Two-File Ledger

Findings live across two files so the agent never wades through closed history when triaging the next iteration:

- [_artifacts/active.md](../../../_artifacts/active.md) - hot file. Live iteration header plus every Open / `needs-verification` row. Read every iteration.
- [_artifacts/ledger.md](../../../_artifacts/ledger.md) - append-only archive of Closed rows. Read only when historical context is needed.

A confirmed finding is appended to `active.md`. When it closes the row moves atomically to `ledger.md` (mark Closed, cut from active file, append to archive) so neither file double-counts. See [iteration-protocol.md](references/iteration-protocol.md) for the move protocol.

## Load When Needed

- [recording-analysis.md](references/recording-analysis.md) for recording triage, thresholds, and UX/perf signatures.
- [recording-checklist.md](references/recording-checklist.md) for the proof-pass format.
- [act-marker-matrix.md](references/act-marker-matrix.md) for act-by-act surfaces and invariants.
- [iteration-protocol.md](references/iteration-protocol.md) for ledger schema, file-split move protocol, gates, and loop termination rules.

## Operating Contract

- Triage the `.mov` before logs, screenshots, `xcresult`, or persisted state.
- One recording segment maps to one app launch. Reuse one recording per iteration.
- Append only confirmed findings to `active.md`. Each row needs a recording timestamp plus one secondary artifact.
- Fix the smallest open row first. TDD required: red, fix, green, gate, signed commit, signature check, then move row from `active.md` to `ledger.md`.
- Use `rtk mise run <task>` for repo commands. No raw `cargo`, raw `xcodebuild`, direct scripts, or `rtk proxy`.
- Commit with `rtk git commit -sS`; verify `rtk git log --show-signature -1` and the exact sign-off trailer.
- No version bumps inside the loop. No full UI suite.

## Loop

1. Read or initialize [_artifacts/active.md](../../../_artifacts/active.md). Consult [_artifacts/ledger.md](../../../_artifacts/ledger.md) only for historical context.
2. Run `rtk mise run e2e:swarm:full` and capture the run slug.
3. Run `rtk mise run e2e:swarm:triage:recording -- _artifacts/runs/<slug>`. The aggregator writes `recording-triage/checklist.md` plus per-detector JSONs.
4. Walk the recording chronologically, then read `_artifacts/runs/<slug>/recording-triage/checklist.md`. Promote `found` rows straight into `active.md` and only re-watch rows the emitter marked `needs-verification`.
5. Triage secondary artifacts only after the recording pass and checklist pass.
6. Append confirmed rows to `active.md`. Fix open rows one at a time; on close, move the row from `active.md` to `ledger.md` per the move protocol. Rerun until `active.md` carries zero data rows.

## Done Bar

Ship only after the latest iteration has zero new findings, `active.md` carries zero data rows, a complete checklist pass, and green touched gates. Report iteration count, lane status, open-row count (always zero at done), closed-this-iteration count, and commits grouped by subsystem.
