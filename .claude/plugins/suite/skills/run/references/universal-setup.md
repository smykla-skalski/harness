# Universal mode setup

Universal mode runs Kuma components as Docker containers instead of Kubernetes pods.
Policies use REST API format (type/name/mesh) instead of K8s resources (apiVersion/kind/metadata).

## Topologies

All topologies supported on K8s are also available on universal:

- **single-zone**: one CP container
- **global+zone**: global CP + zone CP containers
- **global+two-zones**: global CP + two zone CP containers

## Cluster lifecycle

### Single-zone

```
harness cluster --platform universal single-up <cp-name>
harness cluster --platform universal single-down <cp-name>
```

### Global+zone

```
harness cluster --platform universal global-zone-up <global> <zone> <zone-label>
harness cluster --platform universal global-zone-down <global> <zone>
```

### Global+two-zones

```
harness cluster --platform universal global-two-zones-up <global> <zone1> <zone2> <z1-label> <z2-label>
harness cluster --platform universal global-two-zones-down <global> <zone1> <zone2>
```

## Store backend

Default is memory. For postgres:

```
harness cluster --platform universal --store postgres single-up <cp-name>
```

## Image override

By default, harness looks for a locally-built `kuma-cp` Docker image. To override:

```
harness cluster --platform universal --image kumahq/kuma-cp:2.9.0 single-up <cp-name>
```

## Token generation

Generate dataplane tokens for service containers:

```
harness token dataplane --name demo-app --mesh default
harness token ingress --name zone-ingress --mesh default
```

Auto-detects CP address from run context. Override with `--cp-addr http://host:5681`.

The command tries the CP REST API (POST to /tokens/dataplane) first, falling back to kumactl.

## Service containers

Start test service containers with automatic token injection and sidecar setup:

```
harness service up demo-app --image kuma-dp:latest --port 5050 --mesh default
harness service up demo-app --image kuma-dp:latest --port 5050 --transparent-proxy
harness service down demo-app
harness service list
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

Apply with `harness apply --manifest <path>`. In universal mode this uses `kumactl apply -f` instead of `kubectl apply -f`.

Validate with `harness validate --manifest <path>`. Universal validation checks for required type/name/mesh fields locally without a cluster round-trip.

## Capture

`harness capture --label <label>` in universal mode collects:
- Docker container state via `docker ps`
- Dataplane resources from CP API (GET /meshes/default/dataplanes)

Both are combined into a single JSON capture file.

## Docker network

Harness creates a bridge network named `harness-<cp-name>` with subnet 172.57.0.0/16. All CP and service containers are attached to this network for direct IP connectivity.

## Templates

Dataplane YAML templates live in `resources/universal/templates/`:
- `dataplane.yaml.j2` - standard service dataplane
- `dataplane-gateway.yaml.j2` - gateway dataplane variant
- `zone-ingress.yaml.j2` - zone ingress resource
- `zone-egress.yaml.j2` - zone egress resource
- `transparent-proxy.yaml.j2` - transparent proxy config

Templates are rendered with minijinja using variables: name, mesh, address, port, protocol.
