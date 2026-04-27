# Contents

1. [Manifest completeness rule](#manifest-completeness-rule)
2. [Suite naming](#suite-naming)
3. [Suite directory layout](#suite-directory-layout)
4. [suite.md structure](#suitemd-structure)
5. [Baseline directory](#baseline-directory)
6. [Groups directory](#groups-directory)
7. [Group file structure](#group-file-structure)
8. [Standard group structure](#standard-group-structure)
9. [Amendments log](#amendments-log)
10. [Manifest conventions](#manifest-conventions)
11. [Command create defaults](#command-create-defaults)
12. [Validation step patterns](#validation-step-patterns)
13. [Artifact capture patterns](#artifact-capture-patterns)
14. [Execution contract](#execution-contract)
15. [Reference](#reference)

---

# Suite structure

Format spec for test suites consumed by the suite runner.

## Suite naming

Suite names follow the pattern `{feature}-{scope}` in kebab-case:

- `{feature}`: the primary resource or feature being tested (e.g., `meshmetric`, `meshtrace`, `motb`)
- `{scope}`: what aspect is covered (e.g., `core`, `pipe-mode`, `multizone`, `backendref-validation`)

Good: `meshmetric-core`, `motb-pipe-mode`, `meshtrace-otel-backends`, `delegated-gw-dataplane-targetref`
Bad: `test-suite-1`, `full`, `feature-branch`, `my-test`

For single-feature suites testing the full surface, use `{feature}-core`. For focused suites testing a specific aspect, name the aspect explicitly.

## Suite directory layout

```
${DATA_DIR}/${SUITE_NAME}/
  suite.md                   # metadata, group table, execution contract (~80-130 lines)
  amendments.md              # log of fixes applied to suite files during runs (created on first amendment)
  baseline/                  # shared manifests applied before G1
    namespace.yaml
    otel-collector.yaml
    demo-workload.yaml
  groups/                    # one markdown file + one manifest directory per group
    g01-crud.md
    g01/                     # pre-written manifests for G1, applied via harness run apply --manifest g01
      01-create.yaml
      02-update.yaml
    g02-validation.md
    g02/                     # pre-written manifests for G2
      01-invalid-enum.yaml
      02-missing-field.yaml
    ...
```

## suite.md structure

The entry point file starts with YAML frontmatter, then contains tables that reference the group files. Required frontmatter:

```yaml
---
suite_id: <kebab-case-name>
feature: <primary feature>
scope: <what this suite covers>
profiles:
  - single-zone
required_dependencies:           # harness infrastructure blocks only
  - helm                         # valid: docker, compose, kubernetes, k3d, helm, envoy, kuma, build
user_stories:                    # do NOT put application resources here (otel-collector, demo-workload, etc.)
  - <story written from the operator or user point of view>
variant_decisions:
  - <why a variant group was included or skipped>
coverage_expectations:
  - configure
  - consume
  - debug
baseline_files:
  - baseline/namespace.yaml
  # For multi-zone suites, use the object form with clusters:
  # - path: baseline/namespace.yaml
  #   clusters: all
groups:
  - groups/g01-crud.md
skipped_groups:
  - g07-compat: not needed when deprecated fields are unchanged
keep_clusters: false
---
```

### Baseline manifests table

For single-zone-only suites:

```markdown
## Baseline manifests

| File | Purpose |
| --- | --- |
| baseline/namespace.yaml | test namespace with mesh label |
| baseline/otel-collector.yaml | otel collector deployment |
| baseline/demo-workload.yaml | echo server + client pods |
```

For suites with multi-zone profiles, add a Clusters column:

```markdown
## Baseline manifests

| File | Purpose | Clusters |
| --- | --- | --- |
| baseline/namespace.yaml | test namespace with mesh label | all |
| baseline/otel-collector.yaml | otel collector deployment | all |
| baseline/demo-workload.yaml | echo server + client pods | all |
```

### Test groups table

```markdown
## Test groups

| Group | File | Goal | Minimum artifacts |
| --- | --- | --- | --- |
| G1 | groups/g01-crud.md | Resource CRUD | create/get/update/delete YAML |
| G2 | groups/g02-validation.md | Validation rejects | admission errors |
| ... | ... | ... | ... |
```

### Execution contract

See [Execution contract](#execution-contract) below.

### Failure triage

Short section telling the runner to stop on the first unexpected failure, capture state, classify the issue, and record expected vs observed behavior plus artifact paths before continuing.

## Baseline directory

One `.yaml` file per shared resource applied once during `harness run preflight`. These are manifests that multiple groups depend on (namespace setup, otel collector, demo workloads). Extract them from group steps to avoid duplication. The runner materializes them into the active run's `manifests/prepared/baseline/` directory and applies them before Phase 4 begins.

### Baseline cluster distribution

By default, baselines are applied to the primary cluster only (the global CP cluster in multi-zone, or the single cluster in single-zone). When the suite includes `multi-zone` in its `profiles` list, baselines that create workloads must also be present on zone clusters so that xDS configuration can be inspected on zone dataplanes.

Each baseline entry in the `baseline_files` frontmatter list can optionally use the object form with a `clusters` field:

```yaml
baseline_files:
  - path: baseline/namespace.yaml
    clusters: all
  - path: baseline/otel-collector.yaml
    clusters: all
  - path: baseline/demo-workload.yaml
    clusters: all
```

Allowed values for `clusters`:

| Value | Meaning |
| --- | --- |
| `global` | Apply to the global cluster only (default when `clusters` is omitted) |
| `all` | Apply to every cluster in the topology (global + all zones) |
| list of roles | Apply to the listed cluster roles only, e.g. `[global, zone-1]` |

For backward compatibility, a plain string entry like `- baseline/namespace.yaml` is equivalent to `- path: baseline/namespace.yaml` with no `clusters` field (global only).

When `profiles` includes `multi-zone`, baselines that deploy workloads (demo apps, collectors, test namespaces) should use `clusters: all` so zone clusters have the pods needed for xDS inspection and traffic testing. Infrastructure-only baselines that only make sense on the global CP (like mesh-wide policies) can keep the default.

## Groups directory

One markdown file per group plus a manifest directory with the same group ID prefix. Naming convention: `g{NN}-{slug}.md` for the markdown, `g{NN}/` for the manifest directory where NN is zero-padded and slug is kebab-case. Range groups use: `g17-g26-pipe-mode.md` with `g17-g26/` for manifests.

Each manifest directory contains the group's YAML manifests, named in apply order: `01-{descriptive-slug}.yaml`, `02-{descriptive-slug}.yaml`, etc. The group markdown's `## Configure` section references these files with `harness run apply` commands (e.g., `harness run apply --manifest g{NN}`) but does not duplicate the YAML inline. The YAML lives only in the `groups/g{NN}/` directory.

## Group file structure

Each group file starts with YAML frontmatter and then contains the required body sections:

```yaml
---
group_id: g01
story: Verify the backend can be created, observed, and debugged.
capability: MOTB CRUD baseline
profiles:
  - single-zone
preconditions:
  - Baseline manifests are applied.
success_criteria:
  - MeshMetric is accepted.
  - Envoy config includes the expected backend cluster.
debug_checks:
  - inspect dataplane
  - inspect config-dump
artifacts:
  - artifacts/g01/meshmetric.yaml
  - artifacts/g01/config-dump.txt
variant_source: base
helm_values:
  dataPlane.features.unifiedResourceNaming: true
expected_rejection_orders: []
restart_namespaces:
  - kuma-demo
---
```

```markdown
# G1 - CRUD baseline

## Configure

This section contains `harness run apply` commands that reference the pre-written YAML files in the group's manifest directory (`groups/g{NN}/`). Do not embed inline YAML blocks here. Use `harness run apply --manifest g{NN}` to apply the whole directory, or `harness run apply --manifest g{NN}/01-name.yaml` for a specific file.

Use `expected_rejection_orders` when a prepared manifest is intentionally invalid and a later execution step must prove the API rejects it. The list is 1-based and follows the manifest file order in the `groups/g{NN}/` directory. `harness create validate` still validates those manifests but skips up-front schema validation for the listed ordinals so the rejection path can run in Phase 4.

## Consume

Full `harness` validation commands and explicit expected outcomes.

## Debug

Full `harness` debug commands and artifact pointers used when the expected outcome does not hold.
```

## Standard group structure

| Group | Purpose | Typical contents |
| --- | --- | --- |
| G1 | CRUD baseline | create/get/update/delete the resource |
| G2 | Validation failures | invalid manifests that should be rejected (from validator.go) |
| G3 | Runtime config | xDS inspection commands (from plugin.go understanding) |
| G4 | End-to-end flow | traffic generation + expected behavior |
| G5 | Edge cases | dangling refs, missing deps, bad combinations |
| G6 | Multi-zone | KDS sync, cross-zone, cross-mesh isolation |
| G7 | Backward compat | legacy paths, deprecated fields, migration behavior |

Not all groups apply to every feature. Skip groups that don't make sense, but document why in the suite metadata so the next create or runner can tell the difference between intentional scope and missing coverage.

## Amendments log

When the suite runner discovers a manifest error during a run, the user can choose to fix it in the suite itself (not just the current run). These fixes are recorded in `amendments.md` at the suite root. The file is created on the first amendment; suites start without one.

Format:

```markdown
# Suite amendments

Changes applied to suite files during test runs.

---

**2026-03-06** | Run: `20260306-180131-manual` | G3

- **File**: `groups/g03-policy-matching.md`
- **Change**: Fixed namespace from `kuma-system` to `kong`
- **Reason**: MeshTrafficPermission with namespace-scoped targetRef must be in the workload namespace

---
```

Each entry has: date, run ID, group, file path, what changed, and why. Entries are appended chronologically with `---` separators. The runner updates both the suite file (inline YAML or baseline YAML) AND amendments.md in a single operation.

Amendments are permanent fixes to the suite. Future runs use the corrected manifests. This is different from run-only deviations which are recorded only in the run report and don't change the suite.

## Manifest completeness rule

Every Kubernetes resource that any test group references during its steps must exist as a YAML file in the suite before create finishes. This includes:

- ContainerPatch resources for sidecar environment variables or proxy configuration
- MeshTrafficPermission, MeshRetry, MeshTimeout, or any other Mesh* policy that groups apply
- Gateway API CRDs (GatewayClass, Gateway, HTTPRoute) if groups reference them
- Any resource that a group's `## Configure` or `## Execute` steps apply but that does not yet exist as a manifest file

If a group step references applying a resource that has no corresponding YAML file in `groups/{group-id}/`, the create process must create it. The suite:run runner must never need to create manifests on the fly - all manifests ship with the suite.

## Manifest conventions

### Kubernetes format

- `apiVersion`: verify against the CRD (`deployments/charts/kuma/crds/`) - use the exact group/version (e.g., `kuma.io/v1alpha1`)
- `metadata.namespace`: determined by CRD scope (Namespaced) AND policy type. Mesh-scoped `Mesh*` policies go in `kuma-system`. Namespace-scoped policies targeting workloads go in the workload namespace.
- `metadata.labels`: include `kuma.io/mesh: <mesh-name>` for mesh-scoped policies
- Field names must match Go struct JSON tags exactly (camelCase). Check the API spec struct or CRD schema - do not guess, because guessed field names silently create invalid manifests.
- Enum values must be in the allowed set from `+kubebuilder:validation:Enum` markers

### Universal format

- `type`: must match the registered resource kind (e.g., `MeshTrafficPermission`)
- `mesh`: required for mesh-scoped resources (top-level field, not in metadata)
- `name`: resource name (top-level field)
- `spec`: same field names as Kubernetes format (from Go struct JSON tags)

### Multi-zone policy placement

- Policies targeting system namespaces (`kuma-system`) must be applied on the Global CP. Zone CPs reject policy operations on system namespaces via admission webhook.
- When create multi-zone suites, manifests that create or update policies in `kuma-system` must specify `clusters: global` (or omit `clusters` to get the global-only default). Applying them to zone clusters will fail with an admission error.

### Kubernetes Services

- Services with multiple ports must name every port. Kubernetes rejects unnamed ports when count > 1.

### General

- Use realistic but minimal manifests - enough to trigger the behavior, no extras
- Every manifest field must be verified against the CRD or Go API spec before inclusion. See [code-reading-guide.md](code-reading-guide.md) (Schema verification sources) for the full checklist.
- Check the policy spec nesting pattern (from/to/rules) before writing manifests. Config like `action` lives at `spec.from[].default.action`, NOT `spec.default.action`. See [code-reading-guide.md](code-reading-guide.md) (Policy spec nesting patterns) for the full pattern table and correct/incorrect examples.
- `targetRef.name` and `targetRef.labels` are mutually exclusive - never use both in the same targetRef, because mixed selectors create ambiguous targeting and often fail validation. Use `name` to target a specific resource, `labels` to target a group.

### Kuma backendRef qualified names

In Kubernetes mode, Kuma stores resources with qualified internal names in the form `<metadata.name>.<metadata.namespace>`. When a policy (MeshMetric, MeshTrace, MeshAccessLog, etc.) uses a `backendRef` to reference another Kuma resource (MeshOpenTelemetryBackend, MeshExternalService, etc.), the `name` field must use this qualified form - e.g. `demo-collector.kuma-system`, not just `demo-collector`. Bare names silently fail to match at runtime.

### OTel collector configuration

- Use the `debug` exporter, not `logging`. The `logging` exporter was removed in recent collector versions and causes immediate crash (CrashLoopBackOff).

## Command create defaults

- Generate executable commands, not placeholders. The default authored output uses full `harness` invocations.
- Use `harness run apply` for prepared manifests, `harness run record --phase <phase> --label <label> [--cluster <name>] -- kubectl <args>` for kubectl commands, `harness run record --phase <phase> --label <label> -- kumactl <args>` for kumactl commands, `harness run envoy capture --phase <phase> --label <label> --namespace <ns> --workload <target> [--type-contains <Type>|--grep <Text>]` for Envoy admin payloads, and `harness run record --phase <phase> --label <label> -- <command>` for `curl`, `wget`, `jq`, and other non-wrapped commands.
- Raw `kubectl`, `kumactl`, `curl`, or similar commands are allowed only when the suite:create prompt explicitly asks for raw commands.

## Domain knowledge

### Mesh\* policy suite requirements

When the suite tests any `Mesh*` policy, keep the package self-contained and include these rules directly in the authored output:

- Use only the new `Mesh*` policy family for that feature area. Do not mix old and new policy families in one suite, because mixed-family coverage makes migration failures hard to attribute.
- Namespace is part of policy behavior. Mesh-scoped policies belong in `kuma-system`; workload-scoped policies usually belong in the workload namespace.
- Always set `metadata.labels["kuma.io/mesh"]` explicitly on Kubernetes manifests.
- `targetRef.name` and `targetRef.labels` are mutually exclusive. `MeshGateway` targets builtin gateways only; `Dataplane` with labels targets sidecars and delegated gateways.
- G3 covers runtime config inspection, G5 covers selector and dangling-reference edge cases, G6 covers default multi-zone behavior, and G7 covers deprecated-field or migration behavior.

Recommended edge-case matrix for Mesh\* policy suites:

| Case | What to cover |
| --- | --- |
| baseline mesh-level policy | expected default behavior |
| specificity overrides | mesh vs dataplane labels vs dataplane name/section |
| producer vs consumer | precedence in caller namespace |
| route-level targeting | `MeshHTTPRoute` override on one route only |
| sectionName targeting | named and numeric section behavior |
| selector fan-out | one label selector applying to many dataplanes |
| invalid schema | admission rejects wrong enum or shape |
| dangling reference | accept/reject behavior and runtime effect |
| update and rollback | config changes and restore behavior |
| delete semantics | effective cleanup after delete |
| multi-zone propagation | origin/sync and zone runtime behavior |
| protocol mismatch | expected non-application when listener type mismatches |

### Delegated gateways

A "delegated gateway" in Kuma is a standalone gateway proxy (not managed by Kuma's builtin gateway) that Kuma treats as a gateway dataplane. In practice this means Kong Gateway. When generating test suites that involve delegated gateways:

- Use Kong Gateway (image `kong:3.9` or later - check for newer stable releases) as the delegated gateway workload, not nginx or a generic proxy
- Deploy Kong in its own namespace (`kong`) with `kuma.io/sidecar-injection: enabled`
- Annotate the pod with `kuma.io/gateway: enabled` so the injector treats it as a delegated gateway
- Label the pod `app: kong-gateway` to match the convention used in unit test fixtures
- Configure Kong in DB-less mode (`KONG_DATABASE=off`) with declarative config routing to backend services
- The resulting Dataplane resource will have `networking.gateway.type: DELEGATED`
- Policies target delegated gateways via `kind: Dataplane` with label selectors (not `kind: MeshGateway` which is for builtin gateways)

### Builtin gateways

Builtin gateways are managed by Kuma using MeshGateway + GatewayClass resources from the Kubernetes Gateway API. They require Gateway API CRDs to be installed in the cluster. When generating suites that include builtin gateway groups:

- Add `gateway-api-crds` to the suite metadata `required dependencies`
- The test runner will install them via `harness setup gateway` during Phase 2
- Use `GatewayClass`, `Gateway`, `HTTPRoute` from `gateway.networking.k8s.io/v1` or `v1beta1`
- Builtin gateways are NOT available on Universal - only Kubernetes

### Builtin vs delegated

| Aspect | Builtin gateway | Delegated gateway (Kong) |
| --- | --- | --- |
| Managed by | Kuma (MeshGateway + GatewayClass) | External (Kong, deployed by user) |
| Dataplane type | `BUILTIN` | `DELEGATED` |
| Policy targeting | `kind: MeshGateway` | `kind: Dataplane` with labels |
| Pod annotation | none (auto-created) | `kuma.io/gateway: enabled` |
| Transparent proxy | disabled | disabled |
| CRD requirement | Gateway API CRDs (`gateway-api-crds`) | none (standard Kuma CRDs only) |
| Environments | Kubernetes only | Kubernetes and Universal |

## Validation step patterns

Commands to verify expected state after applying manifests:

```bash
# Resource exists
harness run record --phase verify --label get-resource \
  -- kubectl get <resource-type> <name> -n <namespace> -o yaml

# kumactl inspection
harness run record --phase verify --label inspect-dataplanes \
  -- kumactl inspect dataplanes --mesh default

# Envoy config dump
harness run envoy capture --phase verify --label config-dump \
  --namespace <ns> --workload deploy/<name> \
  --type-contains ClustersConfigDump

# Control plane logs
harness run record --phase debug --label control-plane-logs \
  -- kubectl logs -n kuma-system deploy/kuma-control-plane --tail=50
```

## Artifact capture patterns

| Group type | What to capture |
| --- | --- |
| CRUD | resource YAML before/after, kubectl output |
| Validation | admission error messages |
| Runtime config | config dump snippets for relevant xDS sections |
| E2E flow | traffic tool output, collector/backend logs |
| Edge cases | CP logs, resource status, error messages |
| Multi-zone | resource presence on global and zone CPs |
| Backward compat | deprecation warnings, runtime config comparison |

## Execution contract

Every suite must include this checklist in suite.md:

- `harness run preflight` validates baseline manifests and per-group manifest directories, applies baselines once (to all clusters specified by each baseline's `clusters` field), and writes the prepared-suite artifact for the active run
- all manifests applied through `harness run apply`
- all commands (inspect, curl, delete, kubectl get, etc.) recorded via `harness run record`
- cluster state captured after each completed group via `harness run capture`
- `run-status.json` updated after each group with counts and last_completed_group
- all failures trigger immediate triage before next group
- all pass/fail decisions include artifact pointers to existing files
- deviations from suite definitions require user approval and are recorded in the report
- manifest errors trigger user choice: fix for run only, fix in suite (with `amendments.md` entry), or skip
- manifests in per-group directories (`groups/g{NN}/`) are authoritative - the runner applies them via `harness run apply --manifest g{NN}` during Phase 4
- Mesh\* policy suites include the edge cases from [Mesh\* policy suite requirements](#mesh-policy-suite-requirements)

## Reference

- Suite directory format: described in this file
- Example suite: [../examples/example-motb-core-suite.md](../examples/example-motb-core-suite.md)
- Mesh\* policy edge cases: described in this file
