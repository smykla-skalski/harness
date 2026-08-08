use crate::schema_repairs_shape_probes::{
    column_exists, index_exists, table_exists, table_sql_contains, trigger_exists,
};
use crate::{CliError, Connection};

const CURRENT_SCHEMA_TABLES: &[&str] = &[
    "policy_workspace",
    "policy_canvases",
    "policy_nodes",
    "policy_edges",
    "policy_groups",
    "policy_group_nodes",
    "audit_events",
    "remote_acme_state",
    "remote_audit_events",
    "remote_clients",
    "remote_pairing_codes",
    "policy_decisions",
    "task_board_items",
    "task_board_identity",
    "task_board_external_refs",
    "task_board_machines",
    "task_board_local_machine",
    "task_board_orchestrator_settings",
    "task_board_orchestrator_state",
    "task_board_runtime_config",
    "policy_workflow_runs",
    "policy_event_inbox",
    "policy_handoff_outbox",
    "policy_notification_outbox",
    "policy_task_creation_outbox",
    "policy_approval_grants",
    "task_board_dispatch_intents",
    "task_board_imports",
    "task_board_orchestrator_control",
    "task_board_orchestrator_runs",
    "task_board_workflow_executions",
    "task_board_execution_attempts",
    "task_board_admission_leases",
    "task_board_provider_scope_state",
    "task_board_external_create_intents",
    "task_board_dispatch_admission_decisions",
    "task_board_dispatch_admission_ledger",
    "task_board_sync_conflicts",
    "task_board_execution_hosts",
    "task_board_remote_assignments",
    "task_board_remote_host_quarantines",
    "task_board_orchestrator_wake_events",
    "task_board_reconciliation_cursors",
    "task_board_projects",
    "task_board_ai_review_reports",
    "task_board_ai_review_report_order",
    "agent_workspaces",
    "agent_workspace_legacy_sessions",
    "agent_workspace_reconciliation",
    "agent_workspace_reconcile_queue",
    "agent_workspace_teams",
    "agent_workspace_members",
    "agent_workspace_member_provenance",
    "agent_workspace_member_operations",
    "agent_working_copies",
];

const CURRENT_SCHEMA_POLICY_COLUMNS: &[(&str, &str)] = &[
    ("policy_workspace", "manual_ocr_paste_canvas_deleted"),
    (
        "policy_workspace",
        "review_text_paste_dry_run_canvas_deleted",
    ),
    (
        "policy_workspace",
        "review_screenshot_extraction_canvas_deleted",
    ),
    ("policy_workspace", "global_policy_enforcement_enabled"),
    ("policy_workspace", "spawn_requires_live_policy"),
    ("policy_workspace", "spawn_kill_switch"),
    ("policy_workspace", "scenarios_json"),
    ("policy_workspace", "scenarios_seeded"),
    ("policy_canvases", "is_manual_ocr_paste_canvas"),
    ("policy_canvases", "is_review_text_paste_dry_run_canvas"),
    ("policy_canvases", "is_review_screenshot_extraction_canvas"),
    ("policy_canvases", "layout_zoom"),
    ("policy_canvases", "layout_offset_x"),
    ("policy_canvases", "layout_offset_y"),
    ("policy_canvases", "live_document_json"),
    ("policy_canvases", "live_updated_at"),
    ("policy_nodes", "layout_source"),
    ("policy_decisions", "evaluated_at"),
    ("task_board_dispatch_intents", "consumed_approval_grant_id"),
    ("task_board_dispatch_intents", "compensation_pending"),
    ("task_board_dispatch_intents", "workspace_id"),
    ("task_board_dispatch_intents", "working_copy_id"),
    ("task_board_items", "workspace_id"),
    ("task_board_items", "working_copy_id"),
    ("task_board_items", "workflow_kind"),
    ("task_board_items", "execution_repository"),
    ("task_board_items", "estimated_tokens"),
    ("task_board_items", "estimated_cost_microusd"),
    ("task_board_items", "parent_item_id"),
    ("task_board_items", "child_order"),
    ("task_board_items", "kind"),
    ("task_board_projects", "color"),
    ("task_board_projects", "shape"),
];

