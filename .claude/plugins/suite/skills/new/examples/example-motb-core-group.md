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

File: g01/01-demo-metrics.yaml

```yaml
apiVersion: kuma.io/v1alpha1
kind: MeshMetric
metadata:
  name: demo-metrics
  namespace: kuma-system
  labels:
    kuma.io/mesh: default
spec:
  targetRef:
    kind: Mesh
  default:
    applications:
      - path: /metrics
        port: 8080
    backends:
      - type: Prometheus
        prometheus:
          clientId: demo-prom
          path: /metrics
          port: 5670
```

The same manifest is pre-written at `g01/01-demo-metrics.yaml`. Phase 4 applies it via `harness apply --manifest g01` (whole directory) or `harness apply --manifest "g01/01-demo-metrics.yaml"` (single file). `harness preflight` also extracts the inline block above as a fallback.

## Consume

```bash
harness run --phase verify --label get-demo-metrics \
  kubectl get meshmetrics demo-metrics -n kuma-system -o yaml

harness run --phase verify --label inspect-dataplanes \
  kumactl inspect dataplanes --mesh default
```

Expected outcome: the policy is accepted and the captured dataplane wiring reflects the configured backend.

## Debug

```bash
harness envoy capture --phase debug --label config-dump \
  --namespace kuma-demo --workload deploy/demo-client

harness run --phase debug --label control-plane-logs \
  kubectl logs -n kuma-system deploy/kuma-control-plane --tail=50
```

Capture these artifacts if the expected backend cluster is missing or the policy is rejected unexpectedly.
