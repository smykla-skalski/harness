# Harness Architecture

Harness is organized by domain, with a small pure kernel and an explicit workspace layer for ambient state.

## Shape

```mermaid
flowchart LR
    App["app\nCLI transport and wiring"]

    Run["run\nsuite:run domain"]
    Create["create\nsuite:create domain"]
    Observe["observe\nsession observation"]
    Setup["setup\nbootstrap and session lifecycle"]
    Hooks["hooks\nagent-facing policy and protocol"]

    Kernel["kernel\npure shared primitives"]
    Workspace["workspace\nambient harness state"]
    Platform["platform\nruntime and provider adapters"]
    Infra["infra\ngeneric side effects"]
    Errors["errors\ntyped error families"]

    App --> Run
    App --> Create
    App --> Observe
    App --> Setup
    App --> Hooks

    Run --> Kernel
    Run --> Workspace
    Run --> Platform
    Run --> Infra
    Run --> Errors

    Create --> Kernel
    Create --> Workspace
    Create --> Infra
    Create --> Errors

    Observe --> Kernel
    Observe --> Workspace
    Observe --> Infra
    Observe --> Errors

    Setup --> Workspace
    Setup --> Platform
    Setup --> Infra
    Setup --> Errors

    Hooks --> Kernel
    Hooks --> Workspace
    Hooks --> Infra
    Hooks --> Errors

    Platform --> Kernel
    Platform --> Infra
    Workspace --> Kernel
    Workspace --> Infra
```

## Ownership

| Area | Owns |
| --- | --- |
| `src/app/` | Clap entrypoints, top-level command grouping, wiring into domain APIs |
| `src/run/` | tracked run lifecycle, specs, prepared artifacts, reporting, run workflow |
| `src/create/` | `suite:create` payloads, approval workflow, validation, create session state |
| `src/observe/` | session scanning, watch/dump flows, classifier output, observer state |
| `src/setup/` | bootstrap, wrapper/session lifecycle, cluster setup entrypoints |
| `src/hooks/` | hook protocol, normalization, policy input hydration, guards, effects |
| `src/kernel/` | pure shared concepts such as command intent, tool facts, run surface, topology, gates, skill ids |
| `src/workspace/` | XDG paths, session context, current-run pointers, compact handoff, harness-owned ambient files |
| `src/platform/` | provider-specific runtime helpers such as `kubectl_validate`, runtime access, ephemeral `MetalLB` |
| `src/infra/` | generic execution, HTTP, process, persistence, environment, and block abstractions |
| `src/errors/` | typed error families and transport-safe rendering |

## Runtime Flow

```mermaid
sequenceDiagram
    participant U as User or Hook Event
    participant A as app
    participant D as domain
    participant W as workspace
    participant P as platform
    participant I as infra

    U->>A: CLI args or hook payload
    A->>D: typed request
    D->>W: resolve ambient state if needed
    D->>P: ask for runtime-specific translation
    D->>I: execute side effects
    D-->>A: typed result or typed error
    A-->>U: CLI output or hook response
```

## Rules

- `app` is transport only. It may wire domains together, but domains must not depend on `app`.
- `kernel` is pure. It must not depend on product domains, `platform`, or `infra`.
- `workspace` is the only owner of ambient harness state. Domains should not rebuild XDG/session/current-run logic on their own.
- `platform` is adapter logic only. Generic topology lives in `kernel`, not `platform`.
- `infra` stays generic. It must not depend on product domains.
- `run`, `create`, `observe`, `setup`, and `hooks` own their own workflows and persistence-facing models.
- The public crate surface is domain-oriented. `platform` is intentionally crate-internal.
- Shared abstractions must have a real owner. If a concept is cross-domain and pure, it belongs in `kernel`; if it is ambient state, it belongs in `workspace`.

## Public Surface

The intended public shape is app-first and domain-first:

- public: `app`, `run`, `create`, `observe`, `setup`, `hooks`, `kernel`, `workspace`, `infra`, `errors`
- internal: `platform`, manifest plumbing, suite defaults, test-only codec helpers

## State Boundaries

```mermaid
flowchart TD
    Workspace["workspace\ncurrent session and ambient pointers"]
    Run["run\ntracked run state and reports"]
    Create["create\nsuite:create state"]
    Observe["observe\nobserver state"]
    Hooks["hooks\nnormalized hook context"]

    Workspace --> Run
    Workspace --> Create
    Workspace --> Observe
    Workspace --> Hooks
```

Use this document as the short contract. If a module does not clearly fit one of these ownership buckets, it is probably in the wrong place.
