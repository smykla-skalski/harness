use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    HttpApiRouteContract {
        method: HttpRouteMethod::Get,
        path: http_paths::TASK_BOARD_ITEM_POSITION,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_POSITION_GET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Put,
        path: http_paths::TASK_BOARD_ITEM_POSITION,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_POSITION_SET,
        },
        swift_client_exposed: true,
    },
    HttpApiRouteContract {
        method: HttpRouteMethod::Post,
        path: http_paths::TASK_BOARD_ITEM_POSITION_RESET,
        parity: HttpRouteParity::Rpc {
            ws_method: ws_methods::TASK_BOARD_POSITION_RESET,
        },
        swift_client_exposed: true,
    },
];
