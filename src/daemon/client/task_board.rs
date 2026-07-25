use serde::de::DeserializeOwned;

use crate::daemon::protocol::{
    PolicyApprovalGrantResolveRequest, PolicyApprovalGrantResolveResponse,
    PolicyApprovalGrantRevokeRequest, PolicyApprovalGrantRevokeResponse,
    PolicyApprovalGrantsListResponse, PolicyCanvasSetSpawnKillSwitchRequest,
    PolicyCanvasSetSpawnRequiresLivePolicyRequest, PolicyCanvasWorkspaceResponse,
    PolicyTransferBundle, PolicyTransferDumpRequest, PolicyTransferImportRequest,
    TASK_BOARD_STORAGE_DATABASE, TaskBoardAuditRequest, TaskBoardAuditResponse,
    TaskBoardCapabilitiesResponse, TaskBoardCatalogRequest, TaskBoardClearTriageOverrideRequest,
    TaskBoardCreateItemRequest, TaskBoardDispatchDeliverRequest, TaskBoardDispatchDeliverResponse,
    TaskBoardDispatchPickRequest, TaskBoardDispatchPickResponse, TaskBoardDispatchRequest,
    TaskBoardDispatchResponse, TaskBoardEvaluateRequest, TaskBoardEvaluationResponse,
    TaskBoardHostListResponse, TaskBoardHostLocalResponse,
    TaskBoardHostSetProjectTypesRequest, TaskBoardHostSetProjectTypesResponse,
    TaskBoardItemPositionMutationResponse, TaskBoardItemPositionSnapshot,
    TaskBoardListItemsRequest, TaskBoardListItemsResponse, TaskBoardMachinesResponse,
    TaskBoardPlanApproveRequest, TaskBoardPlanBeginRequest,
    TaskBoardPlanRevokeRequest, TaskBoardPlanSubmitRequest, TaskBoardPlanningResponse,
    TaskBoardProjectsResponse, TaskBoardResetItemPositionRequest, TaskBoardSetItemPositionRequest,
    TaskBoardActivateTriageRulesRequest, TaskBoardPreviewTriageRulesRequest,
    TaskBoardSaveTriageRulesDraftRequest, TaskBoardSetTriageOverrideRequest, TaskBoardSyncRequest,
    TaskBoardSyncResponse,
    TaskBoardTriageCurrentResponse, TaskBoardTriageEscalationVerdictRequest,
    TaskBoardTriageEscalationVerdictResponse, TaskBoardTriageHistoryResponse,
    TaskBoardTriageOverrideMutationResponse, TaskBoardTriageRulesAuditResponse,
    TaskBoardTriageRulesDraftResponse, TaskBoardTriageRulesRevisionsResponse,
    TaskBoardUpdateItemRequest, http_paths,
};
use harness_kernel::errors::{CliError, CliErrorKind};
use crate::infra::io;
use crate::task_board::{
    TaskBoardItem, TaskBoardStatus, TriageRuleSetActivationResult, TriageRuleSetDraftSaveResult,
    TriageRuleSetPreviewResult,
};

use super::DaemonClient;

#[expect(
    clippy::missing_errors_doc,
    reason = "all methods forward to daemon HTTP and return CliError on failure"
)]
impl DaemonClient {
    pub fn require_database_task_board(&self) -> Result<i64, CliError> {
        let capability = self
            .get_optional::<TaskBoardCapabilitiesResponse>(
                http_paths::TASK_BOARD_CAPABILITIES,
                &[],
            )?
            .ok_or_else(task_board_upgrade_required)?;
        if capability.storage != TASK_BOARD_STORAGE_DATABASE {
            return Err(task_board_upgrade_required());
        }
        Ok(capability.revision)
    }

    pub fn create_task_board_item(
        &self,
        request: &TaskBoardCreateItemRequest,
    ) -> Result<TaskBoardItem, CliError> {
        self.post(http_paths::TASK_BOARD_ITEMS, request)
    }

