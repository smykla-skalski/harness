# Daemon API schema

`openapi.json` is the OpenAPI 3.1 description of the Harness daemon HTTP API (served by `harness-daemon`). It is **generated** — do not edit it by hand.

- Regenerate: `mise run openapi:generate`
- Drift gate (runs inside `mise run test`): `mise run openapi:check`

The document is assembled from `#[utoipa::path]` annotations on the daemon handlers plus `#[derive(utoipa::ToSchema)]` on their request/response types (`src/daemon/http/openapi/`). `utoipa` is a permanent dependency with no feature gate. Where a route has WebSocket parity, its operation records the mirrored WebSocket JSON-RPC method in the `x-websocket-method` extension, sourced from the daemon route contract (`src/daemon/protocol/api_contract/`).

Coverage is complete: every non-exempt daemon HTTP route is annotated, guarded by the `documented_operations_match_contract` integration test. See `docs/api/openapi-upkeep.md` for what stays manual and why.
