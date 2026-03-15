---
suite_id: motb-core
feature: motb
scope: core
profiles:
  - single-zone
  - multi-zone
required_dependencies:
  - otel-collector
  - demo-workload
user_stories:
  - Configure observability backends and confirm the dataplane emits to the expected target.
variant_decisions:
  - Include the unified naming variant when the code under test changes listener or cluster naming.
coverage_expectations:
  - configure
  - consume
  - debug
baseline_files:
  - baseline/namespace.yaml
  - baseline/otel-collector.yaml
  - baseline/demo-workload.yaml
groups:
  - groups/g01-crud.md
  - groups/g02-validation.md
skipped_groups:
  - g03-runtime: omitted here to keep the worked example compact; real suites add it when plugin output changes
  - g04-e2e: omitted here to keep the worked example compact; real suites add it when behavior depends on live signal flow
  - g05-edge: omitted here to keep the worked example compact; real suites add it when selector and dangling-reference coverage matters
  - g06-multizone: omitted here to keep the worked example compact; real suites add it when KDS or zone-specific behavior is in scope
  - g07-compat: not needed when deprecated fields are unchanged
keep_clusters: false
---

# Example suite - MOTB core (runner view)

Worked suite example showing the structure expected by `suite:run`. Group files stay authoritative for `## Consume` and `## Debug`, while `harness preflight` materializes the `## Configure` YAML into prepared manifests for the active run.

## Baseline manifests

| File | Purpose |
| --- | --- |
| baseline/namespace.yaml | Create the `kuma-demo` namespace with sidecar injection enabled. |
| baseline/otel-collector.yaml | Deploy the shared OTel collector used by the suite. |
| baseline/demo-workload.yaml | Deploy the demo client and echo server used by runtime checks. |

## Test groups

| Group | File | Goal | Minimum artifacts |
| --- | --- | --- | --- |
| G1 | groups/g01-crud.md | CRUD baseline for backend resources | create, update, delete outputs |
| G2 | groups/g02-validation.md | Validation rejects for invalid backend specs | admission errors and dry-run output |

## Execution contract

- `harness preflight` materializes baseline manifests and group `## Configure` YAML once, validates them, applies baselines once, and writes the prepared-suite artifact for the active run.
- All manifests are applied through `harness apply`.
- After `harness init`, use context-driven commands only. Prepared manifests are referenced as `harness apply --manifest "<group-id>/<file>"`.
- All cluster-interacting verification and cleanup commands are executed through `harness record`.
- Group files stay authoritative for `## Consume`, `## Debug`, and expected outcomes.
- State is captured after each completed group with `harness capture`.
- Deviations require user approval and are recorded in the run report.

## Failure triage

- Stop on the first unexpected failure.
- Capture state and the exact failing command before changing anything.
- Classify the issue as manifest, environment, or product bug.
- Record expected vs observed behavior plus artifact paths before proceeding.