    /// Read one bounded page of matching task-board items.
    pub fn list_task_board_items_page(
        &self,
        request: &TaskBoardListItemsRequest,
    ) -> Result<TaskBoardListItemsResponse, CliError> {
        self.get_with_query(
            http_paths::TASK_BOARD_ITEMS,
            &task_board_list_query(request)?
                .iter()
                .map(|(name, value)| (*name, value.as_str()))
                .collect::<Vec<_>>(),
        )
    }

    /// Read every matching task-board item by walking the daemon's pages.
    ///
    /// The daemon bounds each response, so a caller that wants the whole
    /// selection has to ask for the rest; this keeps that loop in one place
    /// rather than in every command that reads the board.
    pub fn list_task_board_items(
        &self,
        request: &TaskBoardListItemsRequest,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let mut request = request.clone();
        let mut items = Vec::new();
        loop {
            let page = self.list_task_board_items_page(&request)?;
            let drained = page.items.is_empty();
            items.extend(page.items);
            let Some(cursor) = page.next_cursor else {
                return Ok(items);
            };
            // Neither an empty page nor a cursor that names the same resume
            // point advances the walk, and following either forever would hang
            // the caller with no way to tell why.
            if drained {
                return Ok(items);
            }
            if request.cursor.as_deref() == Some(cursor.as_str()) {
                return Err(stalled_task_board_page(&cursor));
            }
            request.cursor = Some(cursor);
        }
    }

    pub fn get_task_board_item(&self, item_id: &str) -> Result<TaskBoardItem, CliError> {
        self.get(&item_path(item_id))
    }

