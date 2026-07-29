use std::slice;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::{query, query_as};

use super::super::ORCHESTRATOR_CHANGE_SCOPE;
use super::super::items::bump_change_in_tx;
use super::audit::{broadcast_automation_audits, insert_automation_audit, parse_scope};
use super::runs::TaskBoardAutomationRunLease;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardAutomationRunStage;

#[derive(Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct StoredStageSummary {
    #[serde(default)]
    stages: Vec<TaskBoardAutomationRunStage>,
}

impl AsyncDaemonDb {
    pub(crate) async fn upsert_task_board_automation_run_stage(
        &self,
        lease: &TaskBoardAutomationRunLease,
        stage: &TaskBoardAutomationRunStage,
        now: DateTime<Utc>,
    ) -> Result<u64, CliError> {
        let run_id = &lease.run_id;
        validate_stage(stage, run_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board automation run stage upsert")
            .await?;
        let (stored, scope_json, revision) = query_as::<_, (String, String, i64)>(
            "SELECT stage_summary_json, scope_json, revision
             FROM task_board_orchestrator_runs
             WHERE run_id = ?1 AND lease_owner = ?2 AND lease_epoch = ?3
               AND state IN ('running', 'cancelling') AND lease_expires_at > ?4",
        )
        .bind(run_id)
        .bind(&lease.lease_owner)
        .bind(i64::try_from(lease.lease_epoch).unwrap_or(i64::MAX))
        .bind(now.to_rfc3339())
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!(
                "load task board automation run stage summary '{run_id}': {error}"
            ))
        })?
        .ok_or_else(|| {
            db_error(format!(
                "task board automation run '{run_id}' lost its stage-write lease"
            ))
        })?;
        let stored = updated_stage_summary(&stored, stage, run_id)?;
        let next_revision = revision.checked_add(1).ok_or_else(|| {
            db_error(format!(
                "task board automation run '{run_id}' revision overflow"
            ))
        })?;
        update_stage_summary(
            &mut transaction,
            lease,
            &stored,
            revision,
            next_revision,
            now,
        )
        .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        let scope = parse_scope(&scope_json, run_id)?;
        let event = insert_automation_audit(
            &mut transaction,
            &format!("task_board.automation.stage.{}", stage.state),
            run_id,
            &scope,
            &stage.recorded_at,
            serde_json::to_value(stage).map_err(|error| {
                db_error(format!(
                    "serialize task board automation run stage '{run_id}': {error}"
                ))
            })?,
        )
        .await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation run stage update '{run_id}': {error}"
            ))
        })?;
        broadcast_automation_audits(slice::from_ref(&event));
        u64::try_from(next_revision).map_err(|error| {
            db_error(format!(
                "parse task board automation run revision '{run_id}': {error}"
            ))
        })
    }
}

async fn update_stage_summary(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    lease: &TaskBoardAutomationRunLease,
    stored: &str,
    revision: i64,
    next_revision: i64,
    now: DateTime<Utc>,
) -> Result<(), CliError> {
    let run_id = &lease.run_id;
    let changed = query(
        "UPDATE task_board_orchestrator_runs
         SET stage_summary_json = ?2, revision = ?3
         WHERE run_id = ?1 AND revision = ?4
           AND lease_owner = ?5 AND lease_epoch = ?6
           AND state IN ('running', 'cancelling') AND lease_expires_at > ?7",
    )
    .bind(run_id)
    .bind(stored)
    .bind(next_revision)
    .bind(revision)
    .bind(&lease.lease_owner)
    .bind(i64::try_from(lease.lease_epoch).unwrap_or(i64::MAX))
    .bind(now.to_rfc3339())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "update task board automation run stages '{run_id}': {error}"
        ))
    })?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(db_error(format!(
            "task board automation run '{run_id}' revision changed during stage update"
        )))
    }
}

fn updated_stage_summary(
    stored: &str,
    stage: &TaskBoardAutomationRunStage,
    run_id: &str,
) -> Result<String, CliError> {
    let mut stages = decode_stages(stored, run_id)?;
    upsert_stage(&mut stages, stage);
    canonicalize_stages(&mut stages, run_id)?;
    serde_json::to_string(&StoredStageSummary { stages }).map_err(|error| {
        db_error(format!(
            "serialize task board automation run stages '{run_id}': {error}"
        ))
    })
}

pub(super) fn decode_stages(
    value: &str,
    run_id: &str,
) -> Result<Vec<TaskBoardAutomationRunStage>, CliError> {
    let mut summary = serde_json::from_str::<StoredStageSummary>(value).map_err(|error| {
        db_error(format!(
            "parse task board automation run stages '{run_id}': {error}"
        ))
    })?;
    let shape = serde_json::from_str::<Value>(value).map_err(|error| {
        db_error(format!(
            "parse task board automation run stages '{run_id}': {error}"
        ))
    })?;
    validate_stored_shape(&shape, run_id)?;
    canonicalize_stages(&mut summary.stages, run_id)?;
    Ok(summary.stages)
}

fn validate_stored_shape(value: &Value, run_id: &str) -> Result<(), CliError> {
    let object = value.as_object().ok_or_else(|| invalid_shape(run_id))?;
    if object.keys().any(|key| key != "stages") {
        return Err(invalid_shape(run_id));
    }
    let Some(stages) = object.get("stages") else {
        return Ok(());
    };
    let stages = stages.as_array().ok_or_else(|| invalid_shape(run_id))?;
    for stage in stages {
        let stage = stage.as_object().ok_or_else(|| invalid_shape(run_id))?;
        let allowed = |key: &str| {
            matches!(
                key,
                "sequence" | "stage" | "state" | "recorded_at" | "summary" | "payload"
            )
        };
        if stage.keys().any(|key| !allowed(key))
            || ["sequence", "stage", "state", "recorded_at"]
                .iter()
                .any(|key| !stage.contains_key(*key))
        {
            return Err(invalid_shape(run_id));
        }
    }
    Ok(())
}

fn invalid_shape(run_id: &str) -> CliError {
    db_error(format!(
        "parse task board automation run stages '{run_id}': non-canonical stored shape"
    ))
}

fn upsert_stage(
    stages: &mut Vec<TaskBoardAutomationRunStage>,
    stage: &TaskBoardAutomationRunStage,
) {
    if let Some(existing) = stages
        .iter_mut()
        .find(|existing| existing.sequence == stage.sequence)
    {
        existing.clone_from(stage);
    } else {
        stages.push(stage.clone());
    }
}

fn canonicalize_stages(
    stages: &mut [TaskBoardAutomationRunStage],
    run_id: &str,
) -> Result<(), CliError> {
    for stage in &*stages {
        validate_stage(stage, run_id)?;
    }
    stages.sort_by_key(|stage| stage.sequence);
    if stages
        .windows(2)
        .any(|pair| pair[0].sequence == pair[1].sequence)
    {
        return Err(db_error(format!(
            "task board automation run '{run_id}' has duplicate stage sequence"
        )));
    }
    Ok(())
}

fn validate_stage(stage: &TaskBoardAutomationRunStage, run_id: &str) -> Result<(), CliError> {
    if stage.stage.trim().is_empty() || stage.state.trim().is_empty() {
        return Err(db_error(format!(
            "task board automation run '{run_id}' has an empty stage or state"
        )));
    }
    DateTime::parse_from_rfc3339(&stage.recorded_at).map_err(|error| {
        db_error(format!(
            "parse task board automation run stage timestamp '{run_id}': {error}"
        ))
    })?;
    Ok(())
}
