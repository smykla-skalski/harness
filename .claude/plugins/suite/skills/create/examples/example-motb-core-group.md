---
group_id: g01
story: Verify the policy under test can be configured, observed, and debugged.
capability: Example CRUD baseline
profiles:
  - single-zone
preconditions:
  - Baseline manifests are applied.
success_criteria:
  - The policy under test is accepted.
  - The dataplane config dump references the expected backend cluster.
debug_checks:
  - inspect dataplane
  - inspect config-dump
artifacts:
  - artifacts/g01/policy.yaml
  - artifacts/g01/config-dump.txt
variant_source: base
helm_values:
  dataPlane.features.unifiedResourceNaming: true
restart_namespaces:
  - kuma-demo
---

# G1 - CRUD baseline

## Configure

Apply the whole group manifest directory:

```bash
harness run apply --manifest g01
```

Or apply a specific file:

```bash
harness run apply --manifest g01/01-demo-metrics.yaml
```

The YAML manifests live in the `groups/g01/` directory (e.g., `g01/01-demo-metrics.yaml`). Do not duplicate them inline here.

## Consume

```bash
harness run record --phase verify --label get-demo-metrics \
  -- kubectl get meshmetrics demo-metrics -n kuma-system -o yaml

harness run record --phase verify --label inspect-dataplanes \
  -- kumactl inspect dataplanes --mesh default
```

Expected outcome: the policy is accepted and the captured dataplane wiring reflects the configured backend.

## Debug

```bash
harness run envoy capture --phase debug --label config-dump \
  --namespace kuma-demo --workload deploy/demo-client

harness run record --phase debug --label control-plane-logs \
  -- kubectl logs -n kuma-system deploy/kuma-control-plane --tail=50
```

Capture these artifacts if the expected backend cluster is missing or the policy is rejected unexpectedly.
