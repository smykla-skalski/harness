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
        "admission_policy": {
            "limits": [
                {
                    "kind": "concurrency",
                    "scope": { "kind": "global" },
                    "limit": 1,
                    "reservation": 1,
                },
                {
                    "kind": "rate",
                    "scope": { "kind": "workflow", "value": "default_task" },
                    "limit": 10,
                    "window_seconds": 60,
                    "reservation": 1,
                },
                {
                    "kind": "token_budget",
                    "scope": { "kind": "repository", "value": "example/repo" },
                    "limit": 1_000,
                    "window_seconds": 3_600,
                },
                {
                    "kind": "monetary_budget",
                    "scope": { "kind": "global" },
                    "limit_microusd": 10_000,
                    "window_seconds": 3_600,
                },
            ],
            "windows": [{
                "scope": { "kind": "repository", "value": "example/repo" },
                "timezone": "UTC",
                "weekdays": ["monday"],
                "start_time": "09:00",
                "end_time": "17:00",
                "outside_action": "defer",
            }],
        },
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
    let limit = &policy["properties"]["limits"]["items"]["properties"];
    for field in ["limit", "limit_microusd", "window_seconds", "reservation"] {
        assert_eq!(
            limit[field]["maximum"],
            json!(9_223_372_036_854_775_807_u64),
            "{field} must match the persisted integer bound"
        );
    }
    assert_eq!(
        policy["properties"]["limits"]["items"]["allOf"]
            .as_array()
            .map(Vec::len),
        Some(4)
    );
    let scope = &policy["properties"]["limits"]["items"]["properties"]["scope"];
    assert_eq!(scope["allOf"].as_array().map(Vec::len), Some(2));
}

#[tokio::test(flavor = "current_thread")]
async fn schema_rejects_overflow_and_missing_non_global_scope_values() {
    let invalid_policies = [
        json!({
            "limits": [{
                "kind": "concurrency",
                "scope": { "kind": "global" },
                "limit": 9_223_372_036_854_775_808_u64,
                "reservation": 1,
            }],
        }),
        json!({
            "limits": [{
                "kind": "concurrency",
                "scope": { "kind": "workflow" },
                "limit": 1,
                "reservation": 1,
            }],
        }),
        json!({
            "limits": [{
                "kind": "concurrency",
                "scope": { "kind": "repository" },
                "limit": 1,
                "reservation": 1,
            }],
        }),
        json!({
            "limits": [{
                "kind": "concurrency",
                "scope": { "kind": "global" },
                "limit": 1,
            }],
        }),
        json!({
            "limits": [{
                "kind": "rate",
                "scope": { "kind": "global" },
                "limit": 1,
                "reservation": 1,
            }],
        }),
        json!({
            "limits": [{
                "kind": "token_budget",
                "scope": { "kind": "global" },
                "window_seconds": 60,
            }],
        }),
        json!({
            "limits": [{
                "kind": "monetary_budget",
                "scope": { "kind": "global" },
                "window_seconds": 60,
            }],
        }),
    ];

    for admission_policy in invalid_policies {
        let registry = task_board_registry();
        let tool = registry
            .get(ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE)
            .expect("settings update tool registered");
        let error = tool
            .call(json!({ "admission_policy": admission_policy }))
            .await
            .expect_err("invalid admission policy must fail before daemon I/O");
        assert!(
            matches!(error, crate::mcp::tool::ToolError::InvalidParams(_)),
            "unexpected validation error: {error:?}"
        );
    }
}
