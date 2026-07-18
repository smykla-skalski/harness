use chrono::{DateTime, Duration, Utc};
use sqlx::{Sqlite, Transaction, query_as, query_scalar};

use crate::daemon::db::{CliError, CliErrorKind, db_error, utc_now};
use crate::task_board::{
    TaskBoardAdmissionRequirement, TaskBoardAdmissionRequirementKind, TaskBoardItem,
    TaskBoardOrchestratorSettings, canonical_admission_requirement_key,
};

pub(super) struct CurrentAllowedAdmission {
    pub(super) item_revision: i64,
    pub(super) settings_revision: i64,
    pub(super) launch_profile: Option<String>,
    pub(super) decision_id: String,
    pub(super) generation: i64,
    pub(super) requirements_json: String,
}

pub(super) async fn admission_policy_is_configured_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<bool, CliError> {
    let settings_json = query_scalar::<_, String>(
        "SELECT settings_json FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board admission settings: {error}")))?;
    let settings = serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings_json)
        .map_err(|error| db_error(format!("decode task board admission settings: {error}")))?;
    Ok(!settings.admission_policy.limits.is_empty()
        || !settings.admission_policy.windows.is_empty())
}

pub(super) async fn intent_item_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<(TaskBoardItem, i64), CliError> {
    let item_id = query_scalar::<_, String>(
        "SELECT item_id FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load task board admission intent item: {error}")))?
    .ok_or_else(|| {
        db_error(format!(
            "task board dispatch intent '{intent_id}' not found"
        ))
    })?;
    super::super::items::load_item_in_tx(transaction, &item_id)
        .await?
        .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))
}

pub(super) async fn current_settings_revision(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<i64, CliError> {
    query_scalar::<_, i64>(
        "SELECT revision FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "load task board admission settings revision: {error}"
        ))
    })
}

