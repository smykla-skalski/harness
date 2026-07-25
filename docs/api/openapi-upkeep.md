# OpenAPI upkeep

The daemon HTTP API is described by a generated OpenAPI 3.1 document at `docs/api/openapi.json`. This file audits the manual work each documented endpoint still costs: what the author hand-writes, what the toolchain derives, and what guards each remaining manual step against drift. It records the conclusions of the upkeep reduction tracked in issue #491 (the final slice of #466), so the split between automated and manual can be trusted without re-deriving it.

## What adding a documented endpoint costs

Registering a daemon HTTP route in the `utoipa-axum` router (`.routes(routes!(handler))`) now also produces the route's OpenAPI path from the handler's `#[utoipa::path]` annotation. There is no separate list of handlers to keep in sync, and no build that compiles the router without the annotations.

| Step | Manual? | Source of truth it duplicates | What guards it |
| --- | --- | --- | --- |
| Handler fn + `#[utoipa::path(...)]` annotation (method, tag, params, request body, responses) | Manual | The handler's own behaviour | Nothing tool-side; it is the description. Response shapes and status codes are semantic, not derivable from the signature |
| Annotation `path = "…"` literal | Manual | `http_paths` const and the route's entry in `HTTP_API_CONTRACT` | `documented_operations_match_contract` asserts the generated operation set equals the contract (minus `OPENAPI_EXEMPT`) plus the transport table, so a mistyped literal fails |
| Route registration `.routes(routes!(handler))` | Manual | — (this *is* the registration) | Produces the OpenAPI path as a side effect; a served route without an annotation will not compile through `routes!` |
| `#[derive(utoipa::ToSchema)]` on each wire type | Manual | The wire type's fields | The compiler: a type reachable from an annotation but missing the derive fails to build |
| Regenerate `docs/api/openapi.json` (`mise run openapi:generate`) | Manual | The live router | `mise run openapi:check` fails on drift and runs inside `mise run test` |

Cross-cutting concerns are fully derived and need no per-endpoint work: the four JSON injectors add the shared `401/413/414/429/431/503/504` responses, the `x-websocket-method` extension, optional-body relaxation, and provenance, each kept honest by its own contract test.

## What this slice removed

Two whole steps and an ongoing gating discipline disappeared:

- **Aggregator registration.** Every handler's `__path_*` used to be hand-listed in one of ten `#[derive(OpenApi)] paths(...)` structs. Nothing but the integration test caught a missing entry. `utoipa-axum` derives the path set from the router, so the aggregators are deleted.
- **Feature gating.** `utoipa` was an optional `openapi` feature, so every annotation and `ToSchema` derive carried a `#[cfg_attr(feature = "openapi", …)]` wrapper, imports used only in annotations had to be `#[cfg(feature = "openapi")]` (the trap fixed in #506), and the schema had to build in a second feature-off shape. `routes!` needs the `__path_*` types unconditionally, and the daemon serves with them, so `utoipa` is now a permanent dependency, the `openapi` feature is gone, and every wrapper is plain.

The cost is that `utoipa` and `utoipa-axum` compile into every build. `harness-protocol` is foundational, so its `ToSchema` derives pull `utoipa` workspace-wide. There is no runtime behaviour change: `daemon_http_router` splits the `OpenApiRouter` back into a plain axum `Router` and applies the same middleware, so the served route set is unchanged - and now contract-derived by construction.

## What stays manual, and why

The `#[utoipa::path]` annotation body and the one `ToSchema` derive per wire type stay hand-written. They are not bookkeeping - they are the description itself. The response bodies, status codes, parameter semantics, and tags an endpoint documents cannot be derived from a Rust handler signature, and a wire type's JSON shape is its `ToSchema` derive. `utoipa-axum` removes the registration duplication, not the act of describing the API.

The one residual duplication is the annotation `path` literal: `utoipa` 5.5 requires `path` to be a string literal, so it cannot read the `http_paths` const the way the router once did. That duplication is contract-test-guarded rather than eliminated - `documented_operations_match_contract` fails if the literal and the contract disagree.
