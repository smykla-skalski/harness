# Swarm E2E Iterate

Drive `swarm-full-flow` to zero open findings. Keep the loop recording-first, TDD-driven, and commit-by-commit. Treat avoidable waiting as a suite-speed defect.

## Load When Needed

- [recording-analysis.md](references/recording-analysis.md) for recording triage, thresholds, and UX/perf signatures.
- [recording-checklist.md](references/recording-checklist.md) for the proof-pass format.
- [act-marker-matrix.md](references/act-marker-matrix.md) for act-by-act surfaces and invariants.
- [iteration-protocol.md](references/iteration-protocol.md) for ledger schema, gates, and loop termination rules.

## Operating Contract

- Triage the `.mov` before logs, screenshots, `xcresult`, or persisted state.
- One recording segment maps to one app launch. Reuse one recording per iteration.
- Append only confirmed findings. Each row needs a recording timestamp plus one secondary artifact.
- Fix the smallest open row first. TDD required: red, fix, green, gate, signed commit, signature check.
- Use `rtk mise run <task>` for repo commands. No raw `cargo`, raw `xcodebuild`, direct scripts, or `rtk proxy`.
- Commit with `rtk git commit -sS`; verify `rtk git log --show-signature -1` and the exact sign-off trailer.
- No version bumps inside the loop. No full UI suite.

## Loop

1. Read or initialize [_artifacts/ledger.md](../../../_artifacts/ledger.md).
2. Run `rtk mise run e2e:swarm:full` and capture the run slug.
3. Run `rtk mise run e2e:swarm:triage:recording -- _artifacts/runs/<slug>`. The aggregator writes `recording-triage/checklist.md` plus per-detector JSONs.
4. Walk the recording chronologically, then read `_artifacts/runs/<slug>/recording-triage/checklist.md`. Promote `found` rows straight to ledger entries and only re-watch rows the emitter marked `needs-verification`.
5. Triage secondary artifacts only after the recording pass and checklist pass.
6. Append confirmed rows, fix open rows one at a time, and rerun until the ledger is clean.

## Done Bar

Ship only after the latest iteration has zero new findings, zero open rows, a complete checklist pass, and green touched gates. Report iteration count, lane status, open-row count, and commits grouped by subsystem.
