use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(super) const ROUTE: HttpApiRouteContract = HttpApiRouteContract {
    method: HttpRouteMethod::Get,
    path: http_paths::TASK_BOARD_ITEM_WORKFLOW_PROGRESS,
    parity: HttpRouteParity::Rpc {
        ws_method: ws_methods::TASK_BOARD_WORKFLOW_PROGRESS_GET,
    },
    swift_client_exposed: true,
};
