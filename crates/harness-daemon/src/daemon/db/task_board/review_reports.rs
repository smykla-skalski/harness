use chrono::DateTime;
use sqlx::{Sqlite, Transaction, query, query_as};

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use crate::daemon::db::prelude::*;
#[cfg(test)]
use crate::daemon::db::task_board::item_core_queries::ItemCoreQueries;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TaskBoardAiReviewReportRecord, TaskBoardAiReviewReportStatus, TaskBoardReportOnlyReviewFinding,
    validate_task_board_ai_review_report,
};

#[derive(Debug, sqlx::FromRow)]
struct AiReviewReportRow {
    report_id: String,
    item_id: String,
    correlation_id: String,
    repository: String,
    pull_request_number: i64,
    head_revision: String,
    runtime: String,
    requested_runtime: Option<String>,
    actual_runtime: Option<String>,
    requested_model: String,
    effective_model: Option<String>,
    status: String,
    summary: Option<String>,
    findings_json: String,
    partial_output: Option<String>,
    terminal_reason: Option<String>,
    started_at: String,
    finished_at: String,
}

pub(crate) async fn append_task_board_ai_review_report(
    db: &AsyncDaemonDb,
    report: &TaskBoardAiReviewReportRecord,
) -> Result<bool, CliError> {
    validate_task_board_ai_review_report(report)
        .map_err(|error| db_error(format!("validate AI review report: {error}")))?;
    let mut transaction = db
        .begin_immediate_transaction("append AI review report")
        .await?;
    if let Some(existing) = load_by_id(&mut transaction, &report.report_id).await? {
        transaction.rollback().await.map_err(|error| {
            db_error(format!(
                "rollback unchanged AI review report append: {error}"
            ))
        })?;
        if existing == *report {
            return Ok(false);
        }
        return Err(db_error(format!(
            "AI review report '{}' already exists with different content",
            report.report_id
        )));
    }
    insert_report(&mut transaction, report).await?;
    insert_report_order(&mut transaction, &report.report_id).await?;
    bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit AI review report append: {error}")))?;
    Ok(true)
}

pub(crate) async fn task_board_ai_review_reports(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<Vec<TaskBoardAiReviewReportRecord>, CliError> {
    let rows = query_as::<_, AiReviewReportRow>(
        "SELECT report.report_id, report.item_id, report.correlation_id, report.repository,
                report.pull_request_number, report.head_revision, report.runtime,
                report.requested_runtime, report.actual_runtime, report.requested_model,
                report.effective_model, report.status, report.summary, report.findings_json,
                report.partial_output, report.terminal_reason, report.started_at,
                report.finished_at
         FROM task_board_ai_review_reports AS report
         JOIN task_board_ai_review_report_order AS report_order
           ON report_order.report_id = report.report_id
         WHERE report.item_id = ?1
         ORDER BY report_order.sequence DESC",
    )
    .bind(item_id)
    .fetch_all(db.pool())
    .await
    .map_err(|error| db_error(format!("list AI review reports for '{item_id}': {error}")))?;
    rows.into_iter()
        .map(AiReviewReportRow::into_record)
        .collect()
}

pub(crate) async fn task_board_latest_ai_review_report(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<Option<TaskBoardAiReviewReportRecord>, CliError> {
    query_as::<_, AiReviewReportRow>(
        "SELECT report.report_id, report.item_id, report.correlation_id, report.repository,
                report.pull_request_number, report.head_revision, report.runtime,
                report.requested_runtime, report.actual_runtime, report.requested_model,
                report.effective_model, report.status, report.summary, report.findings_json,
                report.partial_output, report.terminal_reason, report.started_at,
                report.finished_at
         FROM task_board_ai_review_reports AS report
         JOIN task_board_ai_review_report_order AS report_order
           ON report_order.report_id = report.report_id
         WHERE report.item_id = ?1
         ORDER BY report_order.sequence DESC
         LIMIT 1",
    )
    .bind(item_id)
    .fetch_optional(db.pool())
    .await
    .map_err(|error| {
        db_error(format!(
            "load latest AI review report for '{item_id}': {error}"
        ))
    })?
    .map(AiReviewReportRow::into_record)
    .transpose()
}

async fn load_by_id(
    transaction: &mut Transaction<'_, Sqlite>,
    report_id: &str,
) -> Result<Option<TaskBoardAiReviewReportRecord>, CliError> {
    query_as::<_, AiReviewReportRow>(
        "SELECT report_id, item_id, correlation_id, repository, pull_request_number,
                head_revision, runtime, requested_runtime, actual_runtime, requested_model,
                effective_model, status, summary,
                findings_json, partial_output, terminal_reason, started_at, finished_at
         FROM task_board_ai_review_reports
         WHERE report_id = ?1",
    )
    .bind(report_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load AI review report '{report_id}': {error}")))?
    .map(AiReviewReportRow::into_record)
    .transpose()
}

async fn insert_report(
    transaction: &mut Transaction<'_, Sqlite>,
    report: &TaskBoardAiReviewReportRecord,
) -> Result<(), CliError> {
    let pull_request_number = i64::try_from(report.pull_request_number)
        .map_err(|_| db_error("AI review pull request number exceeds SQLite integer range"))?;
    let finished_at_unix_millis = DateTime::parse_from_rfc3339(&report.finished_at)
        .map_err(|error| db_error(format!("parse AI review finish time: {error}")))?
        .timestamp_millis();
    let findings_json = serde_json::to_string(&report.findings)
        .map_err(|error| db_error(format!("serialize AI review findings: {error}")))?;
    query(
        "INSERT INTO task_board_ai_review_reports (
            report_id, item_id, correlation_id, repository, pull_request_number, head_revision,
            runtime, requested_runtime, actual_runtime, requested_model, effective_model, status,
            summary, findings_json,
            partial_output, terminal_reason, started_at, finished_at, finished_at_unix_millis
         ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17,
            ?18, ?19
         )",
    )
    .bind(&report.report_id)
    .bind(&report.item_id)
    .bind(&report.correlation_id)
    .bind(&report.repository)
    .bind(pull_request_number)
    .bind(&report.head_revision)
    .bind(&report.runtime)
    .bind(&report.requested_runtime)
    .bind(&report.actual_runtime)
    .bind(&report.requested_model)
    .bind(&report.effective_model)
    .bind(report.status.as_str())
    .bind(&report.summary)
    .bind(findings_json)
    .bind(&report.partial_output)
    .bind(&report.terminal_reason)
    .bind(&report.started_at)
    .bind(&report.finished_at)
    .bind(finished_at_unix_millis)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "insert AI review report '{}': {error}",
            report.report_id
        ))
    })?;
    Ok(())
}

