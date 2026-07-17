use chrono::{DateTime, Duration, SecondsFormat, Utc};
use sqlx::{Sqlite, Transaction, query, query_scalar};
use uuid::Uuid;

use super::admission::TaskBoardDispatchAdmissionSnapshot;
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::{
    TaskBoardAdmissionDecision, TaskBoardAdmissionRequirement, TaskBoardAdmissionRequirementKind,
    TaskBoardAdmissionUsage, TaskBoardLaunchCapability, canonical_admission_requirement_key,
};

const ADMISSION_RESERVATION_SECONDS: i64 = 900;

pub(super) async fn admission_usage_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    requirements: &[TaskBoardAdmissionRequirement],
    evaluated_at: &str,
    excluded_intent_id: Option<&str>,
) -> Result<Vec<TaskBoardAdmissionUsage>, CliError> {
    release_expired_admission_in_tx(transaction, evaluated_at).await?;
    let mut usage = Vec::with_capacity(requirements.len());
    for requirement in requirements {
        if requirement.kind == TaskBoardAdmissionRequirementKind::TimeWindow {
            continue;
        }
        let key = canonical_admission_requirement_key(requirement)
            .map_err(|error| db_error(format!("key task board admission requirement: {error}")))?;
        let window = ledger_window(requirement, evaluated_at)?;
        let consumed = query_scalar::<_, i64>(
            "SELECT COALESCE(SUM(amount), 0)
             FROM task_board_dispatch_admission_ledger
             WHERE canonical_key = ?1 AND state IN ('reserved', 'committed')
               AND (?2 IS NULL OR window_started_at = ?2)
               AND (?3 IS NULL OR window_ends_at = ?3)
               AND (?4 IS NULL OR intent_id != ?4)",
        )
        .bind(key.stable_id())
        .bind(window.as_ref().map(|value| value.0.as_str()))
        .bind(window.as_ref().map(|value| value.1.as_str()))
        .bind(excluded_intent_id)
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board admission usage: {error}")))?;
        usage.push(TaskBoardAdmissionUsage {
            kind: requirement.kind,
            scope: requirement.scope.clone(),
            consumed: u64::try_from(consumed).map_err(|error| {
                db_error(format!("convert task board admission usage: {error}"))
            })?,
            window_seconds: requirement.window_seconds,
            available_at: window.map(|value| value.1),
        });
    }
    Ok(usage)
}

async fn release_expired_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    evaluated_at: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'released', expires_at = NULL, released_at = ?1
         WHERE state = 'reserved' AND datetime(expires_at) <= datetime(?1)",
    )
    .bind(evaluated_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("release expired task board admission: {error}")))?;
    Ok(())
}

pub(super) async fn persist_admission_snapshot_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    intent_id: Option<&str>,
    snapshot: &mut TaskBoardDispatchAdmissionSnapshot,
) -> Result<(), CliError> {
    release_reserved_admission_in_tx(transaction, intent_id).await?;
    supersede_current_admission_in_tx(transaction, item_id, intent_id).await?;
    snapshot.generation = next_admission_generation(transaction, item_id).await?;
    snapshot.decision_id = format!("admission-decision-{}", Uuid::new_v4().simple());
    insert_decision(transaction, item_id, intent_id, snapshot).await?;
    if snapshot.is_allowed() {
        let intent_id = intent_id.ok_or_else(|| {
            db_error("allowed task board admission decision requires a dispatch intent")
        })?;
        insert_ledger(transaction, item_id, intent_id, snapshot).await?;
    }
    Ok(())
}

pub(super) async fn clear_current_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    intent_id: Option<&str>,
) -> Result<(), CliError> {
    release_reserved_admission_in_tx(transaction, intent_id).await?;
    supersede_current_admission_in_tx(transaction, item_id, intent_id).await
}

