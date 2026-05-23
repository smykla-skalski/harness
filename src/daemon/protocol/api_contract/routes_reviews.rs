use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_REPOSITORIES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_REPOSITORY_CATALOG,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::REVIEWS_CAPABILITIES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_CAPABILITIES,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_QUERY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_QUERY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_ACTION_PREVIEW,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_ACTION_PREVIEW,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_APPROVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_APPROVE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_MERGE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_MERGE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_RERUN_CHECKS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_RERUN_CHECKS,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_LABELS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_ADD_LABEL,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_AUTO,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_AUTO,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Delete,
        path: http_paths::REVIEWS_CACHE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_CLEAR_CACHE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_REFRESH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_REFRESH,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_BODY,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_BODY,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_BODY_UPDATE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_BODY_UPDATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_COMMENT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_COMMENT,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_FILES_LIST,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_FILES_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_FILES_PATCH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_FILES_PATCH,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_FILES_VIEWED,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_FILES_VIEWED,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_FILES_BLOB,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_FILES_BLOB,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_FILES_LOCAL_CLONES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_FILES_LOCAL_CLONES_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_FILES_LOCAL_CLONES_DELETE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_FILES_LOCAL_CLONES_DELETE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_AVATAR,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_AVATAR,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_TIMELINE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_TIMELINE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::REVIEWS_REVIEW_THREADS_RESOLVE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::REVIEWS_REVIEW_THREADS_RESOLVE,
        },
        swift_client_exposed: true,
    },
];