async fn insert_report_order(
    transaction: &mut Transaction<'_, Sqlite>,
    report_id: &str,
) -> Result<(), CliError> {
    query("INSERT INTO task_board_ai_review_report_order (report_id) VALUES (?1)")
        .bind(report_id)
        .execute(transaction.as_mut())
        .await
        .map(|_| ())
        .map_err(|error| {
            db_error(format!(
                "insert AI review report order for '{report_id}': {error}"
            ))
        })
}

impl AiReviewReportRow {
    fn into_record(self) -> Result<TaskBoardAiReviewReportRecord, CliError> {
        let pull_request_number = u64::try_from(self.pull_request_number)
            .map_err(|_| db_error("stored AI review pull request number is invalid"))?;
        let findings =
            serde_json::from_str::<Vec<TaskBoardReportOnlyReviewFinding>>(&self.findings_json)
                .map_err(|error| {
                    db_error(format!(
                        "parse AI review findings for '{}': {error}",
                        self.report_id
                    ))
                })?;
        let record = TaskBoardAiReviewReportRecord {
            report_id: self.report_id,
            item_id: self.item_id,
            correlation_id: self.correlation_id,
            repository: self.repository,
            pull_request_number,
            head_revision: self.head_revision,
            requested_runtime: self
                .requested_runtime
                .unwrap_or_else(|| self.runtime.clone()),
            actual_runtime: self.actual_runtime,
            runtime: self.runtime,
            requested_model: self.requested_model,
            effective_model: self.effective_model,
            status: TaskBoardAiReviewReportStatus::parse(&self.status)
                .map_err(|error| db_error(format!("parse AI review status: {error}")))?,
            summary: self.summary,
            findings,
            partial_output: self.partial_output,
            terminal_reason: self.terminal_reason,
            started_at: self.started_at,
            finished_at: self.finished_at,
        };
        validate_task_board_ai_review_report(&record)
            .map_err(|error| db_error(format!("validate stored AI review report: {error}")))?;
        Ok(record)
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;
    use crate::daemon::db_open::AsyncDaemonDbConnect;
    use crate::task_board::{TaskBoardReviewFindingLocation, TaskBoardReviewFindingSeverity};

    #[tokio::test]
    async fn append_is_idempotent_and_history_survives_restart() {
        let directory = tempdir().expect("tempdir");
        let path = directory.path().join("harness.db");
        let db = AsyncDaemonDb::connect(&path).await.expect("connect");
        let completed = report("report-1", "turn-1", "2026-07-29T16:30:00Z");

        assert!(
            db.append_task_board_ai_review_report(&completed)
                .await
                .expect("append")
        );
        let sequence_after_append = db
            .current_change_sequence()
            .await
            .expect("change sequence after append");
        assert!(
            !db.append_task_board_ai_review_report(&completed)
                .await
                .expect("repeat")
        );
        assert_eq!(
            db.current_change_sequence()
                .await
                .expect("change sequence after replay"),
            sequence_after_append
        );
        drop(db);

        let reopened = AsyncDaemonDb::connect(&path).await.expect("reopen");
        let mut cancelled = report("report-2", "turn-2", "2026-07-29T17:00:00+01:00");
        cancelled.status = TaskBoardAiReviewReportStatus::Cancelled;
        cancelled.partial_output = Some(r#"{"summary":"Interrupted"#.into());
        cancelled.terminal_reason = Some("cancelled after partial output".into());
        reopened
            .append_task_board_ai_review_report(&cancelled)
            .await
            .expect("append cancelled report");
        let mut failed = report("report-3", "turn-3", "2026-07-29T18:00:00+01:00");
        failed.status = TaskBoardAiReviewReportStatus::Failed;
        failed.partial_output = Some("Provider emitted one incomplete finding.".into());
        failed.terminal_reason = Some("provider stopped after partial output".into());
        reopened
            .append_task_board_ai_review_report(&failed)
            .await
            .expect("append failed report");

        assert_eq!(
            reopened
                .task_board_latest_ai_review_report("ticket-899")
                .await
                .expect("latest report"),
            Some(failed.clone())
        );
        assert_eq!(
            reopened
                .task_board_ai_review_reports("ticket-899")
                .await
                .expect("history"),
            vec![failed, cancelled, completed]
        );
    }

    #[tokio::test]
    async fn append_rejects_same_identity_with_different_content() {
        let directory = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
            .await
            .expect("connect");
        let original = report("report-1", "turn-1", "2026-07-29T16:00:01Z");
        db.append_task_board_ai_review_report(&original)
            .await
            .expect("append");
        let mut drifted = original.clone();
        drifted.summary = Some("Different output.".into());

        db.append_task_board_ai_review_report(&drifted)
            .await
            .expect_err("identity reuse must fail");
        assert_eq!(
            db.task_board_ai_review_reports("ticket-899")
                .await
                .expect("history"),
            vec![original]
        );
    }

    #[tokio::test]
    async fn latest_uses_append_order_when_reports_finish_at_the_same_time() {
        let directory = tempdir().expect("tempdir");
        let path = directory.path().join("harness.db");
        let db = AsyncDaemonDb::connect(&path).await.expect("connect");
        let first = report("report-z", "turn-1", "2026-07-29T16:00:01Z");
        let second = report("report-a", "turn-2", "2026-07-29T16:00:01Z");

        db.append_task_board_ai_review_report(&first)
            .await
            .expect("append first");
        db.append_task_board_ai_review_report(&second)
            .await
            .expect("append second");
        drop(db);

        let reopened = AsyncDaemonDb::connect(&path).await.expect("reopen");
        assert_eq!(
            reopened
                .task_board_latest_ai_review_report("ticket-899")
                .await
                .expect("latest"),
            Some(second.clone())
        );
        assert_eq!(
            reopened
                .task_board_ai_review_reports("ticket-899")
                .await
                .expect("history"),
            vec![second, first]
        );
    }

    fn report(
        report_id: &str,
        correlation_id: &str,
        finished_at: &str,
    ) -> TaskBoardAiReviewReportRecord {
        TaskBoardAiReviewReportRecord {
            report_id: report_id.into(),
            item_id: "ticket-899".into(),
            correlation_id: correlation_id.into(),
            repository: "smykla-skalski/harness".into(),
            pull_request_number: 1122,
            head_revision: "0123456789abcdef0123456789abcdef01234567".into(),
            runtime: "openrouter".into(),
            requested_runtime: "openrouter".into(),
            actual_runtime: Some("openrouter".into()),
            requested_model: "deepseek/deepseek-v4-flash".into(),
            effective_model: Some("deepseek/deepseek-v4-flash".into()),
            status: TaskBoardAiReviewReportStatus::Completed,
            summary: Some("One actionable defect.".into()),
            findings: vec![TaskBoardReportOnlyReviewFinding {
                severity: TaskBoardReviewFindingSeverity::High,
                location: TaskBoardReviewFindingLocation {
                    path: "src/lib.rs".into(),
                    line: Some(41),
                },
                evidence: "The new branch skips validation.".into(),
            }],
            partial_output: None,
            terminal_reason: None,
            started_at: "2026-07-29T16:00:00Z".into(),
            finished_at: finished_at.into(),
        }
    }
}