pub(super) async fn release_reserved_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: Option<&str>,
) -> Result<(), CliError> {
    let Some(intent_id) = intent_id else {
        return Ok(());
    };
    let now = utc_now();
    query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'released', expires_at = NULL, released_at = ?2
         WHERE intent_id = ?1 AND state = 'reserved'",
    )
    .bind(intent_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("release task board admission reservation: {error}")))?;
    Ok(())
}

async fn supersede_current_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    intent_id: Option<&str>,
) -> Result<(), CliError> {
    let now = utc_now();
    query(
        "UPDATE task_board_dispatch_admission_decisions
         SET is_current = 0, superseded_at = ?3
         WHERE is_current = 1 AND item_id = ?1
           AND (intent_id IS NULL OR intent_id = ?2)",
    )
    .bind(item_id)
    .bind(intent_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("supersede task board admission decision: {error}")))?;
    Ok(())
}

async fn next_admission_generation(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<i64, CliError> {
    query_scalar::<_, i64>(
        "SELECT COALESCE(MAX(generation), 0) + 1
         FROM task_board_dispatch_admission_decisions WHERE item_id = ?1",
    )
    .bind(item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("allocate task board admission generation: {error}")))
}

async fn insert_decision(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    intent_id: Option<&str>,
    snapshot: &TaskBoardDispatchAdmissionSnapshot,
) -> Result<(), CliError> {
    let policy_json = json_text(&snapshot.policy, "policy")?;
    let context_json = json_text(&snapshot.context, "context")?;
    let requirements_json = json_text(&snapshot.requirements, "requirements")?;
    let blockers_json = json_text(&snapshot.blockers, "blockers")?;
    query(
        "INSERT INTO task_board_dispatch_admission_decisions (
            decision_id, intent_id, generation, item_id, item_revision,
            settings_revision, decision, policy_json, context_json,
            requirements_json, blockers_json, launch_profile, evaluated_at,
            next_available_at, is_current, created_at
         ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 1, ?15
         )",
    )
    .bind(&snapshot.decision_id)
    .bind(intent_id)
    .bind(snapshot.generation)
    .bind(item_id)
    .bind(snapshot.item_revision)
    .bind(snapshot.settings_revision)
    .bind(decision_name(snapshot.decision))
    .bind(policy_json)
    .bind(context_json)
    .bind(requirements_json)
    .bind(blockers_json)
    .bind(snapshot.launch_capability.map(launch_profile_name))
    .bind(&snapshot.evaluated_at)
    .bind(snapshot.next_available_at.as_deref())
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert task board admission decision: {error}")))?;
    Ok(())
}

async fn insert_ledger(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    intent_id: &str,
    snapshot: &TaskBoardDispatchAdmissionSnapshot,
) -> Result<(), CliError> {
    let expires_at = offset_time(&snapshot.evaluated_at, ADMISSION_RESERVATION_SECONDS)?;
    for requirement in &snapshot.requirements {
        let key = canonical_admission_requirement_key(requirement)
            .map_err(|error| db_error(format!("key task board admission ledger: {error}")))?;
        let window = ledger_window(requirement, &snapshot.evaluated_at)?;
        let amount = ledger_amount(requirement)?;
        query(
            "INSERT INTO task_board_dispatch_admission_ledger (
                ledger_id, decision_id, decision, intent_id, generation, item_id,
                canonical_key, kind, scope, amount, limit_value,
                window_started_at, window_ends_at, state, expires_at, reserved_at
             ) VALUES (
                ?1, ?2, 'allowed', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
                ?11, ?12, 'reserved', ?13, ?14
             )",
        )
        .bind(format!("admission-ledger-{}", Uuid::new_v4().simple()))
        .bind(&snapshot.decision_id)
        .bind(intent_id)
        .bind(snapshot.generation)
        .bind(item_id)
        .bind(key.stable_id())
        .bind(kind_name(requirement.kind))
        .bind(&requirement.scope)
        .bind(amount)
        .bind(to_i64(requirement.limit, "limit")?)
        .bind(window.as_ref().map(|value| value.0.as_str()))
        .bind(window.as_ref().map(|value| value.1.as_str()))
        .bind(&expires_at)
        .bind(&snapshot.evaluated_at)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("insert task board admission ledger: {error}")))?;
    }
    Ok(())
}

