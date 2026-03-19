# Harness Architecture

Harness is organized by domain first, with a small shared kernel and an explicit workspace layer kept separate from product workflows.

## Top-Level Map

- `src/app/`: Clap entrypoints and command dispatch only. This is the transport layer.
- `src/kernel/`: Pure shared value objects and parsing logic such as command intent and cluster topology.
- `src/workspace/`: Harness-owned ambient state such as XDG paths, session context, and compact handoff state.
- `src/run/`: Everything for tracked suite execution. Run arguments, suite/group specs, persisted report and status codecs, prepared artifacts, workflow state, audit trail, run services, and run commands all live here.
- `src/authoring/`: Everything for `suite:new`. Session payloads, approval workflow, validation, authoring rules, and authoring commands live here.
- `src/observe/`: Session-log observation and classification. CLI args, state, scan/watch modes, classifier rules, and output formats stay together.
- `src/setup/`: Bootstrap, session lifecycle, pre-compact, capability reporting, and cluster setup entrypoints.
- `src/hooks/`: Agent-facing hook protocol, adapters, registry, guards, and effect application.
- `src/platform/`: Provider/runtime adapters and platform-specific helpers such as compose generation, `kubectl_validate`, and ephemeral `MetalLB`.
- `src/infra/`: Generic shared building blocks such as process/docker/http abstractions, raw execution helpers, I/O helpers, and versioned JSON persistence.
- `src/errors/`: Typed error families and rendering.
## Where Concepts Live

- `suite:run`: `src/run/`
- `suite:new`: `src/authoring/`
- observe/reporting: `src/observe/`
- hook protocol and policy: `src/hooks/`
- ambient harness session and project state: `src/workspace/`
- shared command, workflow, and topology primitives: `src/kernel/`
- cluster/runtime adapters: `src/platform/`
- generic execution and persistence helpers: `src/infra/`

## Dependency Rules

- `app` may depend on any domain, but domains must not depend on `app`.
- `kernel` must stay pure and must not depend on `app`, `run`, `authoring`, `observe`, `setup`, `platform`, or `infra`.
- generic cluster topology, cluster-mode parsing, and cluster-state value objects live in `kernel`, not `platform`.
- `workspace` may depend on `kernel`, `infra`, and `errors`, but product domains should treat it as the single owner of ambient session/project state instead of rebuilding that logic locally.
- `run`, `authoring`, `observe`, and `setup` may depend on `platform`, `infra`, `errors`, and `hooks` facades when needed.
- `platform` must not own generic cluster topology or persisted cluster state. It may depend on `kernel`, but not on `app`, `run`, `authoring`, or `observe`.
- `infra` must stay generic and must not depend on product domains.
- The public crate surface is app-first and domain-oriented. Shared internals should be consumed through `kernel` or `workspace` only when they are true cross-domain concepts.

## Borrowing Rule

Persisted DTOs and process-boundary types stay owned. Borrowing work belongs in service and helper APIs: prefer `&str`, `&Path`, borrowed domain views, and `Cow` for transient access instead of cloning owned state through the call stack.
