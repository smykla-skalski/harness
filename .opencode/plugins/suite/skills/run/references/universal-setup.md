# Universal mode setup

# Contents

1. [Topologies](#topologies)
2. [Cluster lifecycle](#cluster-lifecycle)
3. [Store backend](#store-backend)
4. [Image override](#image-override)
5. [Token generation](#token-generation)
6. [Service containers](#service-containers)
7. [Manifest format](#manifest-format)
8. [Capture](#capture)
9. [Docker network](#docker-network)
10. [Templates](#templates)

---

Universal mode runs Kuma components as Docker containers instead of Kubernetes pods.
Policies use REST API format (type/name/mesh) instead of K8s resources (apiVersion/kind/metadata).

Harness routes universal container work through `ContainerRuntime`. The default backend is Bollard (`HARNESS_CONTAINER_RUNTIME=bollard` or unset). `HARNESS_CONTAINER_RUNTIME=docker-cli` keeps the CLI-backed fallback for debugging or rollout safety.

## Topologies

All topologies supported on K8s are also available on universal:

- **single-zone**: one CP container
- **global+zone**: global CP + zone CP containers
- **global+two-zones**: global CP + two zone CP containers

## Cluster lifecycle

### Single-zone

```
harness setup kuma cluster --platform universal single-up <cp-name>
harness setup kuma cluster --platform universal single-down <cp-name>
```

### Global+zone

```
harness setup kuma cluster --platform universal global-zone-up <global> <zone> <zone-label>
harness setup kuma cluster --platform universal global-zone-down <global> <zone>
```

### Global+two-zones

```
harness setup kuma cluster --platform universal global-two-zones-up <global> <zone1> <zone2> <z1-label> <z2-label>
harness setup kuma cluster --platform universal global-two-zones-down <global> <zone1> <zone2>
```

## Store backend

Default is memory. For postgres:

```
harness setup kuma cluster --platform universal --store postgres single-up <cp-name>
```

## Image override

By default, harness looks for a locally-built `kuma-cp` Docker image. To override:

```
harness setup kuma cluster --platform universal --image kumahq/kuma-cp:2.9.0 single-up <cp-name>
```

If the selected image is missing locally, harness auto-pulls it through the active container runtime backend before starting the container.

## Token generation

Generate dataplane tokens for service containers:

```
harness run kuma token dataplane --name demo-app --mesh default
harness run kuma token ingress --name zone-ingress --mesh default
```

Auto-detects CP address from run context. Override with `--cp-addr http://host:5681`.

The command tries the CP REST API (POST to /tokens/dataplane) first, falling back to kumactl.

## Service containers

Start test service containers with automatic token injection and sidecar setup:

```
harness run kuma service up demo-app --image kuma-dp:latest --port 5050 --mesh default
harness run kuma service up demo-app --image kuma-dp:latest --port 5050 --transparent-proxy
harness run kuma service down demo-app
harness run kuma service list
```

Service up:
1. Generates a dataplane token via CP API
2. Renders dataplane YAML from template (resources/universal/templates/)
3. Starts the container on the Docker network
4. Writes token and dataplane YAML into the container
5. Optionally installs transparent proxy
6. Starts kuma-dp with the token and dataplane file

## Manifest format

Universal manifests use `type`/`name`/`mesh` instead of `apiVersion`/`kind`/`metadata`:

```yaml
type: MeshTrafficPermission
mesh: default
name: allow-all
spec:
  targetRef:
    kind: Mesh
  from:
    - targetRef:
        kind: Mesh
      default:
        action: Allow
```

Apply with `harness run apply --manifest <path>`. In universal mode this uses `kumactl apply -f` instead of `kubectl apply -f`.

Validate with `harness run validate --manifest <path>`. Universal validation checks for required type/name/mesh fields locally without a cluster round-trip.

## Capture

`harness run capture --label <label>` in universal mode collects:
- Docker container state via `docker ps`
- Dataplane resources from CP API (GET /meshes/default/dataplanes)

Both are combined into a single JSON capture file.

## Docker network

Single-container universal runs create a bridge network named `harness-<cp-name>` with subnet `172.57.0.0/16`.

Compose-backed universal runs keep the logical harness network name in the compose spec, but the actual Engine network name follows Docker Compose naming: `<project>_<network>`, for example `harness-global-cp_harness-global-cp`.

Harness now persists that real runtime network name in run state. Use `harness run status` or `harness run cluster-check` instead of guessing the Engine network name from the cluster name.

## Templates

Dataplane YAML templates live in `resources/universal/templates/`:
- `dataplane.yaml.j2` - standard service dataplane
- `dataplane-gateway.yaml.j2` - gateway dataplane variant
- `zone-ingress.yaml.j2` - zone ingress resource
- `zone-egress.yaml.j2` - zone egress resource
- `transparent-proxy.yaml.j2` - transparent proxy config

Templates are rendered with minijinja using variables: name, mesh, address, port, protocol.
