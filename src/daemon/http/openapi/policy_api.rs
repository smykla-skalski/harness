//! Policy domain [`utoipa::OpenApi`] aggregator. Kept in its own module so the
//! path list does not push `openapi/mod.rs` past the file-length cap.

#[derive(utoipa::OpenApi)]
#[openapi(paths(
    super::super::task_board::policy::get_policy_canvas_workspace,
    super::super::task_board::policy::post_policy_canvas_create,
    super::super::task_board::policy::post_policy_canvas_duplicate,
    super::super::task_board::policy::post_policy_canvas_rename,
    super::super::task_board::policy::post_policy_canvas_set_active,
    super::super::task_board::policy::post_policy_canvas_delete,
    super::super::task_board::policy::post_policy_canvas_set_global_enforcement,
    super::super::task_board::policy::post_policy_scenario_create,
    super::super::task_board::policy::post_policy_scenario_update,
    super::super::task_board::policy::post_policy_scenario_delete,
    super::super::task_board::policy::post_policy_scenario_reset,
    super::super::task_board::policy_pipeline::get_policy_pipeline,
    super::super::task_board::policy_pipeline::put_policy_pipeline_draft,
    super::super::task_board::policy_pipeline::post_policy_simulate,
    super::super::task_board::policy_pipeline::post_policy_promote,
    super::super::task_board::policy_pipeline::post_policy_make_live,
    super::super::task_board::policy_pipeline::post_policy_go_live_diff,
    super::super::task_board::policy_pipeline::post_policy_replay,
    super::super::task_board::policy_pipeline::get_policy_audit,
    super::super::task_board::policy_spawn_gate::post_policy_canvas_set_spawn_requires_live_policy,
    super::super::task_board::policy_spawn_gate::post_policy_canvas_set_spawn_kill_switch,
    super::super::task_board::policy_spawn_gate::get_policy_approval_grants,
    super::super::task_board::policy_spawn_gate::post_policy_approval_grant_resolve,
    super::super::task_board::policy_spawn_gate::post_policy_approval_grant_revoke,
    super::super::task_board::policy_io::post_policy_dump,
    super::super::task_board::policy_io::post_policy_export,
    super::super::task_board::policy_io::post_policy_import,
    super::super::task_board::policy_io::post_policy_import_batch,
))]
pub(super) struct PolicyApi;
