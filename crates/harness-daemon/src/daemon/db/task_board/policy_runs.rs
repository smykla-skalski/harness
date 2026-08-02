use chrono::{DateTime, Utc};
use sqlx::{Sqlite, Transaction, query, query_as};

use super::POLICY_RUNTIME_CHANGE_SCOPE;
use super::items::bump_change_in_tx;
use super::mapper::{label, parse_json, to_json};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::policy_runtime::events::run_matches_event;
use crate::task_board::policy_runtime::models::{
    PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun, PolicyWorkflowRunsDocument,
};
use crate::task_board::policy_runtime::repository::{
    BeginRunOutcome, begin_run_in_document, claim_waiting_run_in_document, save_run_in_document,
};
use crate::task_board::policy_runtime::scheduler::timer_wait_is_due;

/// Real implementations behind the matching [`PolicyRuntimeQueries`] methods,
/// called from the single consolidated trait impl in
/// `policy_runtime_queries.rs` (a trait's methods can only be implemented in
/// one `impl` block per type, so this file hands it plain functions instead
/// of declaring its own `impl PolicyRuntimeQueries for AsyncDaemonDb`).
pub(super) async fn save_policy_workflow_run(
    db: &AsyncDaemonDb,
    run: &PolicyWorkflowRun,
) -> Result<i64, CliError> {
    update_policy_runs(db, "policy run save", |document| {
        save_run_in_document(document, run);
        Ok(())
    })
    .await
    .map(|((), revision)| revision)
}

pub(super) async fn begin_policy_workflow_run(
    db: &AsyncDaemonDb,
    run: PolicyWorkflowRun,
    trigger: PolicyRunTrigger,
    now: DateTime<Utc>,
) -> Result<BeginRunOutcome, CliError> {
    update_policy_runs(db, "policy run begin", |document| {
        Ok(begin_run_in_document(document, run, trigger, now))
    })
    .await
    .map(|(outcome, _)| outcome)
}

pub(super) async fn claim_waiting_policy_run(
    db: &AsyncDaemonDb,
    run_id: &str,
    trigger: PolicyRunTrigger,
) -> Result<Option<PolicyWorkflowRun>, CliError> {
    update_policy_runs(db, "policy run claim", |document| {
        Ok(claim_waiting_run_in_document(document, run_id, trigger))
    })
    .await
    .map(|(run, _)| run)
}

pub(super) async fn policy_workflow_runs(
    db: &AsyncDaemonDb,
) -> Result<Vec<PolicyWorkflowRun>, CliError> {
    let mut runs = load_runs(db.pool()).await?;
    sort_newest(&mut runs);
    Ok(runs)
}

pub(super) async fn policy_run_by_id(
    db: &AsyncDaemonDb,
    run_id: &str,
) -> Result<Option<PolicyWorkflowRun>, CliError> {
    query_as::<_, (String,)>("SELECT payload_json FROM policy_workflow_runs WHERE run_id = ?1")
        .bind(run_id)
        .fetch_optional(db.pool())
        .await
        .map_err(|error| db_error(format!("load policy run '{run_id}': {error}")))?
        .map(|row| parse_json(&row.0, "policy workflow run"))
        .transpose()
}

pub(super) async fn policy_runs_for_subject(
    db: &AsyncDaemonDb,
    workflow_id: &str,
    subject_key: &str,
) -> Result<Vec<PolicyWorkflowRun>, CliError> {
    let rows = query_as::<_, (String,)>(
        "SELECT payload_json FROM policy_workflow_runs
            WHERE workflow_id = ?1 AND subject_key = ?2
            ORDER BY updated_at DESC, created_at DESC",
    )
    .bind(workflow_id)
    .bind(subject_key)
    .fetch_all(db.pool())
    .await
    .map_err(|error| db_error(format!("load policy subject runs: {error}")))?;
    parse_run_rows(rows)
}

pub(super) async fn active_policy_runs_for_subject(
    db: &AsyncDaemonDb,
    workflow_id: &str,
    subject_key: &str,
) -> Result<Vec<PolicyWorkflowRun>, CliError> {
    let rows = query_as::<_, (String,)>(
        "SELECT payload_json FROM policy_workflow_runs
            WHERE workflow_id = ?1 AND subject_key = ?2
              AND status IN ('running', 'waiting')
            ORDER BY updated_at DESC, created_at DESC",
    )
    .bind(workflow_id)
    .bind(subject_key)
    .fetch_all(db.pool())
    .await
    .map_err(|error| db_error(format!("load active policy subject runs: {error}")))?;
    parse_run_rows(rows)
}

