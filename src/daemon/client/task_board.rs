use std::collections::HashSet;

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
use super::task_board_list::{
    TASK_BOARD_LIST_MAX_PAGES, changed_task_board_read, enum_label, task_board_list_query,
    undrained_task_board_read, unusable_task_board_page,
};

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
        let owned = task_board_list_query(request)?;
        let query = owned
            .iter()
            .map(|(name, value)| (*name, value.as_str()))
            .collect::<Vec<_>>();
        self.get_with_query(http_paths::TASK_BOARD_ITEMS, &query)
    }

    /// Read every matching task-board item by walking the daemon's pages.
    ///
    /// The daemon bounds each response, so a caller that wants the whole
    /// selection has to ask for the rest; this keeps that loop in one place
    /// rather than in every command that reads the board.
    ///
    /// A walk that cannot advance fails instead of returning what it has. The
    /// daemon only ever pairs a cursor with a non-empty page, and never
    /// repeats the resume point it was handed, so either shape means the
    /// daemon is not the one this client is built against - and a `Vec` has
    /// nowhere to say the board was read only in part.
    ///
    /// Sequence-bound cursors prevent overlap in valid responses. Ids are
    /// still tracked so a malformed overlapping page cannot put duplicate
    /// rows in the returned board.
    pub fn list_task_board_items(
        &self,
        request: &TaskBoardListItemsRequest,
    ) -> Result<Vec<TaskBoardItem>, CliError> {
        let mut request = request.clone();
        let mut items = Vec::new();
        let mut seen = HashSet::new();
        let mut items_change_seq = None;
        for _ in 0..TASK_BOARD_LIST_MAX_PAGES {
            let page = self.list_task_board_items_page(&request)?;
            if let Some(expected) = items_change_seq
                && page.items_change_seq != expected
            {
                return Err(changed_task_board_read(expected, page.items_change_seq));
            }
            items_change_seq.get_or_insert(page.items_change_seq);
            let drained = page.items.is_empty();
            items.extend(
                page.items
                    .into_iter()
                    .filter(|item| seen.insert(item.id.clone())),
            );
            let Some(cursor) = page.next_cursor else {
                return Ok(items);
            };
            if drained {
                return Err(unusable_task_board_page(
                    &cursor,
                    "handed back a cursor with no items",
                ));
            }
            if request.cursor.as_deref() == Some(cursor.as_str()) {
                return Err(unusable_task_board_page(
                    &cursor,
                    "repeated the cursor it was given",
                ));
            }
            request.cursor = Some(cursor);
        }
        Err(undrained_task_board_read())
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

fn task_board_upgrade_required() -> CliError {
    CliErrorKind::workflow_io(
        "the running daemon does not provide database-backed Task Board storage; upgrade and restart the daemon",
    )
    .into()
}
