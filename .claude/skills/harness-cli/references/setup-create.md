# `setup` and `create` references

## `setup` command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `setup bootstrap` | Install or refresh the repo-aware harness wrapper and write agent bootstrap config | `--project-dir <PROJECT_DIR>`, `--agents <AGENTS>...` |
| `setup agents` | Setup entrypoint for harness-managed agent asset commands | Subcommand: `generate` |
| `setup agents generate` | Generate checked-in multi-agent skills and plugin assets | `--check`, `--target <TARGET>` |
| `setup kuma` | Kuma-specific setup entrypoint | Subcommand: `cluster` |
| `setup gateway` | Check, install, or uninstall Gateway API CRDs | `--kubeconfig`, `--repo-root`, `--check-only`, `--uninstall` |
| `setup capabilities` | Emit a structured capabilities/readiness report for planning | `--project-dir`, `--repo-root` |

Sources: `cargo run --quiet -- setup --help`; `cargo run --quiet -- setup agents --help`; `src/app/cli.rs:82-94`; `src/setup/bootstrap.rs:16-24`; `src/setup/agents.rs:7-35`; `src/setup/kuma.rs:8-27`; `src/setup/gateway.rs:35-50`; `src/setup/capabilities.rs:22-42`.

## `setup` key help surface

| Command | Flags / arguments | Notes |
| --- | --- | --- |
| `harness setup bootstrap` | `--project-dir <PROJECT_DIR>`, `--agents <AGENTS>...` | `--agents` defaults to all supported agents; valid values in help include `copilot` |
| `harness setup agents` | `<COMMAND>`, `--delay <DELAY>` | Direct entrypoint; help currently exposes `generate` |
| `harness setup agents generate` | `--check`, `--target <TARGET>` | `--target` defaults to `all` |
| `harness setup kuma` | Subcommand `cluster` | Use `harness setup kuma cluster --help` for lifecycle flags |
| `harness setup kuma cluster` | `<MODE> <CLUSTER_NAME> [EXTRA_CLUSTER_NAMES]...`, `--platform`, `--provider`, `--repo-root`, `--run-dir`, `--helm-setting`, `--remote`, `--push-prefix`, `--push-tag`, `--namespace`, `--release-name`, `--restart-namespace`, `--store`, `--image`, `--no-build`, `--no-load` | Modes in help: `single-up`, `single-down`, `global-zone-up`, `global-zone-down`, `global-two-zones-up`, `global-two-zones-down` |
| `harness setup gateway` | `--kubeconfig`, `--repo-root`, `--check-only`, `--uninstall` | `--check-only` and `--uninstall` are mutually exclusive in source |
| `harness setup capabilities` | `--project-dir`, `--repo-root` | Prints JSON |

Sources: `cargo run --quiet -- setup bootstrap --help`; `cargo run --quiet -- setup agents --help`; `cargo run --quiet -- setup agents generate --help`; `cargo run --quiet -- setup kuma --help`; `cargo run --quiet -- setup kuma cluster --help`; `cargo run --quiet -- setup gateway --help`; `cargo run --quiet -- setup capabilities --help`; `src/setup/bootstrap.rs:36-54`; `src/setup/gateway.rs:76-142`; `src/setup/capabilities.rs:33-42`.

## Canonical `setup` shortcuts

| Use case | Command |
| --- | --- |
| Copilot bootstrap path | `harness setup bootstrap --agents copilot` |
| Asset sync / drift check | `harness setup agents generate --check` |

Sources: `cargo run --quiet -- setup bootstrap --help`; `cargo run --quiet -- setup agents generate --help`.

## `create` command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `create begin` | Begin a `suite:create` workspace session | `--repo-root`, `--feature`, `--mode`, `--suite-dir`, `--suite-name` |
| `create save` | Save a `suite:create` payload | `--kind`, `--payload`, `--input` |
| `create show` | Show saved `suite:create` payloads | `--kind` |
| `create reset` | Reset the `suite:create` workspace | No extra flags |
| `create validate` | Validate authored manifests against local CRDs | `--path`, `--repo-root` |
| `create approval-begin` | Begin the `suite:create` approval flow | `--mode`, `--suite-dir` |

Sources: `cargo run --quiet -- create --help`; `src/app/cli.rs:70-80`; `src/create/commands/begin.rs:19-55`; `src/create/commands/save.rs:13-36`; `src/create/commands/show.rs:13-39`; `src/create/commands/reset.rs:13-23`; `src/create/commands/validate.rs:13-33`; `src/create/commands/approval.rs:17-37`.

## `create` key help surface

| Command | Flags | Notes |
| --- | --- | --- |
| `harness create begin` | `--repo-root`, `--feature`, `--mode`, `--suite-dir`, `--suite-name` | `--mode` values: `interactive`, `bypass` |
| `harness create save` | `--kind`, `--payload`, `--input` | Help exposes kinds: `inventory`, `coverage`, `variants`, `schema`, `proposal`, `edit-request` |
| `harness create show` | `--kind` | Reads a saved payload kind |
| `harness create reset` | none | Clears the workspace/session state |
| `harness create validate` | `--path`, `--repo-root` | `--path` is repeatable and required |
| `harness create approval-begin` | `--mode`, `--suite-dir` | `--mode` values: `interactive`, `bypass` |

Sources: `cargo run --quiet -- create begin --help`; `cargo run --quiet -- create save --help`; `cargo run --quiet -- create show --help`; `cargo run --quiet -- create reset --help`; `cargo run --quiet -- create validate --help`; `cargo run --quiet -- create approval-begin --help`.