fn ledger_window(
    requirement: &TaskBoardAdmissionRequirement,
    evaluated_at: &str,
) -> Result<Option<(String, String)>, CliError> {
    if requirement.kind == TaskBoardAdmissionRequirementKind::Concurrency {
        return Ok(None);
    }
    let seconds = requirement
        .window_seconds
        .ok_or_else(|| db_error("windowed task board admission has no duration"))?;
    let seconds = to_i64(seconds, "window")?;
    if requirement.kind == TaskBoardAdmissionRequirementKind::TimeWindow {
        let start = requirement
            .available_at
            .as_deref()
            .ok_or_else(|| db_error("time-window task board admission has no start"))?;
        return Ok(Some((start.to_string(), offset_time(start, seconds)?)));
    }
    let evaluated_at = parse_time(evaluated_at)?;
    let started_at = evaluated_at.timestamp().div_euclid(seconds) * seconds;
    let start = DateTime::<Utc>::from_timestamp(started_at, 0)
        .ok_or_else(|| db_error("task board admission window start overflow"))?;
    let end = start
        .checked_add_signed(Duration::seconds(seconds))
        .ok_or_else(|| db_error("task board admission window end overflow"))?;
    Ok(Some((canonical_time(start), canonical_time(end))))
}

fn ledger_amount(requirement: &TaskBoardAdmissionRequirement) -> Result<i64, CliError> {
    if requirement.kind == TaskBoardAdmissionRequirementKind::TimeWindow {
        return Ok(0);
    }
    to_i64(
        requirement
            .reservation
            .ok_or_else(|| db_error("task board admission has no reservation amount"))?,
        "reservation",
    )
}

fn offset_time(value: &str, seconds: i64) -> Result<String, CliError> {
    parse_time(value)?
        .checked_add_signed(Duration::seconds(seconds))
        .map(canonical_time)
        .ok_or_else(|| db_error("task board admission timestamp overflow"))
}

fn parse_time(value: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| db_error(format!("parse task board admission timestamp: {error}")))
}

fn canonical_time(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn json_text(value: &impl serde::Serialize, label: &str) -> Result<String, CliError> {
    serde_json::to_string(value)
        .map_err(|error| db_error(format!("serialize task board admission {label}: {error}")))
}

fn to_i64(value: u64, label: &str) -> Result<i64, CliError> {
    i64::try_from(value)
        .map_err(|error| db_error(format!("convert task board admission {label}: {error}")))
}

const fn decision_name(decision: TaskBoardAdmissionDecision) -> &'static str {
    match decision {
        TaskBoardAdmissionDecision::Allowed => "allowed",
        TaskBoardAdmissionDecision::Deferred => "deferred",
        TaskBoardAdmissionDecision::Rejected => "rejected",
    }
}

const fn launch_profile_name(capability: TaskBoardLaunchCapability) -> &'static str {
    match capability {
        TaskBoardLaunchCapability::ReportReadOnly => "read_only",
        TaskBoardLaunchCapability::WorkspaceWrite => "workspace_write",
    }
}

const fn kind_name(kind: TaskBoardAdmissionRequirementKind) -> &'static str {
    match kind {
        TaskBoardAdmissionRequirementKind::Concurrency => "concurrency",
        TaskBoardAdmissionRequirementKind::Rate => "rate",
        TaskBoardAdmissionRequirementKind::TimeWindow => "time_window",
        TaskBoardAdmissionRequirementKind::TokenBudget => "token_budget",
        TaskBoardAdmissionRequirementKind::MonetaryBudget => "monetary_budget",
    }
}
