use axum::Router;
use axum::routing::{get, post, put};

use crate::daemon::protocol::http_paths;

use super::DaemonHttpState;
use super::task_board_orchestrator_handlers::merge_orchestrator_routes;

mod items;
mod policy;
mod policy_io;
mod policy_spawn_gate;

pub(super) use self::items::{authenticated_request, authorized_control_request_parts};

use self::items::{
    delete_task_board_item, get_task_board_audit, get_task_board_capabilities,
    get_task_board_host_list, get_task_board_host_local, get_task_board_item, get_task_board_items,
    get_task_board_machines, get_task_board_projects, post_task_board_dispatch,
    post_task_board_dispatch_deliver, post_task_board_dispatch_pick, post_task_board_evaluate,
    post_task_board_item, post_task_board_plan_approve, post_task_board_plan_begin,
    post_task_board_plan_revoke, post_task_board_plan_submit, post_task_board_sync,
    put_task_board_host_set_project_types, put_task_board_item,
};
use self::policy::merge_policy_routes;
use self::policy_io::merge_policy_io_routes;
use self::policy_spawn_gate::merge_policy_spawn_gate_routes;

fn task_board_host_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::TASK_BOARD_HOST_LOCAL,
            get(get_task_board_host_local),
        )
        .route(
            http_paths::TASK_BOARD_HOST_LIST,
            get(get_task_board_host_list),
        )
        .route(
            http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES,
            put(put_task_board_host_set_project_types),
        )
}

pub(super) fn task_board_routes() -> Router<DaemonHttpState> {
    let router = Router::new()
        .route(
            http_paths::TASK_BOARD_CAPABILITIES,
            get(get_task_board_capabilities),
        )
        .route(
            http_paths::TASK_BOARD_ITEMS,
            post(post_task_board_item).get(get_task_board_items),
        )
        .route(
            http_paths::TASK_BOARD_ITEM,
            get(get_task_board_item)
                .put(put_task_board_item)
                .delete(delete_task_board_item),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_BEGIN,
            post(post_task_board_plan_begin),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_SUBMIT,
            post(post_task_board_plan_submit),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_APPROVE,
            post(post_task_board_plan_approve),
        )
        .route(
            http_paths::TASK_BOARD_PLAN_REVOKE,
            post(post_task_board_plan_revoke),
        )
        .route(http_paths::TASK_BOARD_SYNC, post(post_task_board_sync))
        .route(
            http_paths::TASK_BOARD_DISPATCH,
            post(post_task_board_dispatch),
        )
        .route(
            http_paths::TASK_BOARD_DISPATCH_DELIVER,
            post(post_task_board_dispatch_deliver),
        )
        .route(
            http_paths::TASK_BOARD_DISPATCH_PICK,
            post(post_task_board_dispatch_pick),
        )
        .route(
            http_paths::TASK_BOARD_EVALUATE,
            post(post_task_board_evaluate),
        )
        .route(http_paths::TASK_BOARD_AUDIT, get(get_task_board_audit))
        .route(
            http_paths::TASK_BOARD_PROJECTS,
            get(get_task_board_projects),
        )
        .route(
            http_paths::TASK_BOARD_MACHINES,
            get(get_task_board_machines),
        )
        .merge(task_board_host_routes());
    merge_policy_spawn_gate_routes(merge_policy_io_routes(merge_policy_routes(
        merge_orchestrator_routes(router),
    )))
}
