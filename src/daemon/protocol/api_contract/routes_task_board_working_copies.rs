use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_WORKING_COPIES,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_WORKING_COPIES_LIST,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_WORKING_COPIES_OBTAIN,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_WORKING_COPIES_OBTAIN,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_WORKING_COPIES_DELETE,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_WORKING_COPIES_DELETE,
        },
        swift_client_exposed: true,
    },
];
