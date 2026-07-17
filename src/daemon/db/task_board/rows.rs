use sqlx::FromRow;

#[derive(Debug, FromRow)]
pub(super) struct ItemRow {
    pub(super) item_id: String,
    pub(super) schema_version: i64,
    pub(super) title: String,
    pub(super) body: String,
    pub(super) status: String,
    pub(super) priority: String,
    pub(super) tags_json: String,
    pub(super) project_id: Option<String>,
    pub(super) target_project_types_json: String,
    pub(super) agent_mode: String,
    pub(super) workflow_kind: String,
    pub(super) execution_repository: Option<String>,
    pub(super) estimated_tokens: Option<i64>,
    pub(super) estimated_cost_microusd: Option<i64>,
    pub(super) imported_from_provider: Option<String>,
    pub(super) planning_json: String,
    pub(super) workflow_json: String,
    pub(super) session_id: Option<String>,
    pub(super) work_item_id: Option<String>,
    pub(super) usage_json: String,
    pub(super) created_at: String,
    pub(super) updated_at: String,
    pub(super) deleted_at: Option<String>,
    pub(super) revision: i64,
}

#[derive(Debug, FromRow)]
pub(super) struct ExternalRefRow {
    pub(super) item_id: String,
    pub(super) position: i64,
    pub(super) provider: String,
    pub(super) external_id: String,
    pub(super) url: Option<String>,
    pub(super) sync_state_json: Option<String>,
}

#[derive(Debug, FromRow)]
pub(super) struct MachineRow {
    pub(super) machine_id: String,
    pub(super) label: String,
    pub(super) project_types_json: String,
    pub(super) agent_modes_json: String,
    pub(super) last_seen: String,
}
