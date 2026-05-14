use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_ITEMS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_CREATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ITEMS,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ITEM,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ITEM,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_UPDATE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Delete,
        path: http_paths::TASK_BOARD_ITEM,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_DELETE,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_SYNC,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_SYNC,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_DISPATCH,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_DISPATCH,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_AUDIT,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_AUDIT,
        },
        swift_client_exposed: true,
    },
];
