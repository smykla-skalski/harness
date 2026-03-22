# Manifest validation

Pre-apply checks for every resource or policy manifest.

For `Mesh*` policy specifics (roles, `targetRef` rules, inspect flow), read
[mesh-policies.md](mesh-policies.md).

## Pre-apply checklist

- Confirm all `apiVersion` / `kind` pairs exist in the live API by running `harness run validate --manifest "<manifest-file>"` against the prepared manifest. The default native `kube` backend resolves discovery and server-side dry-run without shelling out to `kubectl`.
- Confirm namespace and labels match test intent
- Confirm required fields and enum values are valid for the cluster's CRDs
- If the manifest references other resources, confirm those names exist in the same mesh and expected namespace
- Run server-side dry-run and block on any failure

## Validate

After cluster bootstrap and `harness run start`, `validate` and `apply` read the active run and kubeconfig from `current-run.json`. Fresh sessions restore that active run automatically from saved project state. Do not add explicit path or kubeconfig flags unless debugging a broken run context.

```bash
harness run validate \
  --manifest "<manifest-file>"
```

Validation is not optional. Never bypass it with ad-hoc `kubectl --validate=false` or similar shortcuts. Validation failures indicate a bug in the manifest or missing CRDs. Fix the root cause instead.

The exception is an intentional rejection test defined by the suite itself. When a group keeps a prepared manifest invalid on purpose so Phase 4 can prove the API rejects it, mark that 1-based `## Configure` ordinal in the group frontmatter `expected_rejection_orders`. `harness run preflight` and `harness create validate` will still materialize the manifest, but they will skip the up-front schema validation for that specific prepared entry.

## Safe apply flow

1. If the suite already provides a prepared manifest, reference it via `harness run apply --manifest "<group-id>/<file>"`. Otherwise write the new manifest to the active run's `manifests/` directory resolved from `current-run.json`. Never use `/tmp`. When a suite group provides inline YAML, use it verbatim without modifications.
2. Validate with `harness run validate`.
3. If validation fails, follow the manifest error handling flow below.
4. Apply with `harness run apply`.
5. If apply fails, follow the manifest error handling flow below.
6. Run kubectl verification commands through `harness run record ... -- kubectl ...`, kumactl verification commands through `harness run record ... -- kumactl ...`, Envoy admin inspection through `harness run envoy ...`, and other cluster-touching commands through `harness run record`, saving output to `artifacts/`. Prefer one-command live inspection such as `harness run envoy capture --grep ...`, `harness run envoy capture --type-contains ...`, `harness run envoy route-body`, or `harness run envoy bootstrap` instead of capture-then-read flows.
7. Record artifacts in report. Every artifact path must resolve to a real file.

## Manifest error handling

When a suite manifest fails validation or apply, first move the runner into failure triage:

```bash
harness run runner-state \
  --event failure-manifest
```

Then use AskUserQuestion with this exact first line:

```text
suite:run/manifest-fix: how should this failure be handled?
```

The prompt body must include:

- `Suite target: <relative path within the suite>`
- the validation or apply error message

For baseline manifests (files under `baseline/`), the "Fix in suite and this run" option is NOT available. Baseline fixes are create-time decisions that belong in `suite:create`, not mid-run edits. If a baseline manifest fails validation, this indicates a `suite:create` create defect - record it as a product finding. For baseline manifests, the options must be exactly:

1. **"Fix for this run only"**
2. **"Skip this step"**
3. **"Stop run"**

For all other manifests (group manifests, runtime manifests), the full options apply:

1. **"Fix for this run only"** - Write the corrected manifest to the active run's `manifests/` directory, record a deviation in the run report (what changed, why, user-approved). The suite files stay unchanged. Future runs will hit the same error.

2. **"Fix in suite and this run"** - Fix the manifest in both places:
   - Update the active suite file (the relevant `groups/` file or `baseline/` file) with the corrected YAML.
   - Append an entry to `amendments.md` in the active suite directory (create the file if it doesn't exist). Format:
     ```
     ---

     **<date>** | Run: `<run-id>` | <group>

     - **File**: `<relative path within suite>`
     - **Change**: <what was fixed>
     - **Reason**: <why it was wrong>
     ```
   - Write the corrected manifest to the active run's `manifests/` directory and proceed with apply.
   - Record a deviation in the run report noting both the run fix and the suite amendment.

3. **"Skip this step"** - Skip the step, record it as skipped in the report with the error details.

4. **"Stop run"** - Stop the tracked run immediately. Do not keep mutating suite files or harness code after the stop choice.

Always include the validation/apply error message in the AskUserQuestion description so the user can make an informed decision. Do not attempt to fix manifests without asking first - the error might reveal a real product bug rather than a suite create mistake. `Fix in suite and this run` unlocks edits only for that exact suite file plus `amendments.md`. It never permits edits to harness code, `.claude/skills`, `.claude/agents`, or unrelated repo files.

## Tracked apply example

```bash
harness run apply \
  --manifest "<manifest-file>" \
  --step "<step-name>"
```

This records validation and apply output, writes the tracked manifest entry, and updates manifest and command indexes.
