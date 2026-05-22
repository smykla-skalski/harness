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
        method: HttpRouteMethod::Get,
        path: http_paths::DEPENDENCY_UPDATES_CAPABILITIES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_CAPABILITIES,
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
        path: http_paths::DEPENDENCY_UPDATES_ACTION_PREVIEW,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_ACTION_PREVIEW,
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
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_REFRESH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_REFRESH,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_BODY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_BODY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_BODY_UPDATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_BODY_UPDATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_COMMENT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_COMMENT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_FILES_LIST,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_FILES_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_FILES_PATCH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_FILES_PATCH,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_FILES_VIEWED,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_FILES_VIEWED,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_FILES_BLOB,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_FILES_BLOB,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES_DELETE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::DEPENDENCY_UPDATES_FILES_LOCAL_CLONES_DELETE,
        },
        swift_client_exposed: true,
    },
];
