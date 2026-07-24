use utoipa_axum::router::OpenApiRouter;
use utoipa_axum::routes;

use super::DaemonHttpState;
use super::task_board_git::merge_git_routes;
use super::task_board_orchestrator_handlers::merge_orchestrator_routes;

pub(super) mod items;
pub(super) mod operations;
pub(super) mod policy;
pub(super) mod policy_io;
pub(super) mod policy_pipeline;
pub(super) mod policy_spawn_gate;
pub(super) mod positions;
pub(super) mod triage;
pub(super) mod triage_rules;
pub(super) mod working_copies;

pub(super) use self::items::{authenticated_request, authorized_control_request_parts};
pub(super) use self::policy_io::{
    POLICY_TRANSFER_HTTP_BODY_LIMIT_BYTES, policy_transfer_http_body_limit,
};

use self::policy::merge_policy_routes;
use self::policy_io::merge_policy_io_routes;
use self::policy_pipeline::merge_policy_pipeline_routes;
use self::policy_spawn_gate::merge_policy_spawn_gate_routes;

fn task_board_triage_rules_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(
            triage_rules::get_task_board_triage_rules_draft,
            triage_rules::put_task_board_triage_rules_draft
        ))
        .routes(routes!(triage_rules::post_task_board_triage_rules_preview))
        .routes(routes!(triage_rules::post_task_board_triage_rules_activate))
        .routes(routes!(triage_rules::get_task_board_triage_rules_revisions))
        .routes(routes!(triage_rules::get_task_board_triage_rules_audit))
}

fn task_board_host_routes() -> OpenApiRouter<DaemonHttpState> {
    OpenApiRouter::new()
        .routes(routes!(operations::get_task_board_host_local))
        .routes(routes!(operations::get_task_board_host_list))
        .routes(routes!(operations::put_task_board_host_set_project_types))
}

pub(super) fn task_board_routes() -> OpenApiRouter<DaemonHttpState> {
    let router = OpenApiRouter::new()
        .routes(routes!(items::get_task_board_capabilities))
        .routes(routes!(
            items::post_task_board_item,
            items::get_task_board_items
        ))
        .routes(routes!(
            items::get_task_board_item,
            items::put_task_board_item,
            items::delete_task_board_item
        ))
        .routes(routes!(
            positions::get_task_board_item_position_snapshot,
            positions::put_task_board_item_position
        ))
        .routes(routes!(positions::post_task_board_item_position_reset))
        .routes(routes!(triage::get_task_board_item_triage))
        .routes(routes!(triage::get_task_board_item_triage_history))
        .routes(routes!(triage::put_task_board_item_triage_override))
        .routes(routes!(triage::post_task_board_item_triage_override_clear))
        .merge(task_board_triage_rules_routes())
        .routes(routes!(items::post_task_board_plan_begin))
        .routes(routes!(items::post_task_board_plan_submit))
        .routes(routes!(items::post_task_board_plan_approve))
        .routes(routes!(items::post_task_board_plan_revoke))
        .routes(routes!(operations::post_task_board_sync))
        .routes(routes!(operations::post_task_board_dispatch))
        .routes(routes!(operations::post_task_board_dispatch_deliver))
        .routes(routes!(operations::post_task_board_dispatch_pick))
        .routes(routes!(operations::post_task_board_evaluate))
        .routes(routes!(operations::get_task_board_audit))
        .routes(routes!(operations::get_task_board_projects))
        .routes(routes!(operations::get_task_board_machines))
        .merge(task_board_host_routes());
    merge_policy_pipeline_routes(merge_policy_spawn_gate_routes(merge_policy_io_routes(
        merge_policy_routes(merge_git_routes(merge_orchestrator_routes(
            working_copies::merge_working_copy_routes(router),
        ))),
    )))
}
