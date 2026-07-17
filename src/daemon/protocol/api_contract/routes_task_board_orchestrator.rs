use super::{HttpApiRouteContract, HttpRouteMethod, HttpRouteParity, http_paths, ws_methods};

pub(crate) const ROUTES: &[HttpApiRouteContract] = &[
    route(
        HttpRouteMethod::Get,
        http_paths::TASK_BOARD_ORCHESTRATOR_RUNS,
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUNS,
    ),
    route(
        HttpRouteMethod::Get,
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
        ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_DETAIL,
    ),
    route(
        HttpRouteMethod::Get,
        http_paths::TASK_BOARD_ORCHESTRATOR_METRICS,
        ws_methods::TASK_BOARD_ORCHESTRATOR_METRICS,
    ),
];

const fn route(
    method: HttpRouteMethod,
    path: &'static str,
    ws_method: &'static str,
) -> HttpApiRouteContract {
    HttpApiRouteContract {
        method,
        path,
        parity: HttpRouteParity::Rpc { ws_method },
        swift_client_exposed: false,
    }
}
