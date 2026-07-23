# Daemon API schema

`openapi.json` is the OpenAPI 3.1 description of the Harness daemon HTTP API
(served by `harness-daemon`). It is **generated** — do not edit it by hand.

- Regenerate: `mise run openapi:generate`
- Drift gate (runs inside `mise run test`): `mise run openapi:check`

The document is assembled from `#[utoipa::path]` annotations on the daemon
handlers plus `#[derive(utoipa::ToSchema)]` on their request/response types
(`src/daemon/http/openapi/`), behind the `openapi` cargo feature. Where a route
has WebSocket parity, its operation records the mirrored WebSocket JSON-RPC
method in the `x-websocket-method` extension, sourced from the daemon route
contract (`src/daemon/protocol/api_contract/`).

Coverage grows across an ordered PR series; routes not yet annotated are absent
from the document until their slice lands.
