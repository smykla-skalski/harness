# Contents

1. [Discovery workers](#discovery-workers)
2. [Inventory payload](#inventory-payload)
3. [Coverage summary](#coverage-summary)
4. [Variant summary](#variant-summary)
5. [Schema summary](#schema-summary)
6. [Writer workers](#writer-workers)
7. [Writer launch contract](#writer-launch-contract)
8. [Writer recovery (partial completion)](#writer-recovery-partial-completion)
9. [Output constraints](#output-constraints)

---

# Agent output format

Structured payload contract for the dedicated `suite:create` workers. Discovery workers save compact JSON through `harness create save`. Writer workers load saved state with `harness create show` and only acknowledge completion.

## Discovery workers

- `coverage-reader` saves `--kind coverage`
- `variant-analyzer` saves `--kind variants`
- `schema-verifier` saves `--kind schema`

Discovery workers read only the scoped files from the parent prompt. They must not dump raw file contents, code blocks longer than 5 lines, or long prose summaries.

## Inventory payload

Before launching discovery workers, the main `suite:create` flow saves the scoped repository inventory with `harness create save --kind inventory`.

Use this exact JSON shape:

```json
{
  "scoped_files": [
    "/abs/path/to/file.go",
    "/abs/path/to/validator.go"
  ]
}
```

`scoped_files` is the only required field. A free-form inventory summary is intentionally not part of this payload because the inventory is just the bounded file set for later workers.

## Coverage summary

One entry per applicable group G1-G7:

- G1 CRUD: struct fields, markers, validation constraints from API spec
- G2 Validation: rejection paths from validator.go
- G3 Runtime config: xDS resource types and Apply() logic from plugin.go
- G4 E2E flow: expected Envoy configs from golden files
- G5 Edge cases: nil handling, boundary values, dangling refs
- G6 Multi-zone: KDS markers, sync config presence
- G7 Backward compat: deprecated fields, legacy paths

For each group entry include a one-line description, supporting source file path, and whether enough material exists to generate the group.

## Variant summary

One entry per detected signal:

- id: S1-S7
- type: deployment-topology / feature-mode / backend-variant / feature-flag / policy-role / protocol-variant / backward-compat
- source: file path or line range
- evidence: one-line description of what was found
- strength: strong / moderate / weak

## Schema summary

Collected for manifest verification in the generation step:

- CRD scope: Namespaced or Cluster (from `deployments/charts/kuma/crds/`)
- Policy scope: Mesh or Global (from `+kuma:policy:scope=` marker)
- Spec nesting pattern: from-based (`spec.from[].default`), to-based (`spec.to[].default`), or rules-based (`spec.rules[].default`). Identify by checking which top-level fields exist in the Go spec struct (`From *[]From`, `To *[]To`, `Rules *[]Rule`). See [Policy spec nesting patterns](code-reading-guide.md#policy-spec-nesting-patterns) in the code reading guide.
- Spec field tree: JSON field names at each nesting level (from Go struct JSON tags)
- Enum fields: field path and allowed values (from `+kubebuilder:validation:Enum=` markers)
- Required fields: non-pointer fields without `omitempty`
- targetRef valid kinds: what `kind` values are accepted in targetRef (from the `From`/`To`/`TargetRef` definitions)
- Save each schema fact with a `required_fields` key. Use `[]` when no required fields exist

## Writer workers

- `suite-writer` writes only `suite.md`
- `baseline-writer` writes only `baseline/*.yaml`
- `group-writer` writes only its assigned `groups/*.md`

Writer workers must:

- load saved state with `harness create show`
- honor the exact file ownership from the parent prompt
- if the local validator is enabled for this environment, validate owned manifests with `harness create validate` before stopping
- use the current repo checkout as the schema source of truth; the required schemas and CRDs are already checked into this repo
- return only a short acknowledgement such as `suite draft saved`

## Writer launch contract

- Pass only the saved proposal, schema facts, and the exact file ownership for that worker.
- Keep writer fan-out bounded. Do not start more than four writer workers at once.
- Launch all writer workers with `mode: "auto"` so they can write files without interactive approval. Background workers cannot prompt the user, so writes are denied without this mode.
- The group-writer must create a `groups/{group-id}/` directory for each group and write the group's test manifests there as individual YAML files (e.g., `groups/g01/01-create.yaml`, `groups/g01/02-update.yaml`). The group markdown's `## Configure` section must NOT contain inline YAML blocks. Instead it should contain only `harness run apply` commands that reference the manifest directory (e.g., `harness run apply --manifest g01` for the whole directory or `harness run apply --manifest g01/01-create.yaml` for a single file). The YAML lives only in the `groups/g{NN}/` directory.
- Require every writer that emits manifests to run `harness create validate --path <file>` on its owned outputs before it stops. Use the current repo checkout as the schema source of truth; all required schemas, including CRDs, are already in this repo. Do not substitute a live-cluster check.
- When the proposal includes multi-zone profiles, pass the baseline cluster distribution from the proposal to the baseline-writer and suite-writer so they emit the object form (`- path:` with `clusters:`) in `baseline_files` frontmatter and include the Clusters column in the baseline manifests table.

## Writer recovery (partial completion)

When a writer worker finishes but some expected files are missing (partial failure or timeout), the main context must recover without re-launching a full worker. Before writing any file that may already exist on disk from a partial worker run, Read it first. Claude Code tracks file state internally - writing a file that exists on disk but was never Read in the current context triggers "File has been modified since read" errors. The recovery sequence is:

1. Run `ls "${SUITE_DIR}/groups/"` to see which files the worker already created.
2. For every file that exists on disk but still needs to be written or overwritten, Read it first, then Write the corrected content.
3. For files that do not exist yet, Write them directly (no Read needed).
4. Never attempt to Write a batch of files without checking which ones already exist. The subagent's writes are invisible to the parent context's file tracker.

## Output constraints

Discovery workers return only the structured summary above because raw code bloats the main context and degrades generation quality in later steps. Workers must NOT return:

- Raw file contents or full function bodies
- Code blocks longer than 5 lines
- Golden file text or test fixture dumps, because those dumps crowd out the schema and variant evidence the main workflow actually needs
