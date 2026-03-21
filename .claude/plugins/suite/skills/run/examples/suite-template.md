# Suite template - directory format

Template for `suite.md` in a directory-format suite. Copy the directory structure and fill in the blanks.

This runner-local template mirrors the suite schema consumed by `harness run preflight` and `suite:run`.

## Directory structure

```
suites/<suite-name>/
├── suite.md           # this file
├── baseline/
│   └── *.yaml         # shared manifests applied before G1
└── groups/
    └── g{NN}-*.md     # one file per group
```

## suite.md template

```yaml
---
suite_id: <feature-scope>
feature: <feature>
scope: <scope>
profiles:
  - single-zone
required_dependencies:
  - <dependency>
user_stories:
  - <story>
variant_decisions:
  - <why a variant group is included or skipped>
coverage_expectations:
  - configure
  - consume
  - debug
baseline_files:
  - baseline/namespace.yaml
groups:
  - groups/g01-crud.md
skipped_groups: []
keep_clusters: false
---
```

### Baseline manifests

| File | Purpose |
| --- | --- |
| baseline/namespace.yaml | Create namespace with sidecar |
| (add more rows) | (describe purpose) |

### Test groups table

## Test groups

| Group | File | Goal | Minimum artifacts |
| --- | --- | --- | --- |
| G1 | groups/g01-crud.md | CRUD baseline | |
| G2 | groups/g02-valid.md | Validation failures | |
| G3 | groups/g03-xds.md | Runtime config verification | |
| G4 | groups/g04-e2e.md | End-to-end flow | |
| G5 | groups/g05-edge.md | Edge cases and negative paths | |
| G6 | groups/g06-mz.md | Multi-zone and isolation | |
| G7 | groups/g07-compat.md | Backward compatibility | |

### Execution contract

- all manifests applied through `harness run apply`
- `harness run preflight` materializes baseline manifests and group `## Configure` YAML once, then writes the prepared-suite artifact in the active run
- kubectl, `curl`, and other cluster-touching commands recorded via `harness run record`, with `harness run record ... -- kumactl ...` reserved for `kumactl`
- cluster state captured after each completed group via `harness run capture`
- group completion recorded through `harness run report group`, which updates `run-status.json` and `run-report.md`
- all failures trigger immediate triage before next group
- all pass/fail decisions include artifact pointers to existing files
- deviations from suite definitions require user approval and are recorded in the report
- inline manifests in group files are authoritative - `harness run preflight` must materialize them verbatim and Phase 4 must reuse the prepared manifest entries from the active run context
- policy create follows the rules in [../references/mesh-policies.md](../references/mesh-policies.md) when applicable

### Failure triage

See [../references/agent-contract.md](../references/agent-contract.md) (failure policy and bug triage protocol) for the full procedure.

## Group file template

Each group file follows this structure:

```markdown
---
group_id: g01
story: <story>
capability: <capability>
profiles:
  - single-zone
preconditions:
  - <required setup>
success_criteria:
  - <expected outcome>
debug_checks:
  - <debug command family>
artifacts:
  - artifacts/g01/<artifact-file>
variant_source: base
helm_values: {}
expected_rejection_orders: []
restart_namespaces: []
---

# G{N} - Group name

## Configure

```yaml
# One fenced block becomes one prepared manifest file.
apiVersion: kuma.io/v1alpha1
kind: <FeatureKind>
metadata:
  name: <resource-name>
  namespace: kuma-demo
spec:
  ...
```

Add one fenced `yaml` or `yml` block per manifest. `harness run preflight` materializes them verbatim into the active run's prepared manifests directory.

If a prepared manifest is intentionally invalid and the test must prove the API rejects it later, list its 1-based ordinal in `expected_rejection_orders`. Preflight still materializes that manifest, but it skips the up-front schema validation for that prepared entry.

## Consume

- `harness run record` commands and expected outputs
- After `harness run init`, use context-driven commands only. Prepared group manifests must be referenced via `harness run apply --manifest "<group-id>/<file>"`.

## Debug

- Follow-up commands and artifact pointers used when the expected outcome fails
```

## Legacy single-file format

For simple suites that don't need progressive loading, a single `<suite-name>.md` file in `suites/` still works. It must use the same frontmatter contract as `suite.md`; the difference is only that all group details live in one file.
