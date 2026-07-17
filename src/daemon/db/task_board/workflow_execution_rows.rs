use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardExecutionAttemptRecord, TaskBoardExecutionOwnership,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardResolvedReviewer,
    TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWorkflowTransitionState,
    validate_task_board_execution_attempt, validate_task_board_workflow_execution,
};

#[derive(sqlx::FromRow)]
pub(super) struct WorkflowExecutionRow {
    pub execution_id: String,
    pub item_id: String,
    pub workflow_kind: String,
    pub phase: String,
    pub state: String,
    pub item_revision: i64,
    pub configuration_revision: i64,
    pub provider_revision: Option<String>,
    pub snapshot_json: String,
    pub resolved_reviewer_json: String,
    pub host_id: Option<String>,
    pub fencing_epoch: i64,
    pub available_at: Option<String>,
    pub blocked_reason: Option<String>,
    pub diagnostics_json: String,
    pub resource_ownership_json: String,
    pub created_at: String,
    pub updated_at: String,
    pub completed_at: Option<String>,
}

#[derive(sqlx::FromRow)]
pub(super) struct ExecutionAttemptRow {
    pub execution_id: String,
    pub action_key: String,
    pub attempt: i64,
    pub idempotency_key: String,
    pub state: String,
    pub failure_class: Option<String>,
    pub available_at: Option<String>,
    pub error: Option<String>,
    pub artifact_json: Option<String>,
    pub started_at: String,
    pub updated_at: String,
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredExecutionState {
    transition: TaskBoardWorkflowTransitionState,
    artifacts: TaskBoardWorkflowExecutionArtifacts,
}

impl WorkflowExecutionRow {
    pub(super) fn into_record(
        self,
        attempts: Vec<TaskBoardExecutionAttemptRecord>,
    ) -> Result<TaskBoardWorkflowExecutionRecord, CliError> {
        let workflow_kind = parse_label(&self.workflow_kind, "workflow kind")?;
        let phase = parse_phase(&self.phase)?;
        let state = parse_label(&self.state, "execution state")?;
        let snapshot: TaskBoardWorkflowSnapshot =
            parse_strict_json(&self.snapshot_json, "workflow snapshot")?;
        let resolved_reviewers: TaskBoardResolvedReviewer =
            parse_strict_json(&self.resolved_reviewer_json, "resolved reviewers")?;
        let stored: StoredExecutionState =
            parse_strict_json(&self.diagnostics_json, "workflow execution artifacts")?;
        let ownership: TaskBoardExecutionOwnership =
            parse_strict_json(&self.resource_ownership_json, "workflow ownership")?;
        validate_row_copies(
            &self,
            workflow_kind,
            phase,
            state,
            &snapshot,
            &resolved_reviewers,
            &stored,
            &ownership,
        )?;
        let record = TaskBoardWorkflowExecutionRecord {
            execution_id: self.execution_id,
            item_id: self.item_id,
            snapshot,
            resolved_reviewers,
            transition: stored.transition,
            artifacts: stored.artifacts,
            ownership,
            available_at: self.available_at,
            blocked_reason: self.blocked_reason,
            created_at: self.created_at,
            updated_at: self.updated_at,
            completed_at: self.completed_at,
            attempts,
        };
        validate_task_board_workflow_execution(&record)
            .map_err(|error| db_error(format!("validate durable workflow execution: {error}")))?;
        Ok(record)
    }
}

impl ExecutionAttemptRow {
    pub(super) fn into_record(self) -> Result<TaskBoardExecutionAttemptRecord, CliError> {
        let attempt = u32::try_from(self.attempt)
            .map_err(|_| db_error("workflow execution attempt number is out of range"))?;
        let state = parse_label(&self.state, "execution attempt state")?;
        let failure_class = self
            .failure_class
            .as_deref()
            .map(|value| parse_label(value, "execution attempt failure class"))
            .transpose()?;
        let artifact = self
            .artifact_json
            .as_deref()
            .map(|json| parse_strict_json(json, "execution attempt artifact"))
            .transpose()?;
        let record = TaskBoardExecutionAttemptRecord {
            execution_id: self.execution_id,
            action_key: self.action_key,
            attempt,
            idempotency_key: self.idempotency_key,
            state,
            failure_class,
            available_at: self.available_at,
            error: self.error,
            artifact,
            started_at: self.started_at,
            updated_at: self.updated_at,
            completed_at: self.completed_at,
        };
        validate_task_board_execution_attempt(&record)
            .map_err(|error| db_error(format!("validate durable execution attempt: {error}")))?;
        Ok(record)
    }
}

pub(super) fn execution_json(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(String, String, String, String), CliError> {
    let snapshot = strict_json(&record.snapshot, "workflow snapshot")?;
    let reviewers = strict_json(&record.resolved_reviewers, "resolved reviewers")?;
    let stored = StoredExecutionState {
        transition: record.transition.clone(),
        artifacts: record.artifacts.clone(),
    };
    let artifacts = strict_json(&stored, "workflow execution artifacts")?;
    let ownership = strict_json(&record.ownership, "workflow ownership")?;
    Ok((snapshot, reviewers, artifacts, ownership))
}

pub(super) fn attempt_artifact_json(
    artifact: Option<&TaskBoardAttemptResultArtifact>,
) -> Result<Option<String>, CliError> {
    artifact
        .map(|artifact| strict_json(artifact, "execution attempt artifact"))
        .transpose()
}

pub(super) fn label<T: Serialize>(value: T, context: &str) -> Result<String, CliError> {
    match serde_json::to_value(value) {
        Ok(Value::String(value)) => Ok(value),
        Ok(_) => Err(db_error(format!(
            "serialize {context}: expected string label"
        ))),
        Err(error) => Err(db_error(format!("serialize {context}: {error}"))),
    }
}

pub(super) fn phase_label(phase: Option<TaskBoardExecutionPhase>) -> Result<String, CliError> {
    phase.map_or_else(
        || Ok("none".to_owned()),
        |phase| label(phase, "execution phase"),
    )
}

fn parse_phase(value: &str) -> Result<Option<TaskBoardExecutionPhase>, CliError> {
    if value == "none" {
        Ok(None)
    } else {
        parse_label(value, "execution phase").map(Some)
    }
}

fn parse_label<T: DeserializeOwned>(value: &str, context: &str) -> Result<T, CliError> {
    serde_json::from_value(Value::String(value.to_owned()))
        .map_err(|error| db_error(format!("parse {context} '{value}': {error}")))
}

fn strict_json<T: Serialize>(value: &T, context: &str) -> Result<String, CliError> {
    serde_json::to_string(value).map_err(|error| db_error(format!("serialize {context}: {error}")))
}

fn parse_strict_json<T>(raw: &str, context: &str) -> Result<T, CliError>
where
    T: Serialize + DeserializeOwned,
{
    let value: Value =
        serde_json::from_str(raw).map_err(|error| db_error(format!("parse {context}: {error}")))?;
    let parsed: T = serde_json::from_value(value.clone())
        .map_err(|error| db_error(format!("decode {context}: {error}")))?;
    let canonical = serde_json::to_value(&parsed)
        .map_err(|error| db_error(format!("canonicalize {context}: {error}")))?;
    if value != canonical {
        return Err(db_error(format!(
            "parse {context}: unknown, defaulted, or non-canonical fields"
        )));
    }
    Ok(parsed)
}

#[allow(clippy::too_many_arguments)]
fn validate_row_copies(
    row: &WorkflowExecutionRow,
    workflow_kind: TaskBoardWorkflowKind,
    phase: Option<TaskBoardExecutionPhase>,
    state: TaskBoardExecutionState,
    snapshot: &TaskBoardWorkflowSnapshot,
    reviewers: &TaskBoardResolvedReviewer,
    stored: &StoredExecutionState,
    ownership: &TaskBoardExecutionOwnership,
) -> Result<(), CliError> {
    let configuration_revision = u64::try_from(row.configuration_revision)
        .map_err(|_| db_error("workflow configuration revision is out of range"))?;
    let fencing_epoch = u64::try_from(row.fencing_epoch)
        .map_err(|_| db_error("workflow fencing epoch is out of range"))?;
    let consistent = workflow_kind == snapshot.workflow_kind
        && workflow_kind == stored.transition.workflow_kind
        && phase == stored.transition.phase
        && state == stored.transition.execution_state
        && row.item_revision == snapshot.item_revision
        && configuration_revision == snapshot.configuration_revision
        && row.provider_revision == snapshot.provider_revision
        && reviewers == &snapshot.reviewer
        && row.host_id == ownership.host_id
        && fencing_epoch == ownership.fencing_epoch;
    if consistent {
        Ok(())
    } else {
        Err(db_error(
            "durable workflow execution columns contradict structured state",
        ))
    }
}
