use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};
use uuid::Uuid;

use super::triage_apply_agent::apply_agent_triage_verdict_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{
    TaskBoardTriageEscalationStatus, TaskBoardTriageEscalationVerdictOutcome, TriageVerdict,
};

/// One `pending` row claimed by the executor and moved to `running`, ready
/// to spawn an agent for.
pub(crate) struct ClaimedTaskBoardTriageEscalation {
    pub(crate) escalation_id: String,
    pub(crate) item_id: String,
    pub(crate) evidence_fingerprint: String,
    pub(crate) verdict_token: String,
    pub(crate) managed_run_id: String,
}

impl AsyncDaemonDb {
    /// Apply one agent-reported verdict. See
    /// `triage_apply_agent::apply_agent_triage_verdict_in_tx` for the full
    /// CAS/eligibility contract; this is only the transaction boundary.
    pub(crate) async fn report_task_board_triage_escalation_verdict(
        &self,
        escalation_id: &str,
        verdict_token: &str,
        reported_fingerprint: &str,
        verdict: TriageVerdict,
        rationale: &str,
    ) -> Result<TaskBoardTriageEscalationVerdictOutcome, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board triage escalation verdict")
            .await?;
        let now = utc_now();
        let outcome = apply_agent_triage_verdict_in_tx(
            &mut transaction,
            escalation_id,
            verdict_token,
            reported_fingerprint,
            verdict,
            rationale,
            &now,
            &self.triage_escalation_config(),
        )
        .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board triage escalation verdict: {error}"))
        })?;
        Ok(outcome)
    }

    /// Count of currently `running` escalations, for the executor to size
    /// its next claim batch against `max_concurrent`.
    pub(crate) async fn count_running_task_board_triage_escalations(&self) -> Result<usize, CliError> {
        let count: i64 = query_scalar(
            "SELECT COUNT(*) FROM task_board_triage_escalations WHERE status = 'running'",
        )
        .fetch_one(self.pool())
        .await
        .map_err(|error| db_error(format!("count running task board triage escalations: {error}")))?;
        Ok(usize::try_from(count).unwrap_or(0))
    }

    /// Claim up to `limit` `pending` rows (oldest `requested_at` first),
    /// minting a fresh single-use `verdict_token` and `managed_run_id` for
    /// each and moving it to `running`. Called once per executor tick; a CAS
    /// `UPDATE ... WHERE status = 'pending'` per row makes a concurrent
    /// claim (there is only ever one executor loop today, but this stays
    /// correct if that ever changes) impossible to double-claim.
    pub(crate) async fn claim_pending_task_board_triage_escalations(
        &self,
        limit: usize,
    ) -> Result<Vec<ClaimedTaskBoardTriageEscalation>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board triage escalation claim")
            .await?;
        let candidates = query_as::<_, (String, String)>(
            "SELECT escalation_id, evidence_fingerprint FROM task_board_triage_escalations
             WHERE status = 'pending' ORDER BY requested_at ASC LIMIT ?1",
        )
        .bind(i64::try_from(limit).unwrap_or(i64::MAX))
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load pending task board triage escalations: {error}")))?;
        let now = utc_now();
        let mut claimed = Vec::with_capacity(candidates.len());
        for (escalation_id, evidence_fingerprint) in candidates {
            let verdict_token = Uuid::new_v4().simple().to_string();
            let managed_run_id = format!("triage-escalation-run-{}", Uuid::new_v4().simple());
            let updated = query(
                "UPDATE task_board_triage_escalations
                 SET status = 'running', started_at = ?2, verdict_token = ?3, managed_run_id = ?4
                 WHERE escalation_id = ?1 AND status = 'pending'",
            )
            .bind(&escalation_id)
            .bind(&now)
            .bind(&verdict_token)
            .bind(&managed_run_id)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("claim task board triage escalation: {error}")))?;
            if updated.rows_affected() == 1 {
                let item_id = item_id_for_escalation_in_tx(&mut transaction, &escalation_id).await?;
                claimed.push(ClaimedTaskBoardTriageEscalation {
                    escalation_id,
                    item_id,
                    evidence_fingerprint,
                    verdict_token,
                    managed_run_id,
                });
            }
        }
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board triage escalation claim: {error}"))
        })?;
        Ok(claimed)
    }

    /// Sweep every `running` row whose `started_at` is older than
    /// `timeout_seconds` to `timed_out`. Covers both an in-process timeout
    /// (the spawned agent never reported) and daemon-restart recovery (a
    /// `running` row left behind by a crash has no live process to ever
    /// report back, and ages past its deadline on the very first tick after
    /// restart identically to an ordinary timeout) -- there is deliberately
    /// no separate recovery code path. Returns the `managed_run_id` of every
    /// swept row so the caller can also request the underlying process stop
    /// -- flipping the DB row alone would otherwise leave a hung agent
    /// process running with no row left pointing at it.
    pub(crate) async fn sweep_stale_task_board_triage_escalations(
        &self,
        timeout_seconds: u64,
    ) -> Result<Vec<String>, CliError> {
        let now = utc_now();
        let cutoff_seconds = i64::try_from(timeout_seconds).unwrap_or(i64::MAX);
        let cutoff = chrono::DateTime::parse_from_rfc3339(&now)
            .map(|parsed| parsed - chrono::Duration::seconds(cutoff_seconds))
            .map_err(|error| db_error(format!("compute task board triage escalation cutoff: {error}")))?
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string();
        let mut transaction = self
            .begin_immediate_transaction("task board triage escalation sweep")
            .await?;
        let stale_run_ids: Vec<String> = query_scalar(
            "SELECT managed_run_id FROM task_board_triage_escalations
             WHERE status = 'running' AND started_at < ?1",
        )
        .bind(&cutoff)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load stale task board triage escalations: {error}")))?;
        query(
            "UPDATE task_board_triage_escalations
             SET status = 'timed_out', completed_at = ?2, failure_reason = 'exceeded timeout'
             WHERE status = 'running' AND started_at < ?1",
        )
        .bind(&cutoff)
        .bind(&now)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("sweep stale task board triage escalations: {error}")))?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit task board triage escalation sweep: {error}"))
        })?;
        Ok(stale_run_ids)
    }

    /// Mark one `running` escalation `failed` immediately, with the real
    /// failure reason -- used when the executor's own attempt to spawn the
    /// agent process fails outright (an error the sweep's timeout path would
    /// otherwise silently absorb and mislabel `timed_out` a full
    /// `timeout_seconds` later).
    pub(crate) async fn fail_running_task_board_triage_escalation(
        &self,
        escalation_id: &str,
        failure_reason: &str,
    ) -> Result<(), CliError> {
        let now = utc_now();
        query(
            "UPDATE task_board_triage_escalations
             SET status = 'failed', completed_at = ?2, failure_reason = ?3
             WHERE escalation_id = ?1 AND status = 'running'",
        )
        .bind(escalation_id)
        .bind(&now)
        .bind(bounded_failure_reason(failure_reason))
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("fail task board triage escalation: {error}")))?;
        Ok(())
    }

    /// The current escalation status for one item, if it has a live
    /// (pending/running) escalation -- the only two states ever surfaced to
    /// a reader, matching [`TaskBoardTriageEscalationStatus`]'s closed shape.
    pub(crate) async fn task_board_triage_escalation_status_for_item(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardTriageEscalationStatus>, CliError> {
        let status: Option<String> = query_scalar(
            "SELECT status FROM task_board_triage_escalations
             WHERE item_id = ?1 AND status IN ('pending', 'running')",
        )
        .bind(item_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("load task board triage escalation status: {error}")))?;
        Ok(match status.as_deref() {
            Some("pending") => Some(TaskBoardTriageEscalationStatus::Pending),
            Some("running") => Some(TaskBoardTriageEscalationStatus::Running),
            _ => None,
        })
    }
}

/// The migration's `CHECK` bounds `failure_reason` to 1024 bytes; a raw
/// `CliError` display string is normally well under that, but this stays
/// defensive against ever passing through a longer one uncaught.
fn bounded_failure_reason(reason: &str) -> &str {
    let mut end = reason.len().min(1024);
    while end > 0 && !reason.is_char_boundary(end) {
        end -= 1;
    }
    &reason[..end]
}

async fn item_id_for_escalation_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    escalation_id: &str,
) -> Result<String, CliError> {
    query_scalar("SELECT item_id FROM task_board_triage_escalations WHERE escalation_id = ?1")
        .bind(escalation_id)
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board triage escalation item id: {error}")))
}

#[cfg(test)]
#[path = "triage_escalation_store_tests.rs"]
mod tests;
