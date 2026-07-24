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
        path: http_paths::REMOTE_CLIENT_SELF_REVOKE,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "self-revoke destroys the caller's own credential; kept a one-shot HTTP action \
                     rather than a method on the RPC session it would invalidate mid-call",
        },
        swift_client_exposed: true,
    },
];
