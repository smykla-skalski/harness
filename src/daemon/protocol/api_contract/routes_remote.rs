use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[HttpApiRouteContract {
    method: HttpRouteMethod::Post,
    path: http_paths::REMOTE_PAIR_CLAIM,
    parity: HttpRouteParity::Exempt {
        reason: "public one-time pairing claim guarded by domain, TTL, and rate limits",
    },
    swift_client_exposed: false,
}];
