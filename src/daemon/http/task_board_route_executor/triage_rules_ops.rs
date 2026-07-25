use crate::daemon::protocol::{
    TaskBoardActivateTriageRulesRequest, TaskBoardPreviewTriageRulesRequest,
    TaskBoardSaveTriageRulesDraftRequest, TaskBoardTriageRulesAuditResponse,
    TaskBoardTriageRulesDraftResponse, TaskBoardTriageRulesRevisionsResponse,
};
use crate::daemon::service;
use harness_kernel::errors::CliError;
use crate::task_board::{
    TriageRuleSetActivationResult, TriageRuleSetDraftSaveResult, TriageRuleSetPreviewResult,
};

use super::super::{DaemonHttpState, require_async_db};

pub(crate) async fn get_triage_rules_draft(
    state: &DaemonHttpState,
) -> Result<TaskBoardTriageRulesDraftResponse, CliError> {
    service::get_task_board_triage_rules_draft_db(require_async_db(state, "task board triage rules draft get")?)
        .await
}

pub(crate) async fn save_triage_rules_draft(
    state: &DaemonHttpState,
    request: &TaskBoardSaveTriageRulesDraftRequest,
) -> Result<TriageRuleSetDraftSaveResult, CliError> {
    service::save_task_board_triage_rules_draft_db(
        require_async_db(state, "task board triage rules draft save")?,
        request,
    )
    .await
}

pub(crate) async fn preview_triage_rules(
    state: &DaemonHttpState,
    request: &TaskBoardPreviewTriageRulesRequest,
) -> Result<TriageRuleSetPreviewResult, CliError> {
    service::preview_task_board_triage_rules_db(
        require_async_db(state, "task board triage rules preview")?,
        request,
    )
    .await
}

pub(crate) async fn activate_triage_rules(
    state: &DaemonHttpState,
    request: &TaskBoardActivateTriageRulesRequest,
) -> Result<TriageRuleSetActivationResult, CliError> {
    service::activate_task_board_triage_rules_db(
        require_async_db(state, "task board triage rules activate")?,
        request,
    )
    .await
}

pub(crate) async fn get_triage_rules_revisions(
    state: &DaemonHttpState,
    limit: Option<u32>,
) -> Result<TaskBoardTriageRulesRevisionsResponse, CliError> {
    service::get_task_board_triage_rules_revisions_db(
        require_async_db(state, "task board triage rules revisions")?,
        limit,
    )
    .await
}

pub(crate) async fn get_triage_rules_audit(
    state: &DaemonHttpState,
    limit: Option<u32>,
) -> Result<TaskBoardTriageRulesAuditResponse, CliError> {
    service::get_task_board_triage_rules_audit_db(
        require_async_db(state, "task board triage rules audit")?,
        limit,
    )
    .await
}