    pub fn get_task_board_item_position_snapshot(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardItemPositionSnapshot, CliError> {
        self.get(&item_action_path(item_id, "position"))
    }

    pub fn set_task_board_item_position(
        &self,
        item_id: &str,
        request: &TaskBoardSetItemPositionRequest,
    ) -> Result<TaskBoardItemPositionMutationResponse, CliError> {
        self.put(&item_action_path(item_id, "position"), request)
    }

    pub fn reset_task_board_item_position(
        &self,
        item_id: &str,
        request: &TaskBoardResetItemPositionRequest,
    ) -> Result<TaskBoardItemPositionMutationResponse, CliError> {
        self.post(&item_action_path(item_id, "position/reset"), request)
    }

    pub fn get_task_board_item_triage(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardTriageCurrentResponse, CliError> {
        io::validate_safe_segment(item_id)?;
        self.get(&item_action_path(item_id, "triage"))
    }

    pub fn get_task_board_item_triage_history(
        &self,
        item_id: &str,
        before_generation: Option<u64>,
        limit: Option<u32>,
    ) -> Result<TaskBoardTriageHistoryResponse, CliError> {
        io::validate_safe_segment(item_id)?;
        let before_generation = before_generation.map(|value| value.to_string());
        let limit = limit.map(|value| value.to_string());
        let mut query = Vec::with_capacity(2);
        if let Some(value) = before_generation.as_deref() {
            query.push(("before_generation", value));
        }
        if let Some(value) = limit.as_deref() {
            query.push(("limit", value));
        }
        self.get_with_query(&item_action_path(item_id, "triage/history"), &query)
    }

    pub fn set_task_board_item_triage_override(
        &self,
        item_id: &str,
        request: &TaskBoardSetTriageOverrideRequest,
    ) -> Result<TaskBoardTriageOverrideMutationResponse, CliError> {
        io::validate_safe_segment(item_id)?;
        self.put(&item_action_path(item_id, "triage/override"), request)
    }

    pub fn clear_task_board_item_triage_override(
        &self,
        item_id: &str,
        request: &TaskBoardClearTriageOverrideRequest,
    ) -> Result<TaskBoardTriageOverrideMutationResponse, CliError> {
        io::validate_safe_segment(item_id)?;
        self.post(&item_action_path(item_id, "triage/override/clear"), request)
    }

    pub fn get_task_board_triage_rules_draft(
        &self,
    ) -> Result<TaskBoardTriageRulesDraftResponse, CliError> {
        self.get(http_paths::TASK_BOARD_TRIAGE_RULES_DRAFT)
    }

    pub fn save_task_board_triage_rules_draft(
        &self,
        request: &TaskBoardSaveTriageRulesDraftRequest,
    ) -> Result<TriageRuleSetDraftSaveResult, CliError> {
        self.put(http_paths::TASK_BOARD_TRIAGE_RULES_DRAFT, request)
    }

    pub fn preview_task_board_triage_rules(
        &self,
        request: &TaskBoardPreviewTriageRulesRequest,
    ) -> Result<TriageRuleSetPreviewResult, CliError> {
        self.post(http_paths::TASK_BOARD_TRIAGE_RULES_PREVIEW, request)
    }

    /// Report a triage escalation verdict. No control-plane session
    /// authentication is involved -- the request body's `verdict_token` is
    /// the entire credential, matching the endpoint's own auth contract
    /// (see `TaskBoardTriageEscalationVerdictRequest`).
    pub fn report_task_board_triage_escalation_verdict(
        &self,
        escalation_id: &str,
        request: &TaskBoardTriageEscalationVerdictRequest,
    ) -> Result<TaskBoardTriageEscalationVerdictResponse, CliError> {
        self.post(&triage_escalation_verdict_path(escalation_id), request)
    }

    pub fn activate_task_board_triage_rules(
        &self,
        request: &TaskBoardActivateTriageRulesRequest,
    ) -> Result<TriageRuleSetActivationResult, CliError> {
        self.post(http_paths::TASK_BOARD_TRIAGE_RULES_ACTIVATE, request)
    }

    pub fn get_task_board_triage_rules_revisions(
        &self,
        limit: Option<u32>,
    ) -> Result<TaskBoardTriageRulesRevisionsResponse, CliError> {
        let limit = limit.map(|value| value.to_string());
        let mut query = Vec::with_capacity(1);
        if let Some(value) = limit.as_deref() {
            query.push(("limit", value));
        }
        self.get_with_query(http_paths::TASK_BOARD_TRIAGE_RULES_REVISIONS, &query)
    }

    pub fn get_task_board_triage_rules_audit(
        &self,
        limit: Option<u32>,
    ) -> Result<TaskBoardTriageRulesAuditResponse, CliError> {
        let limit = limit.map(|value| value.to_string());
        let mut query = Vec::with_capacity(1);
        if let Some(value) = limit.as_deref() {
            query.push(("limit", value));
        }
        self.get_with_query(http_paths::TASK_BOARD_TRIAGE_RULES_AUDIT, &query)
    }

    pub fn update_task_board_item(
        &self,
        item_id: &str,
        request: &TaskBoardUpdateItemRequest,
    ) -> Result<TaskBoardItem, CliError> {
        self.put(&item_path(item_id), request)
    }

    pub fn delete_task_board_item(&self, item_id: &str) -> Result<TaskBoardItem, CliError> {
        self.delete(&item_path(item_id))
    }

    pub fn begin_task_board_planning(
        &self,
        request: &TaskBoardPlanBeginRequest,
    ) -> Result<TaskBoardPlanningResponse, CliError> {
        self.post(&item_action_path(&request.id, "planning/begin"), request)
    }

    pub fn submit_task_board_plan(
        &self,
        request: &TaskBoardPlanSubmitRequest,
    ) -> Result<TaskBoardPlanningResponse, CliError> {
        self.post(&item_action_path(&request.id, "planning/submit"), request)
    }

    pub fn approve_task_board_plan(
        &self,
        request: &TaskBoardPlanApproveRequest,
    ) -> Result<TaskBoardPlanningResponse, CliError> {
        self.post(&item_action_path(&request.id, "planning/approve"), request)
    }

    pub fn revoke_task_board_plan(
        &self,
        request: &TaskBoardPlanRevokeRequest,
    ) -> Result<TaskBoardPlanningResponse, CliError> {
        self.post(&item_action_path(&request.id, "planning/revoke"), request)
    }

    pub fn sync_task_board(
        &self,
        request: &TaskBoardSyncRequest,
    ) -> Result<TaskBoardSyncResponse, CliError> {
        self.post(http_paths::TASK_BOARD_SYNC, request)
    }

    pub fn dispatch_task_board(
        &self,
        request: &TaskBoardDispatchRequest,
    ) -> Result<TaskBoardDispatchResponse, CliError> {
        self.post(http_paths::TASK_BOARD_DISPATCH, request)
    }

    pub fn deliver_task_board_dispatch(
        &self,
        request: &TaskBoardDispatchDeliverRequest,
    ) -> Result<TaskBoardDispatchDeliverResponse, CliError> {
        self.post(http_paths::TASK_BOARD_DISPATCH_DELIVER, request)
    }

    pub fn pick_task_board_dispatch(&self) -> Result<TaskBoardDispatchPickResponse, CliError> {
        self.post(
            http_paths::TASK_BOARD_DISPATCH_PICK,
            &TaskBoardDispatchPickRequest::default(),
        )
    }

    pub fn evaluate_task_board(
        &self,
        request: &TaskBoardEvaluateRequest,
    ) -> Result<TaskBoardEvaluationResponse, CliError> {
        self.post(http_paths::TASK_BOARD_EVALUATE, request)
    }

    pub fn audit_task_board(
        &self,
        request: &TaskBoardAuditRequest,
    ) -> Result<TaskBoardAuditResponse, CliError> {
        self.get_task_board_with_status(http_paths::TASK_BOARD_AUDIT, request.status)
    }

    pub fn task_board_projects(
        &self,
        request: &TaskBoardCatalogRequest,
    ) -> Result<TaskBoardProjectsResponse, CliError> {
        self.get_task_board_with_status(http_paths::TASK_BOARD_PROJECTS, request.status)
    }

    pub fn task_board_machines(
        &self,
        request: &TaskBoardCatalogRequest,
    ) -> Result<TaskBoardMachinesResponse, CliError> {
        self.get_task_board_with_status(http_paths::TASK_BOARD_MACHINES, request.status)
    }

    pub fn task_board_host_local(&self) -> Result<TaskBoardHostLocalResponse, CliError> {
        self.get(http_paths::TASK_BOARD_HOST_LOCAL)
    }

    pub fn task_board_host_list(&self) -> Result<TaskBoardHostListResponse, CliError> {
        self.get(http_paths::TASK_BOARD_HOST_LIST)
    }

    pub fn set_task_board_host_project_types(
        &self,
        request: &TaskBoardHostSetProjectTypesRequest,
    ) -> Result<TaskBoardHostSetProjectTypesResponse, CliError> {
        self.put(http_paths::TASK_BOARD_HOST_SET_PROJECT_TYPES, request)
    }

    pub fn set_policy_canvas_spawn_requires_live_policy(
        &self,
        request: &PolicyCanvasSetSpawnRequiresLivePolicyRequest,
    ) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
        self.post(
            http_paths::POLICY_CANVASES_SPAWN_REQUIRES_LIVE_POLICY,
            request,
        )
    }

    pub fn set_policy_canvas_spawn_kill_switch(
        &self,
        request: &PolicyCanvasSetSpawnKillSwitchRequest,
    ) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
        self.post(http_paths::POLICY_CANVASES_SPAWN_KILL_SWITCH, request)
    }

