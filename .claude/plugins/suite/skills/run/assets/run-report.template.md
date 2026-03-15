---
run_id: __RUN_ID__
suite_id: __SUITE_ID__
profile: __PROFILE__
overall_verdict: pending
story_results: []
debug_summary: []
---

# Run report

Compactness rules:

- keep this report concise and summary-oriented
- do not paste raw command output or full YAML dumps here
- reference evidence files in `artifacts/`, `state/`, and `manifests/`
- run `harness report check` before closeout

## Run summary

- session id: `__SESSION_ID__`
- created at (utc): `__CREATED_AT__`
- operator: ``
- feature scope: ``
- local build revision: ``
- local `kumactl` path/version: ``

## Preflight status

| check | status | evidence |
| --- | --- | --- |
| docker reachable | PASS/FAIL | `artifacts/...` |
| cluster reachable | PASS/FAIL | `artifacts/...` |
| nodes visible | PASS/FAIL | `artifacts/...` |
| kuma control plane ready | PASS/FAIL | `artifacts/...` |
| local kumactl confirmed | PASS/FAIL | `artifacts/...` |

## Story verdicts

| story | status | evidence | notes |
| --- | --- | --- | --- |
| G1 | PASS/FAIL | `artifacts/...` | |

## Debug evidence

| check | status | evidence | notes |
| --- | --- | --- | --- |
| control plane logs | captured/unused | `commands/...` | |

## Deviations

- None.

## Failures and triage

- None.

## Conclusions

- overall status: pending
- unresolved risks:
- recommended follow-up:
