use super::*;

const UPDATE_FIELDS: &[&str] = &[
    "step_mode",
    "enabled_workflows",
    "dry_run_default",
    "dispatch_status_filter",
    "clear_dispatch_status_filter",
    "project_dir",
    "clear_project_dir",
    "github_project",
    "github_inbox",
    "todoist_inbox",
    "scheduling",
    "retry",
    "reviewers",
    "repositories",
    "execution_hosts",
    "admission_policy",
    "policy_version",
];

#[tokio::test(flavor = "current_thread")]
async fn update_tool_proxies_every_public_field_to_running_daemon() {
    let arguments = json!({
        "step_mode": true,
        "enabled_workflows": ["default_task", "pr_review"],
        "dry_run_default": true,
        "dispatch_status_filter": "backlog",
        "clear_dispatch_status_filter": false,
        "project_dir": "/tmp/project",
        "clear_project_dir": false,
        "github_project": {},
        "github_inbox": {},
        "todoist_inbox": {},
        "scheduling": {
            "max_dispatches_per_run": 1,
            "max_concurrent_workflows": 1,
            "reconcile_interval_seconds": 60,
        },
        "retry": {
            "max_attempts": 3,
            "base_delay_seconds": 30,
            "multiplier": 4,
            "max_delay_seconds": 600,
            "deterministic_jitter_percent": 10,
        },
        "reviewers": {
            "reviewer_count": 1,
            "required_approvals": 1,
            "max_revision_cycles": 3,
            "profiles": [],
        },
        "repositories": [],
        "execution_hosts": [],
        "admission_policy": { "limits": [], "windows": [] },
        "policy_version": "1",
    });
    let (result, captured) = call_task_board_tool(
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
        arguments.clone(),
        json!({ "saved": true }),
    )
    .await;

    assert_eq!(text_result_json(&result), json!({ "saved": true }));
    assert_eq!(
        captured.request.method,
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE
    );
    assert_eq!(captured.request.params, arguments);
}

#[test]
fn schema_advertises_every_field_and_strict_admission_policy() {
    let schema = task_board_tool_schema(ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE);
    assert_schema_covers_fields(
        &schema,
        ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
        UPDATE_FIELDS,
    );
    let policy = &schema["properties"]["admission_policy"];
    assert_eq!(policy["type"], "object");
    assert_eq!(policy["additionalProperties"], false);
    assert_eq!(policy["properties"]["limits"]["type"], "array");
    assert_eq!(
        policy["properties"]["limits"]["items"]["additionalProperties"],
        false
    );
    assert_eq!(policy["properties"]["windows"]["type"], "array");
    assert_eq!(
        policy["properties"]["windows"]["items"]["additionalProperties"],
        false
    );
}
