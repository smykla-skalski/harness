use super::triage_escalation_store::ClaimedTaskBoardTriageEscalation;
use super::triage_override::{
    TaskBoardTriageOverrideClearInput, TaskBoardTriageOverrideMutationResult,
    TaskBoardTriageOverrideSetInput,
};
use super::{triage_escalation_store, triage_override, triage_rules_activation, triage_rules_preview, triage_rules_store};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::{
    TaskBoardTriageDecisionRecord, TaskBoardTriageEffectiveOutcome, TaskBoardTriageEscalationStatus,
    TaskBoardTriageEscalationVerdictOutcome, TaskBoardTriageOverride,
    TriageRuleSetActivationResult, TriageRuleSetAuditEntry, TriageRuleSetDraft,
    TriageRuleSetDraftSaveResult, TriageRuleSetPreviewResult, TriageRuleSetRevisionSummary,
    TriageRuleSetV1, TriageVerdict,
};

pub(crate) const TASK_BOARD_TRIAGE_HISTORY_MAX_LIMIT: u32 = 100;

/// Everything `GET /v1/task-board/items/{item_id}/triage` needs: the latest
/// automatic decision, the active triage override (if any), and the single
/// effective outcome those two resolve to.
#[derive(Debug)]
pub(crate) struct TaskBoardTriageCurrentRead {
    pub(crate) current: Option<TaskBoardTriageDecisionRecord>,
    pub(crate) triage_override: Option<TaskBoardTriageOverride>,
    pub(crate) effective: Option<TaskBoardTriageEffectiveOutcome>,
    pub(crate) pending_escalation_status: Option<TaskBoardTriageEscalationStatus>,
}

#[derive(Debug)]
pub(crate) struct TaskBoardTriageHistoryPage {
    pub(crate) decisions: Vec<TaskBoardTriageDecisionRecord>,
    pub(crate) next_before_generation: Option<u64>,
}

#[path = "triage_queries_reads.rs"]
mod reads;
use reads::{task_board_triage_current, task_board_triage_history};

