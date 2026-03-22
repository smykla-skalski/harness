# Contents

1. [Prerequisites](#prerequisites)
2. [Kubeconfig mapping](#kubeconfig-mapping)
3. [Profiles](#profiles)
4. [Build and deploy local code changes](#build-and-deploy-local-code-changes)
5. [CRD updates](#crd-updates)
6. [Baseline readiness validation](#baseline-readiness-validation)

---

# Cluster setup

Cluster lifecycle commands for harness-managed Kubernetes and universal test environments.

## Prerequisites

- `harness setup capabilities` reports the requested profile as ready
- Docker Engine reachable for universal profiles and Docker-backed local workflows
- `kubectl`, `helm`, `make` installed
- `k3d` installed for local Kubernetes provider runs
- `REPO_ROOT` resolved (via `--repo` flag or auto-detected from cwd)
- Remote Kubernetes provider runs also need explicit `--remote` mappings plus `--push-prefix` and `--push-tag`

`HARNESS_CONTAINER_RUNTIME` defaults to `bollard`. Leave it unset for the normal Engine API backend. Set `HARNESS_CONTAINER_RUNTIME=docker-cli` only to force the CLI-backed fallback. When using the default backend, missing `docker` on `PATH` does not block universal readiness by itself.

## Kubeconfig mapping

Local k3d provider:

| Cluster | Role | Kubeconfig file |
| ------- | ---- | --------------- |
| `kuma-1` | single-zone or global | `${HOME}/.kube/k3d-kuma-1.yaml` |
| `kuma-2` | zone-1 | `${HOME}/.kube/k3d-kuma-2.yaml` |
| `kuma-3` | zone-2 | `${HOME}/.kube/k3d-kuma-3.yaml` |

Remote provider:

- pass source kubeconfigs with repeatable `--remote name=<cluster>,kubeconfig=<path>[,context=<ctx>]`
- harness flattens them into tracked generated kubeconfigs under its session state
- after `harness run start`, rely on the active run context instead of exporting `KUBECONFIG` manually

## Profiles

### Single-zone

```bash
harness setup kuma cluster single-up kuma-1
```

Remote equivalent:

```bash
harness setup kuma cluster \
  --provider remote \
  --remote name=kuma-1,kubeconfig=/path/to/kuma-1.yaml[,context=kuma-1] \
  --push-prefix ghcr.io/acme/kuma \
  --push-tag branch-dev \
  single-up kuma-1
```

Manual equivalent:

```bash
CLUSTER=kuma-1 make k3d/cluster/start
K3D_HELM_DEPLOY_NO_CNI=true CLUSTER=kuma-1 make k3d/cluster/deploy/helm
```

Stop:

```bash
CLUSTER=kuma-1 make k3d/cluster/stop
```

### Global + one zone

```bash
harness setup kuma cluster global-zone-up kuma-1 kuma-2 zone-1
```

Remote equivalent:

```bash
harness setup kuma cluster \
  --provider remote \
  --remote name=kuma-1,kubeconfig=/path/to/kuma-1.yaml[,context=global] \
  --remote name=kuma-2,kubeconfig=/path/to/kuma-2.yaml[,context=zone-1] \
  --push-prefix ghcr.io/acme/kuma \
  --push-tag branch-dev \
  global-zone-up kuma-1 kuma-2 zone-1
```

Manual equivalent for global:

```bash
CLUSTER=kuma-1 make k3d/cluster/start
KUBECONFIG="${HOME}/.kube/k3d-kuma-1.yaml" \
  K3D_HELM_DEPLOY_NO_CNI=true \
  CLUSTER=kuma-1 \
  KUMA_MODE=global \
  K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS="controlPlane.mode=global controlPlane.globalZoneSyncService.type=NodePort" \
  make k3d/cluster/deploy/helm
```

Manual equivalent for zone:

```bash
GLOBAL_NODE_IP=$(docker inspect k3d-kuma-1-server-0 \
  -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

GLOBAL_KDS_PORT=$(KUBECONFIG="${HOME}/.kube/k3d-kuma-1.yaml" kubectl get svc \
  -n kuma-system kuma-global-zone-sync \
  -o jsonpath='{.spec.ports[?(@.name=="global-zone-sync")].nodePort}')

GLOBAL_KDS="grpcs://${GLOBAL_NODE_IP}:${GLOBAL_KDS_PORT}"

CLUSTER=kuma-2 make k3d/cluster/start
KUBECONFIG="${HOME}/.kube/k3d-kuma-2.yaml" \
  K3D_HELM_DEPLOY_NO_CNI=true \
  CLUSTER=kuma-2 \
  KUMA_MODE=zone \
  K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS="controlPlane.mode=zone controlPlane.zone=zone-1 controlPlane.kdsGlobalAddress=${GLOBAL_KDS} controlPlane.tls.kdsZoneClient.skipVerify=true" \
  make k3d/cluster/deploy/helm
```

### Global + two zones

```bash
harness setup kuma cluster global-two-zones-up kuma-1 kuma-2 kuma-3 zone-1 zone-2
```

Remote equivalent:

```bash
harness setup kuma cluster \
  --provider remote \
  --remote name=kuma-1,kubeconfig=/path/to/kuma-1.yaml[,context=global] \
  --remote name=kuma-2,kubeconfig=/path/to/kuma-2.yaml[,context=zone-1] \
  --remote name=kuma-3,kubeconfig=/path/to/kuma-3.yaml[,context=zone-2] \
  --push-prefix ghcr.io/acme/kuma \
  --push-tag branch-dev \
  global-two-zones-up kuma-1 kuma-2 kuma-3 zone-1 zone-2
```

Stop all:

```bash
CLUSTER=kuma-1 make k3d/cluster/stop
CLUSTER=kuma-2 make k3d/cluster/stop
CLUSTER=kuma-3 make k3d/cluster/stop
```

## Build and deploy local code changes

The lifecycle script handles build, image load, and helm deploy in one step.

For remote provider runs, harness uses the Kuma repo publish contract to build and push images, then deploys them with Helm against the tracked generated kubeconfigs.

For manual control:

```bash
make build
K3D_HELM_DEPLOY_NO_CNI=true CLUSTER=kuma-1 make k3d/cluster/deploy/helm
```

## CRD updates

After CRD/schema changes, force-update CRDs:

Do not refresh CRDs with a bare `kubectl apply` during a tracked run. If CRDs changed, recreate the affected cluster profile with `harness setup kuma cluster` and rerun `harness run preflight` plus `harness run capture --label preflight`.

## Gateway API CRDs

Suites that test builtin gateways (MeshGateway, GatewayClass, HTTPRoute) or compare builtin vs delegated gateways need the Kubernetes Gateway API CRDs installed. These are not included in Kuma's CRD bundle - they come from the upstream `gateway-api` project.

Check and install:

```bash
# Check if installed
harness setup gateway --check-only

# Install (idempotent - skips if already present)
harness setup gateway

# Uninstall what harness installed
harness setup gateway --uninstall
```

The script extracts the version from `go.mod` (`sigs.k8s.io/gateway-api`) to stay in sync with the Kuma codebase. It installs the standard CRDs: GatewayClass, Gateway, HTTPRoute, ReferenceGrant.

Install on every cluster that needs it (in multi-zone setups, zones running builtin gateways need the CRDs). In remote mode, pass `--kubeconfig <generated-path>` so harness can record that it owns the install and remove it during teardown if needed.

## Baseline readiness validation

Before test execution on a fresh run, use `harness run start` and then `harness run capture --label preflight` as described in [workflow.md](workflow.md). If cluster/bootstrap drift forces a refresh on an already-created run, use `harness run preflight` and then `harness run capture --label preflight`. These commands prepare the suite once for the active run: they materialize baseline manifests and group `## Configure` YAML into the active run's prepared manifests directory, validate them, apply baselines, and write the prepared-suite artifact before the readiness checks complete. For multi-zone profiles, baselines with `clusters: all` in the suite frontmatter are applied to every cluster in the topology (global + zones), not just the primary cluster. This ensures zone clusters have demo workloads and collectors present for xDS inspection. Use those tracked artifacts instead of ad-hoc `kubectl` readiness checks or per-group manifest copying.

## Notes

- Kuma now renders MetalLB dynamically during `k3d/cluster/start`. Do not create or expect `mk/metallb-k3d-*.yaml` files by hand.
- Performance toggles are documented in [workflow.md](workflow.md) (performance toggles section).
