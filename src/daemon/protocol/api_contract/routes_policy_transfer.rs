use super::{
    HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, WsExemptionKind, http_paths,
};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICIES_DUMP,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "bulk policy export is a CLI administrative transfer kept off the interactive \
                     RPC surface",
        },
        swift_client_exposed: false,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::POLICIES_IMPORT,
        parity: HttpRouteParity::Exempt {
            kind: WsExemptionKind::StandingDecision,
            reason: "bulk policy import is a CLI administrative transfer kept off the interactive \
                     RPC surface",
        },
        swift_client_exposed: false,
    },
];