    pub fn dump_policy_transfer(
        &self,
        request: &PolicyTransferDumpRequest,
    ) -> Result<PolicyTransferBundle, CliError> {
        self.post(http_paths::POLICIES_DUMP, request)
    }

    pub fn import_policy_transfer(
        &self,
        request: &PolicyTransferImportRequest,
    ) -> Result<PolicyCanvasWorkspaceResponse, CliError> {
        self.post(http_paths::POLICIES_IMPORT, request)
    }

    pub fn list_policy_approval_grants(
        &self,
    ) -> Result<PolicyApprovalGrantsListResponse, CliError> {
        self.get(http_paths::POLICY_APPROVAL_GRANTS)
    }

    pub fn resolve_policy_approval_grant(
        &self,
        request: &PolicyApprovalGrantResolveRequest,
    ) -> Result<PolicyApprovalGrantResolveResponse, CliError> {
        self.post(http_paths::POLICY_APPROVAL_GRANT_RESOLVE, request)
    }

    pub fn revoke_policy_approval_grant(
        &self,
        request: &PolicyApprovalGrantRevokeRequest,
    ) -> Result<PolicyApprovalGrantRevokeResponse, CliError> {
        self.post(http_paths::POLICY_APPROVAL_GRANT_REVOKE, request)
    }