pub(in crate::daemon::db::task_board) async fn validate_worker_start_fence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected_read_only_fence: Option<(i64, u64)>,
    loaded_item_revision: i64,
) -> Result<(), CliError> {
    let (settings_revision, spawn_kill_switch) = query_as::<_, (i64, bool)>(
        "SELECT settings.revision,
                COALESCE((SELECT spawn_kill_switch FROM policy_workspace
                          WHERE singleton = 1), 0)
         FROM task_board_orchestrator_settings AS settings
         WHERE settings.singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load final task board start fence: {error}")))?;
    if spawn_kill_switch {
        return Err(CliErrorKind::invalid_transition(
            "spawn kill switch engaged; worker start refused".to_string(),
        )
        .into());
    }
    let Some((expected_item_revision, expected_configuration_revision)) = expected_read_only_fence
    else {
        return Ok(());
    };
    if expected_item_revision != loaded_item_revision {
        return Err(CliErrorKind::invalid_transition(
            "read-only workflow item revision changed before worker start".to_string(),
        )
        .into());
    }
    let current_configuration_revision = u64::try_from(settings_revision)
        .map_err(|_| db_error("task board settings revision is out of range"))?;
    if expected_configuration_revision != current_configuration_revision {
        return Err(CliErrorKind::invalid_transition(
            "read-only workflow configuration revision changed before worker start".to_string(),
        )
        .into());
    }
    Ok(())
}

pub(super) async fn current_allowed_admission(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<Option<CurrentAllowedAdmission>, CliError> {
    query_as::<_, (i64, i64, Option<String>, String, i64, String)>(
        "SELECT item_revision, settings_revision, launch_profile,
                decision_id, generation, requirements_json
         FROM task_board_dispatch_admission_decisions
         WHERE intent_id = ?1 AND decision = 'allowed' AND is_current = 1",
    )
    .bind(intent_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map(|value| {
        value.map(
            |(
                item_revision,
                settings_revision,
                launch_profile,
                decision_id,
                generation,
                requirements_json,
            )| CurrentAllowedAdmission {
                item_revision,
                settings_revision,
                launch_profile,
                decision_id,
                generation,
                requirements_json,
            },
        )
    })
    .map_err(|error| db_error(format!("load current task board admission: {error}")))
}

pub(super) async fn stored_reservation_is_complete(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    recorded: &CurrentAllowedAdmission,
) -> Result<bool, CliError> {
    let mut expected = decode_requirements(&recorded.requirements_json)?
        .iter()
        .map(canonical_admission_requirement_key)
        .map(|key| {
            key.map(|key| key.stable_id())
                .map_err(|error| db_error(format!("key stored task board admission: {error}")))
        })
        .collect::<Result<Vec<_>, _>>()?;
    expected.sort();
    let actual = query_scalar::<_, String>(
        "SELECT canonical_key FROM task_board_dispatch_admission_ledger
         WHERE decision_id = ?1 AND intent_id = ?2 AND generation = ?3
           AND state = 'reserved' AND datetime(expires_at) > datetime('now')
         ORDER BY canonical_key",
    )
    .bind(&recorded.decision_id)
    .bind(intent_id)
    .bind(recorded.generation)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load stored task board admission ledger: {error}")))?;
    Ok(actual == expected)
}

pub(super) async fn stored_reservation_time_is_current(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    recorded: &CurrentAllowedAdmission,
) -> Result<bool, CliError> {
    let now = parse_admission_time(&utc_now())?;
    for requirement in decode_requirements(&recorded.requirements_json)? {
        if requirement.kind == TaskBoardAdmissionRequirementKind::Concurrency {
            continue;
        }
        let key = canonical_admission_requirement_key(&requirement)
            .map_err(|error| db_error(format!("key stored task board admission: {error}")))?;
        let window = query_as::<_, (Option<String>, Option<String>)>(
            "SELECT window_started_at, window_ends_at
             FROM task_board_dispatch_admission_ledger
             WHERE decision_id = ?1 AND intent_id = ?2 AND generation = ?3
               AND canonical_key = ?4 AND state = 'reserved'
               AND datetime(expires_at) > datetime('now')",
        )
        .bind(&recorded.decision_id)
        .bind(intent_id)
        .bind(recorded.generation)
        .bind(key.stable_id())
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task board admission window: {error}")))?;
        let Some((Some(starts_at), Some(ends_at))) = window else {
            return Ok(false);
        };
        if !requirement_window_is_current(&requirement, &starts_at, &ends_at, now)? {
            return Ok(false);
        }
    }
    Ok(true)
}

fn requirement_window_is_current(
    requirement: &TaskBoardAdmissionRequirement,
    stored_start: &str,
    stored_end: &str,
    now: DateTime<Utc>,
) -> Result<bool, CliError> {
    let stored_start = parse_admission_time(stored_start)?;
    let stored_end = parse_admission_time(stored_end)?;
    let seconds = requirement
        .window_seconds
        .and_then(|value| i64::try_from(value).ok())
        .ok_or_else(|| db_error("windowed task board admission has no valid duration"))?;
    let (expected_start, expected_end) = match requirement.kind {
        TaskBoardAdmissionRequirementKind::TimeWindow => {
            let start = requirement
                .available_at
                .as_deref()
                .ok_or_else(|| db_error("time-window task board admission has no start"))?;
            let start = parse_admission_time(start)?;
            let end = start
                .checked_add_signed(Duration::seconds(seconds))
                .ok_or_else(|| db_error("task board admission window end overflow"))?;
            if now < start || now >= end {
                return Ok(false);
            }
            (start, end)
        }
        TaskBoardAdmissionRequirementKind::Rate
        | TaskBoardAdmissionRequirementKind::TokenBudget
        | TaskBoardAdmissionRequirementKind::MonetaryBudget => {
            let started_at = now.timestamp().div_euclid(seconds) * seconds;
            let start = DateTime::<Utc>::from_timestamp(started_at, 0)
                .ok_or_else(|| db_error("task board admission window start overflow"))?;
            let end = start
                .checked_add_signed(Duration::seconds(seconds))
                .ok_or_else(|| db_error("task board admission window end overflow"))?;
            (start, end)
        }
        TaskBoardAdmissionRequirementKind::Concurrency => return Ok(true),
    };
    Ok(stored_start == expected_start && stored_end == expected_end)
}

fn parse_admission_time(value: &str) -> Result<DateTime<Utc>, CliError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| db_error(format!("parse task board admission timestamp: {error}")))
}

pub(super) fn decode_requirements(
    value: &str,
) -> Result<Vec<TaskBoardAdmissionRequirement>, CliError> {
    serde_json::from_str(value)
        .map_err(|error| db_error(format!("decode stored task board admission: {error}")))
}