pub(super) async fn policy_run_ids_ready_for_event(
    db: &AsyncDaemonDb,
    event: &PolicyWorkflowEvent,
) -> Result<Vec<String>, CliError> {
    Ok(policy_workflow_runs(db)
        .await?
        .into_iter()
        .filter(|run| run_matches_event(run, event))
        .map(|run| run.run_id)
        .collect())
}

pub(super) async fn policy_runs_ready_for_timer(
    db: &AsyncDaemonDb,
    now: DateTime<Utc>,
) -> Result<Vec<PolicyWorkflowRun>, CliError> {
    let mut runs = Vec::new();
    for run in policy_workflow_runs(db).await? {
        if timer_wait_is_due(&run, &now)? {
            runs.push(run);
        }
    }
    runs.sort_by(|left, right| {
        left.updated_at
            .cmp(&right.updated_at)
            .then_with(|| left.created_at.cmp(&right.created_at))
    });
    Ok(runs)
}

async fn update_policy_runs<R>(
    db: &AsyncDaemonDb,
    context: &str,
    mutate: impl FnOnce(&mut PolicyWorkflowRunsDocument) -> Result<R, CliError>,
) -> Result<(R, i64), CliError> {
    let mut transaction = db.begin_immediate_transaction(context).await?;
    let mut document = PolicyWorkflowRunsDocument {
        runs: load_runs(transaction.as_mut()).await?,
        ..PolicyWorkflowRunsDocument::default()
    };
    let result = mutate(&mut document)?;
    write_runs(&mut transaction, &document.runs).await?;
    let revision = bump_change_in_tx(&mut transaction, POLICY_RUNTIME_CHANGE_SCOPE).await?;
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {context}: {error}")))?;
    Ok((result, revision))
}

async fn load_runs<'e, E>(executor: E) -> Result<Vec<PolicyWorkflowRun>, CliError>
where
    E: sqlx::Executor<'e, Database = Sqlite>,
{
    let rows =
        query_as::<_, (String,)>("SELECT payload_json FROM policy_workflow_runs ORDER BY position")
            .fetch_all(executor)
            .await
            .map_err(|error| db_error(format!("load policy workflow runs: {error}")))?;
    parse_run_rows(rows)
}

fn parse_run_rows(rows: Vec<(String,)>) -> Result<Vec<PolicyWorkflowRun>, CliError> {
    rows.into_iter()
        .map(|row| parse_json(&row.0, "policy workflow run"))
        .collect()
}

async fn write_runs(
    transaction: &mut Transaction<'_, Sqlite>,
    runs: &[PolicyWorkflowRun],
) -> Result<(), CliError> {
    query("DELETE FROM policy_workflow_runs")
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("clear policy workflow runs: {error}")))?;
    for (position, run) in runs.iter().enumerate() {
        insert_run(transaction, run, position).await?;
    }
    Ok(())
}

async fn insert_run(
    transaction: &mut Transaction<'_, Sqlite>,
    run: &PolicyWorkflowRun,
    position: usize,
) -> Result<(), CliError> {
    query(
        "INSERT INTO policy_workflow_runs (
        run_id, position, workflow_id, subject_key, subject_fingerprint, trigger, status,
        waiting_since, created_at, updated_at, completed_at, payload_json, revision
    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 1)",
    )
    .bind(&run.run_id)
    .bind(i64::try_from(position).unwrap_or(i64::MAX))
    .bind(&run.workflow_id)
    .bind(&run.subject.key)
    .bind(&run.subject_fingerprint)
    .bind(label(run.trigger, "policy run trigger")?)
    .bind(label(run.status, "policy run status")?)
    .bind(&run.waiting_since)
    .bind(&run.created_at)
    .bind(&run.updated_at)
    .bind(&run.completed_at)
    .bind(to_json(run, "policy workflow run")?)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert policy run '{}': {error}", run.run_id)))?;
    Ok(())
}

fn sort_newest(runs: &mut [PolicyWorkflowRun]) {
    runs.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| right.created_at.cmp(&left.created_at))
    });
}
