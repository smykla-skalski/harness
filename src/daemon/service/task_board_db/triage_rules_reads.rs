use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TASK_BOARD_TRIAGE_RULES_LIST_DEFAULT_LIMIT, TaskBoardActivateTriageRulesRequest,
    TaskBoardPreviewTriageRulesRequest, TaskBoardSaveTriageRulesDraftRequest,
    TaskBoardTriageRulesAuditResponse, TaskBoardTriageRulesDraftResponse,
    TaskBoardTriageRulesRevisionsResponse,
};
use harness_kernel::errors::CliError;
use crate::task_board::{TriageRuleSetActivationResult, TriageRuleSetDraftSaveResult, TriageRuleSetPreviewResult};

pub(crate) async fn get_task_board_triage_rules_draft_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardTriageRulesDraftResponse, CliError> {
    let draft = db.load_task_board_triage_rules_draft().await?;
    Ok(TaskBoardTriageRulesDraftResponse { draft })
}

pub(crate) async fn save_task_board_triage_rules_draft_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardSaveTriageRulesDraftRequest,
) -> Result<TriageRuleSetDraftSaveResult, CliError> {
    db.save_task_board_triage_rules_draft(
        request.rules.clone(),
        request.actor.clone(),
        request.expected_revision,
    )
    .await
}

pub(crate) async fn preview_task_board_triage_rules_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardPreviewTriageRulesRequest,
) -> Result<TriageRuleSetPreviewResult, CliError> {
    db.preview_task_board_triage_rules(request.rules.clone()).await
}

pub(crate) async fn activate_task_board_triage_rules_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardActivateTriageRulesRequest,
) -> Result<TriageRuleSetActivationResult, CliError> {
    db.activate_task_board_triage_rules(
        request.rules.clone(),
        request.actor.clone(),
        request.expected_active_revision,
    )
    .await
}

pub(crate) async fn get_task_board_triage_rules_revisions_db(
    db: &AsyncDaemonDb,
    limit: Option<u32>,
) -> Result<TaskBoardTriageRulesRevisionsResponse, CliError> {
    let revisions = db
        .list_task_board_triage_rules_revisions(limit.unwrap_or(TASK_BOARD_TRIAGE_RULES_LIST_DEFAULT_LIMIT))
        .await?;
    Ok(TaskBoardTriageRulesRevisionsResponse { revisions })
}

pub(crate) async fn get_task_board_triage_rules_audit_db(
    db: &AsyncDaemonDb,
    limit: Option<u32>,
) -> Result<TaskBoardTriageRulesAuditResponse, CliError> {
    let audit = db
        .list_task_board_triage_rules_audit(limit.unwrap_or(TASK_BOARD_TRIAGE_RULES_LIST_DEFAULT_LIMIT))
        .await?;
    Ok(TaskBoardTriageRulesAuditResponse { audit })
}
