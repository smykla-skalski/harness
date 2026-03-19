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
  - path: baseline/namespace.yaml
    clusters: all
  - path: baseline/otel-collector.yaml
    clusters: all
  - path: baseline/demo-workload.yaml
    clusters: all
groups:
  - groups/g01-crud.md
  - groups/g02-validation.md
skipped_groups:
  - g03-runtime: omitted in this worked example to keep focus on suite structure; actual suites add it when plugin output changes
  - g04-e2e: omitted in this worked example; add it when live signal flow is part of the feature scope
  - g05-edge: omitted in this worked example; add it when selector or dangling-reference coverage matters
  - g06-multizone: omitted in this worked example; add it when KDS or zone-specific behavior is in scope
  - g07-compat: not needed when deprecated fields are unchanged
keep_clusters: false
---

# MOTB core suite

## Baseline manifests

| File | Purpose | Clusters |
| --- | --- | --- |
| baseline/namespace.yaml | Create the `kuma-demo` namespace with sidecar injection enabled. | all |
| baseline/otel-collector.yaml | Deploy the shared OTel collector used by the suite. | all |
| baseline/demo-workload.yaml | Deploy the demo client and echo server used by runtime checks. | all |

## Test groups

| Group | File | Goal | Minimum artifacts |
| --- | --- | --- | --- |
| G1 | groups/g01-crud.md | CRUD baseline for backend resources | create, update, delete outputs |
| G2 | groups/g02-validation.md | Validation rejects for invalid backend specs | admission errors and dry-run output |

## Execution contract

- `harness run preflight` materializes baseline manifests and group `## Configure` YAML once, validates them, applies baselines to all clusters declared in each baseline's `clusters` field, and writes the prepared-suite artifact for the active run.
- All manifests are applied through `harness run apply`.
- All cluster-interacting commands are executed through tracked harness wrappers such as `harness run record ... -- kubectl ...`, `harness run record ... -- kumactl ...`, or `harness run record`.
- Group files stay authoritative for `## Consume`, `## Debug`, and expected outcomes.
- The prepared-suite artifact is the runtime source of truth for prepared manifest paths plus `helm_values` and `restart_namespaces`.
- State is captured after each completed group with `harness run capture`.
- Deviations require user approval and are recorded in the run report.

## Failure triage

- Stop on the first unexpected failure.
- Capture state and the exact failing command before changing anything.
- Classify the issue as manifest, environment, or product bug.
- Record expected vs observed behavior plus artifact paths before proceeding.
