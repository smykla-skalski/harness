use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICIES_DUMP,
        parity: HttpRouteParity::Exempt {
            reason: "CLI policy transfer is an HTTP-only bulk operation",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICIES_IMPORT,
        parity: HttpRouteParity::Exempt {
            reason: "CLI policy transfer is an HTTP-only bulk operation",
        },
        swift_client_exposed: false,
    },
];
