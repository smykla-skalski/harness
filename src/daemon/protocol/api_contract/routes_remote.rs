use super::{
    HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, WsExemptionKind, http_paths,
};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REMOTE_PAIR_CLAIM,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "pre-auth pairing claim that mints the first credential; cannot ride the \
                     authenticated RPC channel it bootstraps",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REMOTE_PAIR_STATUS,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "pre-auth pairing lifecycle check keyed by an opaque id; part of the bootstrap \
                     that precedes the authenticated RPC channel",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REMOTE_PAIR_MINT,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "mints a credential for a third party from a service that holds only the \
                     pair_mint scope; kept off the RPC channel so a broker never opens an \
                     authenticated session it has no scope to use",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REMOTE_CLIENT_SELF_REVOKE,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "self-revoke destroys the caller's own credential; kept a one-shot HTTP action \
                     rather than a method on the RPC session it would invalidate mid-call",
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::REMOTE_PAIRINGS,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "read by the companion panel over plain HTTP, which holds pair_manage and                      opens no RPC session; mirroring it as a websocket method would require                      granting the broker a channel it has no other use for",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REMOTE_PAIRING_REVOKE,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "revokes a credential belonging to somebody else, invoked by the companion                      panel over plain HTTP for the same reason listing is",
        },
        swift_client_exposed: false,
    },
];
