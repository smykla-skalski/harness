use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REMOTE_PAIR_CLAIM,
        parity: HttpRouteParity::Exempt {
            reason: "public one-time pairing claim guarded by domain, TTL, and rate limits",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REMOTE_PAIR_STATUS,
        parity: HttpRouteParity::Exempt {
            reason: "public pairing lifecycle check keyed by an opaque id with redacted output",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REMOTE_CLIENT_SELF_REVOKE,
        parity: HttpRouteParity::Exempt {
            reason: "credential lifecycle action bound to the authenticated caller",
        },
        swift_client_exposed: true,
    },
];