const CURRENT_SCHEMA_RUN_COLUMNS: &[(&str, &str)] = &[
    ("codex_runs", "task_id"),
    ("codex_runs", "board_item_id"),
    ("codex_runs", "workflow_execution_id"),
    ("codex_runs", "workspace_id"),
    ("agent_tuis", "workspace_id"),
    ("agent_turn_runs", "runtime_turn_id"),
    ("task_board_ai_review_reports", "requested_runtime"),
    ("task_board_ai_review_reports", "actual_runtime"),
];

const DEPRECATED_SCHEMA_POLICY_COLUMNS: &[(&str, &str)] =
    &[("policy_workspace", "enforcement_snapshot_json")];

const CURRENT_SCHEMA_TRIGGERS: &[&str] = &[
    "remote_audit_events_touch_client_activity",
    "agent_workspace_queue_session_insert",
    "agent_workspace_queue_session_update",
    "agent_workspace_queue_session_delete",
    "agent_workspace_queue_project_update",
    "agent_workspace_team_source_agent_insert",
    "agent_workspace_team_source_agent_update",
    "agent_workspace_team_source_agent_delete",
    "agent_workspace_team_source_session_update",
    "agent_workspace_team_source_tui_insert",
    "agent_workspace_team_source_tui_update",
    "agent_workspace_team_source_tui_delete",
    "agent_workspace_team_source_codex_insert",
    "agent_workspace_team_source_codex_update",
    "agent_workspace_team_source_codex_delete",
    "agent_workspace_team_source_provenance_insert",
    "agent_workspace_team_source_provenance_update",
    "agent_workspace_team_source_provenance_delete",
    "agent_workspace_team_detach_session",
];

const CURRENT_SCHEMA_INDEXES: &[&str] = &[
    "task_board_items_source_project",
    "task_board_projects_source_slug",
    "idx_agent_workspaces_project",
    "idx_agent_workspace_selected_session",
    "idx_agent_workspace_reconciliation_idempotency",
    "idx_agent_workspace_member_managed_identity",
    "idx_agent_workspace_member_managed_lookup",
    "idx_agent_workspace_member_source",
    "idx_agent_workspace_member_provenance_member",
    "idx_agent_workspace_member_provenance_source",
    "idx_agent_workspace_legacy_sessions_session",
    "idx_agent_workspace_member_operations_member",
    "idx_agent_working_copies_active_path",
    "idx_agent_working_copies_workspace",
    "idx_agent_tuis_workspace_updated",
    "idx_codex_runs_workspace_updated",
    "idx_task_board_items_workspace",
    "idx_task_board_dispatch_workspace_work_item",
];

const CURRENT_SCHEMA_REMOTE_ACME_COLUMNS: &[(&str, &str)] = &[
    ("remote_acme_state", "domain"),
    ("remote_acme_state", "host"),
    ("remote_acme_state", "https_port"),
    ("remote_acme_state", "http_port"),
    ("remote_acme_state", "acme_email"),
    ("remote_acme_state", "acme_challenge"),
    ("remote_acme_state", "acme_dns_provider"),
    ("remote_acme_state", "account_credentials_json"),
];

pub(super) fn shape_needs_repair(conn: &Connection) -> Result<bool, CliError> {
    for table in CURRENT_SCHEMA_TABLES {
        if !table_exists(conn, table)? {
            return Ok(true);
        }
    }
    for (table, column) in CURRENT_SCHEMA_POLICY_COLUMNS
        .iter()
        .chain(CURRENT_SCHEMA_RUN_COLUMNS)
        .chain(CURRENT_SCHEMA_REMOTE_ACME_COLUMNS)
    {
        if !column_exists(conn, table, column)? {
            return Ok(true);
        }
    }
    crate::schema_repairs_external_creates::require_table_shape(conn)?;
    crate::schema_repairs_wake_events::require_table_shape(conn)?;
    if !table_sql_contains(conn, "task_board_dispatch_intents", "'held'")?
        || table_sql_contains(conn, "task_board_projects", "'todoist'")?
    {
        return Ok(true);
    }
    for (table, column) in DEPRECATED_SCHEMA_POLICY_COLUMNS {
        if column_exists(conn, table, column)? {
            return Ok(true);
        }
    }
    for trigger in CURRENT_SCHEMA_TRIGGERS {
        if !trigger_exists(conn, trigger)? {
            return Ok(true);
        }
    }
    for index in CURRENT_SCHEMA_INDEXES {
        if !index_exists(conn, index)? {
            return Ok(true);
        }
    }
    Ok(false)
}
