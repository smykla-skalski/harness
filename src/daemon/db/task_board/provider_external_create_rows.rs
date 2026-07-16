use chrono::{DateTime, Duration, Utc};
use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use super::mapper::{parse_json, to_json};
use super::provider_external_create_evidence::validate_create_evidence;
use crate::daemon::db::{CliError, CliErrorKind, db_error, utc_now};
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, ExternalSyncField,
    TaskBoardExternalCreateEvidence, TaskBoardExternalCreateIntent,
    TaskBoardExternalCreateIntentState, TaskBoardExternalCreateReceipt,
    TaskBoardExternalCreateSnapshot, TaskBoardItem, TaskBoardStatus, normalize_repository_slug,
};

const LOAD_LATEST_INTENT_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE item_id = ?1 AND provider = ?2
     ORDER BY updated_at DESC, intent_id DESC LIMIT 1";
const LOAD_INTENT_BY_ID_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents WHERE intent_id = ?1";

pub(super) async fn load_latest_intent(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
    provider: ExternalProvider,
) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
    query_as::<_, ExternalCreateIntentRow>(LOAD_LATEST_INTENT_SQL)
        .bind(item_id)
        .bind(provider_label(provider))
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task-board external create history: {error}")))?
        .map(ExternalCreateIntentRow::into_intent)
        .transpose()
}

pub(super) async fn load_intent_by_id(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
    query_as::<_, ExternalCreateIntentRow>(LOAD_INTENT_BY_ID_SQL)
        .bind(intent_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load task-board external create intent: {error}")))?
        .map(ExternalCreateIntentRow::into_intent)
        .transpose()
}

pub(super) async fn insert_intent(
    transaction: &mut Transaction<'_, Sqlite>,
    intent: &TaskBoardExternalCreateIntent,
) -> Result<(), CliError> {
    query(
        "INSERT INTO task_board_external_create_intents (
            intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
         ) VALUES (
            ?1, ?2, ?3, ?4, ?5, ?6, 'in_flight', ?7, ?8, NULL, NULL,
            ?9, NULL, NULL, NULL, ?9
         )",
    )
    .bind(&intent.intent_id)
    .bind(&intent.item_id)
    .bind(intent.item_revision)
    .bind(provider_label(intent.provider))
    .bind(&intent.scope_id)
    .bind(&intent.create_key)
    .bind(to_json(
        &intent.snapshot,
        "task-board external create snapshot",
    )?)
    .bind(to_json(
        &intent.changed_fields,
        "task-board external create changed fields",
    )?)
    .bind(&intent.created_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert task-board external create intent: {error}")))?;
    Ok(())
}

pub(super) async fn update_created_evidence(
    transaction: &mut Transaction<'_, Sqlite>,
    intent: &TaskBoardExternalCreateIntent,
    outcome: &ExternalCreateOutcome,
    provider_baseline: &ExternalRef,
    recorded_at: &str,
) -> Result<(), CliError> {
    let updated = query(
        "UPDATE task_board_external_create_intents SET
            state = 'created', outcome_json = ?4, external_ref_json = ?5,
            outcome_recorded_at = ?6, updated_at = ?6
         WHERE intent_id = ?1 AND provider = ?2 AND create_key = ?3 AND state = 'in_flight'",
    )
    .bind(&intent.intent_id)
    .bind(provider_label(intent.provider))
    .bind(&intent.create_key)
    .bind(to_json(outcome, "task-board external create outcome")?)
    .bind(to_json(
        provider_baseline,
        "task-board external create provider baseline",
    )?)
    .bind(recorded_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "record task-board external create outcome: {error}"
        ))
    })?
    .rows_affected();
    if updated == 1 {
        Ok(())
    } else {
        Err(create_conflict(
            intent,
            "intent changed before outcome recording",
        ))
    }
}

pub(super) async fn update_attached_receipt(
    transaction: &mut Transaction<'_, Sqlite>,
    intent: &TaskBoardExternalCreateIntent,
    attached_at: &str,
    attached_item_revision: i64,
) -> Result<(), CliError> {
    let updated = query(
        "UPDATE task_board_external_create_intents SET
            state = 'attached', attached_at = ?4, attached_item_revision = ?5, updated_at = ?4
         WHERE intent_id = ?1 AND provider = ?2 AND create_key = ?3 AND state = 'created'",
    )
    .bind(&intent.intent_id)
    .bind(provider_label(intent.provider))
    .bind(&intent.create_key)
    .bind(attached_at)
    .bind(attached_item_revision)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "attach task-board external create receipt: {error}"
        ))
    })?
    .rows_affected();
    if updated == 1 {
        Ok(())
    } else {
        Err(create_conflict(intent, "intent changed before attachment"))
    }
}

