# WebSocket parity exemptions

The daemon HTTP API is dual-transport: almost every route mirrors a WebSocket
JSON-RPC method, recorded per route in the contract at
`src/daemon/protocol/api_contract/`. A route without a mirror is an **exemption**
and must say why in classified terms. This file is the audit that judged each
current exemption sound, so the classification can be trusted without
re-deriving it. It records the conclusions of the audit tracked in issue #508
(part of #466).

## The two kinds of exemption

`HttpRouteParity::Exempt` carries a `WsExemptionKind`. There are exactly two, and
deliberately no "not built yet" option:

- **Structural** — the route can never be a single request-and-response RPC
  call. It is a connection upgrade, a long-lived server-sent stream, or a
  liveness probe that exists to stay transport-plain. There is no coherent RPC
  form to add.
- **StandingDecision** — the route *is* request/response and could be expressed
  as an RPC method, but is kept HTTP-only for a durable architectural reason: a
  pre-authentication bootstrap that cannot ride the authenticated RPC channel, a
  one-way ingestion path that must survive when RPC framing is unusable, or a
  bulk CLI transfer kept off the interactive surface.

A route that merely lacks a WebSocket method because no client has needed one is
**neither** — it is a parity gap to close (add the method) or to convert into a
real standing decision, not an exemption to record. The contract test
`every_exemption_is_classified_with_a_durable_reason` enforces this: it rejects
any exemption reason that reads as an unbuilt-client placeholder ("yet", "no
client consumes it", and similar), so a future route cannot be exempted with a
placeholder.

## Current exemptions

Eleven routes are exempt. All were reviewed and judged sound.

### Structural (6)

| Method | Path | Why it has no RPC form |
| --- | --- | --- |
| GET | `/ready` | Liveness probe for orchestrators and load balancers; stays transport-plain HTTP. |
| GET | `/ws` | The WebSocket upgrade transport that *carries* the RPC methods; not itself an RPC call. |
| GET | `/stream` | Long-lived global server-sent event stream; its WebSocket mirror is the `stream.subscribe` subscription, not a request/response call. |
| GET | `/v1/sessions/{session_id}/stream` | Long-lived per-session server-sent event stream; mirrored by `session.subscribe`, not a request/response call. |
| GET | `/v1/managed-agents/{managed_agent_id}/attach` | Upgrades the connection into a raw terminal stream. |

(The `/stream` and `/sessions/{id}/stream` rows share the streaming rationale; the
subscription primitives `stream.subscribe` / `session.subscribe` are the
WebSocket equivalents and are intentionally socket-only, listed in
`WS_ONLY_METHODS`.)

### Standing decision (5)

| Method | Path | Durable reason to stay HTTP-only |
| --- | --- | --- |
| POST | `/daemon/telemetry` | One-way decode-failure telemetry must reach the daemon on a plain HTTP path even when a client cannot decode RPC framing. |
| POST | `/v1/remote/pair/claim` | Pre-auth pairing claim that mints the first credential; cannot ride the authenticated RPC channel it bootstraps. |
| POST | `/v1/remote/pair/status` | Pre-auth pairing lifecycle check; part of the bootstrap that precedes the authenticated RPC channel. |
| POST | `/v1/remote/clients/self/revoke` | Self-revoke destroys the caller's own credential; kept a one-shot HTTP action rather than a method on the RPC session it would invalidate mid-call. |
| POST | `/v1/policies/dump` and `/v1/policies/import` | Bulk policy transfer is a CLI administrative operation kept off the interactive RPC surface. |

## Gaps closed by this audit

Four ACP routes were previously exempt with the provisional reason "CLI-only …
no Monitor surface consumes it yet". They are plain request/response calls that
sit beside ACP routes which already have WebSocket methods (`prompt`,
`resolve_acp_permission`, `acp_inspect`, `acp_transcript`), so "HTTP-only" read
as unbuilt rather than decided. Each was given a WebSocket method, closing the
gap:

| Method | Path | New WebSocket method | Scope |
| --- | --- | --- | --- |
| POST | `/v1/managed-agents/{id}/logout` | `managed_agent.logout_acp` | write |
| GET | `/v1/managed-agents/{id}/sessions` | `managed_agent.acp_sessions` | read |
| DELETE | `/v1/managed-agents/{id}/sessions/{agent_session_id}` | `managed_agent.delete_acp_session` | write |
| POST | `/v1/managed-agents/{id}/sessions/{agent_session_id}/close` | `managed_agent.close_acp_session` | write |

The remote auth scope for each now derives from the mirrored method like any
other RPC route.
