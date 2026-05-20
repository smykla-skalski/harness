use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_REPOSITORIES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_REPOSITORY_CATALOG,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_QUERY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_QUERY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_APPROVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_APPROVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_MERGE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_MERGE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_RERUN_CHECKS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_RERUN_CHECKS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_LABELS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_ADD_LABEL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_AUTO,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_AUTO,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Delete,
        path: http_paths::DEPENDENCY_UPDATES_CACHE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_CLEAR_CACHE,
        },
        swift_client_exposed: true,
    },
];
