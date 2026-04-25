# Swarm Full-Flow E2E Gap Ledger

Rows marked `Open` are counted by `mise run e2e:swarm-gaps-open`.
The Slice 6 orchestrator appends optional-runtime skips as `Closed` rows so missing optional tools are visible without making the lane fail.

| ID | Status | Severity | Subsystem | Current behavior | Desired behavior | Closed by |
|---|---|---|---|---|---|---|
| G-01 | Closed | high | review-state | Worker review handoff can double-book without review-aware state. | Awaiting-review task and agent state prevent new assignments. | Slice 1-5 commits |
| G-02 | Closed | high | review-state | Reviewers can mutate without single-runtime claim discipline. | Claim-review rejects duplicate same-runtime reviewers. | Slice 1-5 commits |
| G-03 | Closed | high | review-state | Quorum lacks a durable consensus object. | Distinct-runtime reviews compute consensus. | Slice 1-5 commits |
| G-04 | Closed | medium | review-state | Review rounds are not visible. | Round counter increments on rework. | Slice 1-5 commits |
| G-05 | Closed | medium | review-state | Disputes can spin without leader arbitration. | Third failed round enters leader arbitration. | Slice 1-5 commits |
| G-06 | Closed | medium | review-state | Review points are all-or-nothing. | Worker can agree and dispute individual points. | Slice 1-5 commits |
| G-07 | Closed | medium | signals | Empty reviewer pool can block review forever. | Auto-spawn reviewer signal is emitted to leader. | Slice 1-5 commits |
| G-08 | Closed | medium | improver | Improver role has no guarded disk-edit path. | Improver apply is path-guarded and dry-run capable. | Slice 1-5 commits |
| G-09 | Closed | low | routing | Task persona hints are ignored. | Suggested persona biases routing. | Slice 1-5 commits |
| G-10 | Closed | high | monitor-models | Monitor decoders are strict for review variants. | Tolerant Rust/Swift v10 review model decoding. | Slice 1-5 commits |
| G-11 | Closed | medium | metrics | Awaiting-review and review counts are absent from metrics. | Metrics include awaiting-review, in-review, and arbitration counts. | Slice 1-5 commits |
| G-12 | Closed | medium | daemon-contract | Review routes are missing from API parity. | HTTP and WS contract parity covers review routes. | Slice 1-5 commits |
| G-13 | Closed | medium | daemon-ws | Monitor cannot dispatch review mutations over WS. | WS dispatch routes every review/improver mutation. | Slice 1-5 commits |
| G-14 | Closed | medium | testing | No canonical full-flow e2e lane exists. | `scripts/e2e/swarm-full-flow.sh --assert` drives the 16-act scenario. | Slice 6 |
| G-15 | Closed | medium | observe-routing | High observer task severity is not exercised end-to-end. | Observer issue routing keeps `high` first-class in scripts and tests. | Slice 6 |