impl AsyncDaemonDb {
    pub(crate) async fn task_board_triage_current(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardTriageCurrentRead, CliError> {
        <Self as TriageQueries>::task_board_triage_current(self, item_id).await
    }

    pub(crate) async fn task_board_triage_history(
        &self,
        item_id: &str,
        before_generation: Option<u64>,
        limit: u32,
    ) -> Result<TaskBoardTriageHistoryPage, CliError> {
        <Self as TriageQueries>::task_board_triage_history(self, item_id, before_generation, limit)
            .await
    }
}

pub(crate) trait TriageQueries: Send + Sync {
    async fn task_board_triage_current(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardTriageCurrentRead, CliError>;

    async fn task_board_triage_history(
        &self,
        item_id: &str,
        before_generation: Option<u64>,
        limit: u32,
    ) -> Result<TaskBoardTriageHistoryPage, CliError>;

    /// Set (or replace) a durable triage override under one item-revision
    /// and item-list sequence CAS. Always authoritative for lane outcome,
    /// even over a manual anchor -- a manually anchored item still moves
    /// lanes, carrying its slot/actor/`lane_set_at` with it.
    async fn set_task_board_triage_override(
        &self,
        input: TaskBoardTriageOverrideSetInput,
    ) -> Result<TaskBoardTriageOverrideMutationResult, CliError>;

    /// Clear a durable triage override under one item-revision and
    /// item-list sequence CAS, first refreshing stale automatic evidence
    /// when needed and then reconciling that decision's placement. A manual
    /// anchor still reconciles, keeping its slot/actor/`lane_set_at`.
    async fn clear_task_board_triage_override(
        &self,
        input: TaskBoardTriageOverrideClearInput,
    ) -> Result<TaskBoardTriageOverrideMutationResult, CliError>;

    /// Apply one agent-reported verdict. See
    /// `triage_apply_agent::apply_agent_triage_verdict_in_tx` for the full
    /// CAS/eligibility contract; this is only the transaction boundary.
    async fn report_task_board_triage_escalation_verdict(
        &self,
        escalation_id: &str,
        verdict_token: &str,
        reported_fingerprint: &str,
        verdict: TriageVerdict,
        rationale: &str,
    ) -> Result<TaskBoardTriageEscalationVerdictOutcome, CliError>;

    /// Count of currently `running` escalations, for the executor to size
    /// its next claim batch against `max_concurrent`.
    async fn count_running_task_board_triage_escalations(&self) -> Result<usize, CliError>;

    /// Claim up to `limit` `pending` rows (oldest `requested_at` first),
    /// minting a fresh single-use `verdict_token` and `managed_run_id` for
    /// each and moving it to `running`.
    async fn claim_pending_task_board_triage_escalations(
        &self,
        limit: usize,
    ) -> Result<Vec<ClaimedTaskBoardTriageEscalation>, CliError>;

    /// Sweep every `running` row whose `started_at` is older than
    /// `timeout_seconds` to `timed_out`. Returns the `managed_run_id` of
    /// every swept row so the caller can also request the underlying
    /// process stop.
    async fn sweep_stale_task_board_triage_escalations(
        &self,
        timeout_seconds: u64,
    ) -> Result<Vec<String>, CliError>;

    /// Mark one `running` escalation `failed` immediately, with the real
    /// failure reason.
    async fn fail_running_task_board_triage_escalation(
        &self,
        escalation_id: &str,
        failure_reason: &str,
    ) -> Result<(), CliError>;

    /// The current escalation status for one item, if it has a live
    /// (pending/running) escalation.
    async fn task_board_triage_escalation_status_for_item(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardTriageEscalationStatus>, CliError>;

    async fn load_task_board_triage_rules_draft(
        &self,
    ) -> Result<Option<TriageRuleSetDraft>, CliError>;

    /// CAS-save a draft candidate. `expected_revision` must be `None` when
    /// no draft exists yet, or the draft's current revision to replace it.
    async fn save_task_board_triage_rules_draft(
        &self,
        candidate: TriageRuleSetV1,
        actor: String,
        expected_revision: Option<i64>,
    ) -> Result<TriageRuleSetDraftSaveResult, CliError>;

    async fn list_task_board_triage_rules_revisions(
        &self,
        limit: u32,
    ) -> Result<Vec<TriageRuleSetRevisionSummary>, CliError>;

    async fn list_task_board_triage_rules_audit(
        &self,
        limit: u32,
    ) -> Result<Vec<TriageRuleSetAuditEntry>, CliError>;

    /// CAS-activate `candidate`, or deactivate back to the `BuiltInV1`
    /// default when `candidate` is `None`.
    async fn activate_task_board_triage_rules(
        &self,
        candidate: Option<TriageRuleSetV1>,
        actor: String,
        expected_active_revision: Option<i64>,
    ) -> Result<TriageRuleSetActivationResult, CliError>;

    /// Evaluate `candidate` against one frozen read of the current inbox
    /// without persisting anything.
    async fn preview_task_board_triage_rules(
        &self,
        candidate: TriageRuleSetV1,
    ) -> Result<TriageRuleSetPreviewResult, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the plain function that actually owns the
/// area's query logic, kept in the file the query has always lived in.
impl TriageQueries for AsyncDaemonDb {
    async fn task_board_triage_current(
        &self,
        item_id: &str,
    ) -> Result<TaskBoardTriageCurrentRead, CliError> {
        task_board_triage_current(self, item_id).await
    }

    async fn task_board_triage_history(
        &self,
        item_id: &str,
        before_generation: Option<u64>,
        limit: u32,
    ) -> Result<TaskBoardTriageHistoryPage, CliError> {
        task_board_triage_history(self, item_id, before_generation, limit).await
    }

    async fn set_task_board_triage_override(
        &self,
        input: TaskBoardTriageOverrideSetInput,
    ) -> Result<TaskBoardTriageOverrideMutationResult, CliError> {
        triage_override::set_task_board_triage_override(self, input).await
    }

    async fn clear_task_board_triage_override(
        &self,
        input: TaskBoardTriageOverrideClearInput,
    ) -> Result<TaskBoardTriageOverrideMutationResult, CliError> {
        triage_override::clear_task_board_triage_override(self, input).await
    }

    async fn report_task_board_triage_escalation_verdict(
        &self,
        escalation_id: &str,
        verdict_token: &str,
        reported_fingerprint: &str,
        verdict: TriageVerdict,
        rationale: &str,
    ) -> Result<TaskBoardTriageEscalationVerdictOutcome, CliError> {
        triage_escalation_store::report_task_board_triage_escalation_verdict(
            self,
            escalation_id,
            verdict_token,
            reported_fingerprint,
            verdict,
            rationale,
        )
        .await
    }

    async fn count_running_task_board_triage_escalations(&self) -> Result<usize, CliError> {
        triage_escalation_store::count_running_task_board_triage_escalations(self).await
    }

    async fn claim_pending_task_board_triage_escalations(
        &self,
        limit: usize,
    ) -> Result<Vec<ClaimedTaskBoardTriageEscalation>, CliError> {
        triage_escalation_store::claim_pending_task_board_triage_escalations(self, limit).await
    }

    async fn sweep_stale_task_board_triage_escalations(
        &self,
        timeout_seconds: u64,
    ) -> Result<Vec<String>, CliError> {
        triage_escalation_store::sweep_stale_task_board_triage_escalations(self, timeout_seconds)
            .await
    }

    async fn fail_running_task_board_triage_escalation(
        &self,
        escalation_id: &str,
        failure_reason: &str,
    ) -> Result<(), CliError> {
        triage_escalation_store::fail_running_task_board_triage_escalation(
            self,
            escalation_id,
            failure_reason,
        )
        .await
    }

    async fn task_board_triage_escalation_status_for_item(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardTriageEscalationStatus>, CliError> {
        triage_escalation_store::task_board_triage_escalation_status_for_item(self, item_id).await
    }

    async fn load_task_board_triage_rules_draft(
        &self,
    ) -> Result<Option<TriageRuleSetDraft>, CliError> {
        triage_rules_store::load_task_board_triage_rules_draft(self).await
    }

    async fn save_task_board_triage_rules_draft(
        &self,
        candidate: TriageRuleSetV1,
        actor: String,
        expected_revision: Option<i64>,
    ) -> Result<TriageRuleSetDraftSaveResult, CliError> {
        triage_rules_store::save_task_board_triage_rules_draft(
            self,
            candidate,
            actor,
            expected_revision,
        )
        .await
    }

    async fn list_task_board_triage_rules_revisions(
        &self,
        limit: u32,
    ) -> Result<Vec<TriageRuleSetRevisionSummary>, CliError> {
        triage_rules_store::list_task_board_triage_rules_revisions(self, limit).await
    }

    async fn list_task_board_triage_rules_audit(
        &self,
        limit: u32,
    ) -> Result<Vec<TriageRuleSetAuditEntry>, CliError> {
        triage_rules_store::list_task_board_triage_rules_audit(self, limit).await
    }

    async fn activate_task_board_triage_rules(
        &self,
        candidate: Option<TriageRuleSetV1>,
        actor: String,
        expected_active_revision: Option<i64>,
    ) -> Result<TriageRuleSetActivationResult, CliError> {
        triage_rules_activation::activate_task_board_triage_rules(
            self,
            candidate,
            actor,
            expected_active_revision,
        )
        .await
    }

    async fn preview_task_board_triage_rules(
        &self,
        candidate: TriageRuleSetV1,
    ) -> Result<TriageRuleSetPreviewResult, CliError> {
        triage_rules_preview::preview_task_board_triage_rules(self, candidate).await
    }
}

#[cfg(test)]
#[path = "triage_queries_tests.rs"]
mod tests;
