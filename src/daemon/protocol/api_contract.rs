#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpRouteMethod {
    Get,
    Post,
    Put,
    Delete,
}

impl HttpRouteMethod {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Get => "GET",
            Self::Post => "POST",
            Self::Put => "PUT",
            Self::Delete => "DELETE",
        }
    }
}

/// Why a route carries no WebSocket RPC mirror. Every exemption must name one
/// of these; there is deliberately no "not built yet" variant, so a route that
/// merely lacks a client path is a parity gap to close, not an exemption to
/// record. See `docs/api/websocket-parity-exemptions.md` for the audit that
/// classified each current exemption.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WsExemptionKind {
    /// The route can never be a single request-and-response RPC call: a
    /// connection upgrade, a long-lived server-sent stream, or a liveness probe
    /// that exists to stay transport-plain.
    Structural,
    /// The route is request/response and could be expressed as an RPC method,
    /// but is deliberately kept HTTP-only for a durable reason (a pre-auth
    /// bootstrap that cannot ride the authenticated RPC channel, a one-way
    /// ingestion path, or a bulk CLI transfer outside the interactive surface).
    StandingDecision,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpRouteParity {
    Rpc { ws_method: &'static str },
    Exempt {
        kind: WsExemptionKind,
        reason: &'static str,
    },
}

impl HttpRouteParity {
    #[must_use]
    pub const fn ws_method(self) -> Option<&'static str> {
        match self {
            Self::Rpc { ws_method } => Some(ws_method),
            Self::Exempt { .. } => None,
        }
    }

    #[must_use]
    pub const fn exemption_reason(self) -> Option<&'static str> {
        match self {
            Self::Rpc { .. } => None,
            Self::Exempt { reason, .. } => Some(reason),
        }
    }

    #[must_use]
    pub const fn exemption_kind(self) -> Option<WsExemptionKind> {
        match self {
            Self::Rpc { .. } => None,
            Self::Exempt { kind, .. } => Some(kind),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HttpApiRouteContract {
    pub method: HttpRouteMethod,
    pub path: &'static str,
    pub parity: HttpRouteParity,
    pub swift_client_exposed: bool,
}

pub mod http_paths;
mod routes;
mod routes_policy_transfer;
mod routes_remote;
mod routes_reviews;
mod routes_sessions_infra;
mod routes_task_board;
mod routes_task_board_orchestrator;
mod routes_task_board_positions;
mod routes_task_board_triage;
mod routes_tasks_agents_voice;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_reviews_parity;
pub use harness_protocol::daemon::ws_methods;

pub use routes::HTTP_API_CONTRACT;

#[must_use]
pub fn mapped_ws_methods() -> Vec<&'static str> {
    HTTP_API_CONTRACT
        .iter()
        .filter_map(|route| route.parity.ws_method())
        .collect()
}

/// Return every task-board route's websocket method name.
///
/// # Panics
/// Panics when a task-board route is missing its websocket method mapping;
/// this is a static-data invariant validated by contract tests.
#[must_use]
pub fn task_board_mcp_methods() -> Vec<&'static str> {
    routes_task_board::ROUTES
        .iter()
        .chain(routes_task_board_positions::ROUTES)
        .chain(routes_task_board_triage::ROUTES)
        // The triage escalation verdict route is HTTP-only by design (no
        // websocket mapping exists) and is never an MCP tool -- its only
        // caller is the daemon's own spawned escalation worker.
        .filter(|route| !matches!(route.parity, HttpRouteParity::Exempt { .. }))
        .map(|route| {
            route
                .parity
                .ws_method()
                .expect("task-board route should map to websocket")
        })
        .collect()
}

#[must_use]
pub fn explicit_exemptions() -> Vec<&'static HttpApiRouteContract> {
    HTTP_API_CONTRACT
        .iter()
        .filter(|route| matches!(route.parity, HttpRouteParity::Exempt { .. }))
        .collect()
}