pub(super) fn create_snapshot(
    item: &TaskBoardItem,
    provider: ExternalProvider,
    provider_target: &str,
) -> Result<TaskBoardExternalCreateSnapshot, CliError> {
    let provider_target = normalize_provider_target(provider, provider_target)?;
    let execution_repository = match provider {
        ExternalProvider::GitHub => {
            normalize_optional_repository(item.execution_repository.as_deref(), &item.id)?
        }
        ExternalProvider::Todoist => item.execution_repository.clone(),
    };
    let target_matches = match provider {
        ExternalProvider::GitHub => execution_repository
            .as_ref()
            .is_none_or(|repository| repository == &provider_target),
        ExternalProvider::Todoist => item
            .project_id
            .as_ref()
            .is_none_or(|project| project == &provider_target),
    };
    if !target_matches {
        return Err(create_conflict_for(
            &item.id,
            provider,
            "item target does not match provider scope",
        ));
    }
    Ok(TaskBoardExternalCreateSnapshot {
        title: item.title.clone(),
        body: item.body.clone(),
        status: item.status.canonical_persisted_status(),
        project_id: item.project_id.clone(),
        execution_repository,
        provider_target,
    })
}

pub(super) fn create_changed_fields(
    snapshot: &TaskBoardExternalCreateSnapshot,
    provider: ExternalProvider,
) -> Vec<ExternalSyncField> {
    let mut fields = vec![ExternalSyncField::Title, ExternalSyncField::Body];
    if snapshot.status != TaskBoardStatus::Done {
        fields.push(ExternalSyncField::Status);
    }
    if provider != ExternalProvider::GitHub && snapshot.project_id.is_some() {
        fields.push(ExternalSyncField::Project);
    }
    fields
}

pub(super) fn require_same_intent(
    stored: &TaskBoardExternalCreateIntent,
    expected: &TaskBoardExternalCreateIntent,
) -> Result<(), CliError> {
    let matches = stored.intent_id == expected.intent_id
        && stored.item_id == expected.item_id
        && stored.item_revision == expected.item_revision
        && stored.provider == expected.provider
        && stored.scope_id == expected.scope_id
        && stored.create_key == expected.create_key
        && stored.snapshot == expected.snapshot
        && stored.changed_fields == expected.changed_fields
        && stored.created_at == expected.created_at;
    if matches {
        Ok(())
    } else {
        Err(create_conflict(expected, "intent identity differs"))
    }
}

pub(super) fn next_timestamp(previous: &str) -> Result<String, CliError> {
    let previous = DateTime::parse_from_rfc3339(previous)
        .map_err(|error| db_error(format!("parse external create timestamp: {error}")))?
        .with_timezone(&Utc);
    let now = DateTime::parse_from_rfc3339(&utc_now())
        .map_err(|error| db_error(format!("parse current external create timestamp: {error}")))?
        .with_timezone(&Utc);
    let next = if now > previous {
        now
    } else {
        previous
            .checked_add_signed(Duration::seconds(1))
            .ok_or_else(|| db_error("external create timestamp cannot advance"))?
    };
    let next = next.format("%Y-%m-%dT%H:%M:%SZ").to_string();
    if next.len() == 20 {
        Ok(next)
    } else {
        Err(db_error(
            "external create timestamp advances beyond the persisted timestamp range",
        ))
    }
}

pub(super) fn provider_label(provider: ExternalProvider) -> &'static str {
    match provider {
        ExternalProvider::GitHub => "github",
        ExternalProvider::Todoist => "todoist",
    }
}

pub(super) fn create_conflict(intent: &TaskBoardExternalCreateIntent, reason: &str) -> CliError {
    create_conflict_for(&intent.item_id, intent.provider, reason)
}

pub(super) fn create_conflict_for(
    item_id: &str,
    provider: ExternalProvider,
    reason: &str,
) -> CliError {
    CliErrorKind::concurrent_modification(format!(
        "task-board external create for item '{item_id}' provider '{provider}' cannot continue: {reason}"
    ))
    .into()
}

pub(super) fn normalize_provider_target(
    provider: ExternalProvider,
    target: &str,
) -> Result<String, CliError> {
    match provider {
        ExternalProvider::GitHub => normalize_repository_slug(Some(target))
            .ok_or_else(|| db_error(format!("invalid GitHub create target '{target}'"))),
        ExternalProvider::Todoist => {
            let target = target.trim();
            if target.is_empty() {
                Err(db_error("Todoist create target cannot be empty"))
            } else {
                Ok(target.to_owned())
            }
        }
    }
}