    fn get_task_board_with_status<Res: DeserializeOwned>(
        &self,
        path: &str,
        status: Option<TaskBoardStatus>,
    ) -> Result<Res, CliError> {
        let Some(status) = status else {
            return self.get(path);
        };
        let status = enum_label(status, "status")?;
        self.get_with_query(path, &[("status", status.as_str())])
    }
}

fn item_path(item_id: &str) -> String {
    http_paths::TASK_BOARD_ITEM.replace("{item_id}", item_id)
}

fn triage_escalation_verdict_path(escalation_id: &str) -> String {
    let mut base = reqwest::Url::parse("http://localhost/").expect("static URL should parse");
    base.path_segments_mut()
        .expect("static URL should accept path segments")
        .pop_if_empty()
        .push(escalation_id);
    let encoded_escalation_id = base.path().trim_start_matches('/');
    http_paths::TASK_BOARD_TRIAGE_ESCALATION_VERDICT
        .replace("{escalation_id}", encoded_escalation_id)
}

fn item_action_path(item_id: &str, action: &str) -> String {
    format!("{}/{action}", item_path(item_id))
}

/// Render a list request as the daemon's query string, in a stable order.
fn task_board_list_query(
    request: &TaskBoardListItemsRequest,
) -> Result<Vec<(&'static str, String)>, CliError> {
    let mut query = enum_facet_query(request)?;
    append_text_query(request, &mut query);
    append_page_query(request, &mut query);
    Ok(query)
}

fn enum_facet_query(
    request: &TaskBoardListItemsRequest,
) -> Result<Vec<(&'static str, String)>, CliError> {
    let mut query = Vec::new();
    if let Some(status) = request.status {
        query.push(("status", enum_label(status, "status")?));
    }
    if let Some(priority) = request.priority {
        query.push(("priority", enum_label(priority, "priority")?));
    }
    if let Some(agent_mode) = request.agent_mode {
        query.push(("agent_mode", enum_label(agent_mode, "agent mode")?));
    }
    Ok(query)
}

fn append_text_query(
    request: &TaskBoardListItemsRequest,
    query: &mut Vec<(&'static str, String)>,
) {
    if let Some(project_id) = &request.project_id {
        query.push(("project_id", project_id.clone()));
    }
    for tag in &request.tags {
        query.push(("tag", tag.clone()));
    }
    if let Some(text) = &request.query {
        query.push(("query", text.clone()));
    }
}

fn append_page_query(
    request: &TaskBoardListItemsRequest,
    query: &mut Vec<(&'static str, String)>,
) {
    if let Some(limit) = request.limit {
        query.push(("limit", limit.to_string()));
    }
    if let Some(cursor) = &request.cursor {
        query.push(("cursor", cursor.clone()));
    }
}

fn enum_label<T: serde::Serialize>(value: T, label: &str) -> Result<String, CliError> {
    serde_json::to_value(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            CliErrorKind::workflow_serialize(format!("task-board {label} is not a string")).into()
        })
}

fn stalled_task_board_page(cursor: &str) -> CliError {
    CliErrorKind::workflow_io(format!(
        "the daemon returned the same task-board page cursor '{cursor}' twice; \
         the board read cannot advance"
    ))
    .into()
}

fn task_board_upgrade_required() -> CliError {
    CliErrorKind::workflow_io(
        "the running daemon does not provide database-backed Task Board storage; upgrade and restart the daemon",
    )
    .into()
}
