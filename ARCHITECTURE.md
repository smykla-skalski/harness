# Harness Architecture

Harness is organized by domain first, with infrastructure and platform code kept separate from product workflows.

## Top-Level Map

- `src/app/`: Clap entrypoints and command dispatch only. This is the transport layer.
- `src/run/`: Everything for tracked suite execution. Run arguments, persisted context, prepared artifacts, workflow state, audit trail, run services, and run commands all live here.
- `src/authoring/`: Everything for `suite:new`. Session payloads, approval workflow, validation, authoring rules, and authoring commands live here.
- `src/observe/`: Session-log observation and classification. CLI args, state, scan/watch modes, classifier rules, and output formats stay together.
- `src/setup/`: Bootstrap, session lifecycle, pre-compact, capability reporting, and cluster setup entrypoints.
- `src/hooks/`: Agent-facing hook protocol, adapters, registry, guards, and effect application.
- `src/platform/`: Cluster/runtime/topology support and platform-specific helpers such as `kubectl_validate` and ephemeral `MetalLB`.
- `src/infra/`: Generic shared building blocks such as process/docker/http abstractions, raw execution helpers, I/O helpers, and versioned JSON persistence.
- `src/errors/`: Typed error families and rendering.
- `src/schema/`: Markdown/frontmatter and persisted document schema parsing shared by the domains above.

## Where Concepts Live

- `suite:run`: `src/run/`
- `suite:new`: `src/authoring/`
- observe/reporting: `src/observe/`
- hook protocol and policy: `src/hooks/`
- cluster/runtime adapters: `src/platform/`
- generic execution and persistence helpers: `src/infra/`

## Dependency Rules

- `app` may depend on any domain, but domains must not depend on `app`.
- `run`, `authoring`, `observe`, and `setup` may depend on `platform`, `infra`, `errors`, `schema`, and `hooks` facades when needed.
- `platform` must not depend on `app`, `run`, `authoring`, or `observe`.
- `infra` must stay generic and must not depend on product domains.
- Legacy flat module paths are temporarily re-exported from `lib.rs` for compatibility, but new code should use the domain-first paths.

## Borrowing Rule

Persisted DTOs and process-boundary types stay owned. Borrowing work belongs in service and helper APIs: prefer `&str`, `&Path`, borrowed domain views, and `Cow` for transient access instead of cloning owned state through the call stack.