fn normalize_optional_repository(
    repository: Option<&str>,
    item_id: &str,
) -> Result<Option<String>, CliError> {
    let Some(repository) = repository else {
        return Ok(None);
    };
    normalize_repository_slug(Some(repository))
        .map(Some)
        .ok_or_else(|| db_error(format!("invalid execution repository on item '{item_id}'")))
}

fn parse_provider(value: &str) -> Result<ExternalProvider, CliError> {
    serde_json::from_value(serde_json::Value::String(value.to_owned())).map_err(|error| {
        db_error(format!(
            "parse task-board external create provider: {error}"
        ))
    })
}

#[derive(Debug, FromRow)]
pub(super) struct ExternalCreateIntentRow {
    intent_id: String,
    item_id: String,
    item_revision: i64,
    provider: String,
    scope_id: String,
    create_key: String,
    state: String,
    create_snapshot_json: String,
    changed_fields_json: String,
    outcome_json: Option<String>,
    external_ref_json: Option<String>,
    created_at: String,
    outcome_recorded_at: Option<String>,
    attached_at: Option<String>,
    attached_item_revision: Option<i64>,
    updated_at: String,
}

impl ExternalCreateIntentRow {
    pub(super) fn into_intent(self) -> Result<TaskBoardExternalCreateIntent, CliError> {
        let snapshot: TaskBoardExternalCreateSnapshot = parse_json(
            &self.create_snapshot_json,
            "task-board external create snapshot",
        )?;
        let changed_fields: Vec<ExternalSyncField> = parse_json(
            &self.changed_fields_json,
            "task-board external create changed fields",
        )?;
        let provider = parse_provider(&self.provider)?;
        let state = self.decode_state()?;
        let intent = TaskBoardExternalCreateIntent {
            intent_id: self.intent_id,
            item_id: self.item_id,
            item_revision: self.item_revision,
            provider,
            scope_id: self.scope_id,
            create_key: self.create_key,
            snapshot,
            changed_fields,
            state,
            created_at: self.created_at,
            updated_at: self.updated_at,
        };
        validate_decoded_intent(&intent)?;
        Ok(intent)
    }

    fn decode_state(&self) -> Result<TaskBoardExternalCreateIntentState, CliError> {
        match self.state.as_str() {
            "in_flight" => Ok(TaskBoardExternalCreateIntentState::InFlight),
            "created" => self
                .decode_evidence()
                .map(Box::new)
                .map(TaskBoardExternalCreateIntentState::Created),
            "attached" => {
                let evidence = self.decode_evidence()?;
                let attached_at = self
                    .attached_at
                    .clone()
                    .ok_or_else(|| db_error("attached external create intent has no timestamp"))?;
                let attached_item_revision = self.attached_item_revision.ok_or_else(|| {
                    db_error("attached external create intent has no item revision")
                })?;
                Ok(TaskBoardExternalCreateIntentState::Attached(Box::new(
                    TaskBoardExternalCreateReceipt {
                        evidence,
                        attached_at,
                        attached_item_revision,
                    },
                )))
            }
            state => Err(db_error(format!(
                "invalid task-board external create intent state '{state}'"
            ))),
        }
    }

    fn decode_evidence(&self) -> Result<TaskBoardExternalCreateEvidence, CliError> {
        Ok(TaskBoardExternalCreateEvidence {
            outcome: parse_json(
                self.outcome_json
                    .as_deref()
                    .ok_or_else(|| db_error("external create intent has no outcome"))?,
                "task-board external create outcome",
            )?,
            provider_baseline: parse_json(
                self.external_ref_json
                    .as_deref()
                    .ok_or_else(|| db_error("external create intent has no baseline"))?,
                "task-board external create provider baseline",
            )?,
            recorded_at: self
                .outcome_recorded_at
                .clone()
                .ok_or_else(|| db_error("external create intent has no recorded timestamp"))?,
        })
    }
}

fn validate_decoded_intent(intent: &TaskBoardExternalCreateIntent) -> Result<(), CliError> {
    if intent.snapshot.status != intent.snapshot.status.canonical_persisted_status()
        || intent.changed_fields != create_changed_fields(&intent.snapshot, intent.provider)
        || normalize_provider_target(intent.provider, &intent.snapshot.provider_target)?
            != intent.snapshot.provider_target
    {
        return Err(create_conflict(
            intent,
            "persisted create snapshot is not canonical",
        ));
    }
    if let Some(evidence) = intent.created_evidence() {
        validate_create_evidence(intent, &evidence.outcome, &evidence.provider_baseline)?;
    }
    Ok(())
}
