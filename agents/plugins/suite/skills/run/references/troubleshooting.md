# Contents

1. [Pods do not schedule](#1-pods-in-non-system-namespaces-do-not-schedule)
2. [Schema rejected](#2-resource-schema-rejected-before-business-validation)
3. [Wrong kumactl](#3-wrong-kumactl-behavior)
4. [Workload crashes](#4-dependency-workload-crashes-after-start)
5. [Missing xDS config](#5-expected-xds-config-not-visible)
6. [Stale after redeploy](#6-changes-not-reflected-after-redeploy)
7. [Multi-zone sync](#7-multi-zone-sync-unclear)
8. [Leftovers](#8-unexpected-leftovers-after-redeploy)
9. [KDS connection](#9-zone-cannot-connect-to-global-kds)
10. [MetalLB file missing](#10-k3dstart-fails-for-kuma-3-with-missing-metallb-file)
11. [Disk pressure on k3d node](#11-disk-pressure-on-k3d-node)
12. [Prepared manifest stale after suite-fix](#12-prepared-manifest-stale-after-suite-fix)
13. [Run state looks stale or contradictory](#13-run-state-looks-stale-or-contradictory)
14. [Failure triage checklist](#failure-triage-checklist)
15. [ContainerPatch value must be JSON string](#15-containerpatch-value-must-be-json-string)
16. [Init container CPU throttling on k3d](#16-init-container-cpu-throttling-on-k3d-auto-fixed)

---

# Troubleshooting

Known local failure modes and fixes.

For policy matching and inspect workflow, use [mesh-policies.md](mesh-policies.md).

## 1) Pods in non-system namespaces do not schedule

Symptoms: workloads stay Pending, CNI-related scheduling issues.

Fix:

```bash
K3D_HELM_DEPLOY_NO_CNI=true CLUSTER=kuma-1 make k3d/cluster/deploy/helm
```

## 2) Resource schema rejected before business validation

Symptoms: `harness run validate` or `harness run apply` fails with CRD required-field or enum errors.

Fix:

1. Run server-side dry-run with `harness run validate`.
2. Re-run Phase 2 bootstrap for the affected cluster profile with `harness setup kuma cluster`, then re-run preflight. Avoid ad-hoc CRD refresh commands during a tracked run because bare `kubectl apply` is outside the harness contract.
3. Retry validation.

## 3) Wrong kumactl behavior

Symptoms: unknown resource types, missing command support for newer resources.

Fix:

```bash
harness run record --phase debug --label kumactl-version \
  -- kumactl version
```

Use `harness run record ... -- kumactl ...` for tracked local version and inspect commands so they stay audited and captured.

## 4) Dependency workload crashes after start

Symptoms: supporting workload pod CrashLoopBackOff, startup logs show invalid configuration.

Fix: fix config according to pod logs, then re-apply tracked manifest.

## 5) Expected xDS config not visible

Symptoms: expected filters/clusters/listeners are missing.

Checks:

- Verify policy target selectors match the intended dataplanes
- Verify service protocol annotations when HTTP-specific behavior is expected
- Verify listeners are generated in expected mode (HCM vs TCP proxy)

## 6) Changes not reflected after redeploy

Symptoms: xDS/config does not match latest code.

Fix:

1. Redeploy with local build target.
2. Restart test workloads to refresh sidecars and certs.
3. Capture state snapshot and compare timestamps.

## 7) Multi-zone sync unclear

Symptoms: resource present on global but absent on zone.

Checks:

- Zone connection status is Online
- Correct KDS global address configured
- `kuma.io/origin` and `kuma.io/display-name` labels preserved

## 8) Unexpected leftovers after redeploy

Symptoms: behavior looks like old resources are still active.

Root cause: default lifecycle mode keeps helm release and namespace for speed.

Fix:

```bash
HARNESS_HELM_CLEAN=1 \
  harness setup kuma cluster single-up kuma-1
```

Then rerun preflight and continue tests.

## 9) Zone cannot connect to global KDS

Symptoms: zone CP logs show `dial tcp <cluster-ip>:5685: i/o timeout`.

Root cause: using global cluster service ClusterIP in `controlPlane.kdsGlobalAddress`.

Fix: expose global sync service as NodePort and use `grpcs://<global-node-ip>:<node-port>` instead of the service ClusterIP.

## 10) k3d cluster bootstrap fails around MetalLB networking

Symptoms: `k3d/cluster/start` fails while rendering or applying MetalLB resources.

Root cause: Kuma no longer uses static `mk/metallb-k3d-*.yaml` files. MetalLB is rendered dynamically from the shared Docker network and the cluster number.

Fix: use `harness setup kuma cluster` or the new manual contract:

```bash
CLUSTER=kuma-3 make k3d/cluster/start
```

Do not create or patch `mk/metallb-k3d-*.yaml` files by hand.

## 11) Remote Kubernetes setup fails before Helm deploy

Symptoms: `harness setup kuma cluster --provider remote ...` fails before deploy with missing push flags, missing repo publish targets, or kubeconfig flatten/reachability errors.

Fix:

- verify `harness setup capabilities` reports `readiness.providers.remote.ready=true`
- confirm the Kuma checkout still exposes `images/release`, `docker/push`, and `manifests/json/release`
- rerun with explicit `--remote`, `--push-prefix`, and `--push-tag`
- validate each source kubeconfig and context with `kubectl --kubeconfig <path> config get-contexts`

## 12) Disk pressure on k3d node

Symptoms: pods stuck in Pending/Evicted, node shows `DiskPressure=True`, `kubectl describe node` reports kubelet disk pressure.

Root cause: old kumahq/* Docker images (~1GB each, 6 images per build) and dangling volumes accumulate across test runs. After ~20 builds, Docker storage exceeds 80% and k3d's overlayfs triggers kubelet disk pressure.

Fix:

```bash
docker system prune -a --volumes -f
```

After pruning, all kumahq/* images are gone. The k3d cluster nodes will show `ImagePullBackOff` because they reference images that no longer exist in Docker. You must rebuild and reload images into the cluster before continuing:

```bash
K3D_HELM_DEPLOY_NO_CNI=true make k3d/cluster/deploy/helm CLUSTER=kuma-1 \
  K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS="<your helm settings>"
```

This triggers a full build cycle (images + load + helm upgrade). After the deploy, restart test workloads to pick up the new sidecar images.

Prevention: `HARNESS_DOCKER_PRUNE=1` (default) in `harness setup kuma cluster` prunes old kumahq/* images before each build. The preflight script also warns when >30 kumahq/* images or >50 dangling volumes exist.

## 13) Prepared manifest stale after suite-fix

Symptoms: after choosing "Fix in suite and this run", the re-applied manifest still has the old broken content. The suite source file is correct but the prepared copy in `runs/<run-id>/manifests/prepared/` was not updated.

Fix: re-materialize the prepared manifest before re-applying. Use `harness run apply --manifest <path> --step <label>` which reads from the suite source, not from the stale prepared copy. Alternatively, copy the fixed file to the prepared directory before re-applying:

```bash
cp <fixed-suite-source-file> runs/<run-id>/manifests/prepared/<matching-path>
```

## 14) Run state looks stale or contradictory

Symptoms: `resume` cannot attach, `run-status.json` disagrees with the report, the current-run pointer targets the wrong run, or harness reports a final verdict with a non-final workflow phase.

Fix:

```bash
harness run doctor --run-dir runs/<run-id>
harness run repair --run-dir runs/<run-id>
```

Use `doctor` first to inspect what is wrong. Use `repair` only for deterministic state fixes that harness can rebuild safely. Do not edit `run-status.json`, `suite-run-state.json`, or `current-run.json` by hand.

## 16. ContainerPatch value must be JSON string

ContainerPatch `sidecarPatch` entries use JSON patch format. The `value` field must be a JSON string, not a YAML object:

Wrong (strict decoding error: unknown field "name", "value"):
```yaml
- op: add
  path: /env/-
  value:
    name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://collector:4317"
```

Correct:
```yaml
- op: add
  path: /env/-
  value: '{"name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": "http://collector:4317"}'
```

This applies to all Kuma resources that use JSON patch operations (ContainerPatch, ProxyTemplate). The CRD enforces strict decoding - nested YAML objects under `value` produce "unknown field" errors even though the intent is clear.

## 16) Init container CPU throttling on k3d (auto-fixed)

Symptoms: pods stuck at `Init:0/1` for 2-4 minutes, `kuma-init` container shows high CPU throttle count in `kubectl describe pod`.

Root cause: k3d clusters inherit tight cgroup CPU limits. Kuma's default init container resource limits (`100m` CPU) get throttled by the container runtime, stalling iptables setup.

Fix: harness injects these helm values automatically during every k8s cluster bootstrap (`single-up`, `global-zone-up`, `global-two-zones-up`):

```
runtime.kubernetes.injector.initContainer.resources.limits.cpu=0
runtime.kubernetes.injector.initContainer.resources.requests.cpu=10m
```

Setting the CPU limit to `0` removes it entirely. No manual action needed - `harness setup kuma cluster` handles this for all k3d deployments.

If you are deploying outside harness and hit this, pass the settings via `K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS` or `--helm-setting`:

```bash
harness setup kuma cluster single-up kuma-1 \
  --helm-setting "runtime.kubernetes.injector.initContainer.resources.limits.cpu=0" \
  --helm-setting "runtime.kubernetes.injector.initContainer.resources.requests.cpu=10m"
```

## Failure triage checklist

When a test fails:

1. Run `harness run capture` immediately with label `failure-<test-id>`.
2. Record exact failing command in command log.
3. Record expected vs observed behavior.
4. Classify root cause: **suite bug** (wrong manifest/expectations), **product bug** (Kuma vs spec), **harness bug** (infra misconfiguration), or **environment issue** (timing/resources).
5. If the symptoms look like run-state drift instead of product behavior, run `harness run doctor` before making a manual fix.
6. Do not continue until classification is explicit and user approves via AskUserQuestion.
