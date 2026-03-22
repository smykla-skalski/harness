# Harness architecture

This file is the short ownership map for the current layout.

Use [README.md](README.md) for day-to-day usage. Use this file when you need to answer a different question: "where should this code live?"

## High-level shape

```mermaid
flowchart LR
    App["app\nCLI transport and wiring"]

    Run["run\ntracked suite execution"]
    Create["create\nsuite creation workflow"]
    Observe["observe\nsession analysis and reporting"]
    Setup["setup\nbootstrap and session lifecycle"]
    Hooks["hooks\nagent-facing policy and protocol"]

    Kernel["kernel\npure shared primitives"]
    Workspace["workspace\nambient harness state"]
    Platform["platform\nruntime-specific adapters"]
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

    Workspace --> Kernel
    Workspace --> Infra
    Platform --> Kernel
    Platform --> Infra
```

## What each root owns

| Path             | Owns                                                                               |
| ---------------- | ---------------------------------------------------------------------------------- |
| `src/app/`       | Clap CLI, top-level command grouping, transport mapping, domain wiring             |
| `src/run/`       | tracked runs, run workflow, prepared artifacts, reporting, run diagnostics, repair |
| `src/create/`    | `suite:create` workflow, approval state, create validation, create session state   |
| `src/observe/`   | log/session scanning, doctor diagnostics, classifiers, dump/scan flows, output     |
| `src/setup/`     | environment bootstrap, wrapper/session lifecycle, cluster setup entrypoints        |
| `src/hooks/`     | hook payload handling, guard policy, protocol normalization, hook effects          |
| `src/kernel/`    | pure shared concepts such as command intent, topology, skill ids, gates            |
| `src/workspace/` | XDG paths, current session pointers, compact handoff, ambient harness files        |
| `src/infra/`     | generic execution, persistence, environment, HTTP, process, and block abstractions |
| `src/errors/`    | typed error families plus transport-safe rendering                                 |

## Internal support roots

These are real roots in the repo, but they are not part of the main public domain map:

- `src/platform/` is crate-internal adapter code for runtime-specific behavior.
- `src/manifests/` is crate-internal manifest plumbing.
- `src/suite_defaults/` is crate-internal suite scaffolding and defaults.
- `src/codec/` is test-only support code and is not part of the public library surface.

## Public crate surface

The current `src/lib.rs` surface is:

- public: `app`, `create`, `errors`, `hooks`, `infra`, `kernel`, `observe`, `run`, `setup`, `workspace`
- crate-internal: `platform`, `manifests`, `suite_defaults`
- test-only: `codec`

That means `platform` is intentionally not a stable library API even though it is a first-class internal root.

## Runtime flow

```mermaid
sequenceDiagram
    participant U as User or Hook Event
    participant A as app
    participant D as Domain
    participant W as workspace
    participant P as platform
    participant I as infra

    U->>A: CLI args or hook payload
    A->>D: typed request
    D->>W: load session or ambient state if needed
    D->>P: ask for runtime-specific behavior if needed
    D->>I: perform side effects
    D-->>A: typed result or typed error
    A-->>U: CLI output or hook response
```

## State boundaries

```mermaid
flowchart TD
    Workspace["workspace\ncurrent session and ambient pointers"]
    Run["run\nrunner state, metadata, reports"]
    Create["create\nsuite:create state"]
    Observe["observe\nobserver state"]
    Setup["setup\nsession and bootstrap state"]
    Hooks["hooks\nnormalized hook context"]

    Workspace --> Run
    Workspace --> Create
    Workspace --> Observe
    Workspace --> Setup
    Workspace --> Hooks
```

## Rules

- `app` is transport only. It wires domains together, but domains must not depend on `app`.
- `kernel` is pure. It must not depend on product domains, `platform`, or `infra`.
- `workspace` is the only owner of ambient harness state.
- `platform` is adapter code, not a public crate surface.
- `infra` stays generic and must not depend on product domains.
- `run`, `create`, `observe`, `setup`, and `hooks` own their own workflows and persistence-facing models.
- Shared pure concepts belong in `kernel`. Shared ambient state belongs in `workspace`.

If a module does not fit one of these buckets, it is probably in the wrong place.
