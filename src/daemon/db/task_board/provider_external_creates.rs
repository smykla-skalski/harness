use sqlx::{Sqlite, Transaction, query_as};
use uuid::Uuid;

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::items::{bump_change_in_tx, load_item_in_tx};
use super::provider_external_create_evidence::validate_create_evidence;
use super::provider_external_create_rows::{
    ExternalCreateIntentRow, create_changed_fields, create_conflict, create_conflict_for,
    create_snapshot, insert_intent, load_intent_by_id, load_latest_intent, next_timestamp,
    provider_label, require_same_intent, update_created_evidence,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::infra::io;
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateEvidence, TaskBoardExternalCreateExisting,
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState,
};

const LIST_PENDING_INTENTS_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE provider = ?1 AND scope_id = ?2 AND state IN ('in_flight', 'created')
     ORDER BY state, updated_at, intent_id";
const LIST_CREATED_INTENTS_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE state = 'created' ORDER BY outcome_recorded_at, intent_id";
const LIST_IN_FLIGHT_PROVIDER_INTENTS_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE provider = ?1 AND state = 'in_flight'
     ORDER BY created_at, intent_id";
const LIST_PENDING_PROVIDER_FOLLOW_UPS_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE provider = ?1 AND state = 'attached'
       AND follow_up_completed_at IS NULL
       AND follow_up_audit_event_id IS NULL
     ORDER BY scope_id, attached_at, intent_id";
const LIST_PENDING_FOLLOW_UPS_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE state = 'attached'
       AND follow_up_completed_at IS NULL
       AND follow_up_audit_event_id IS NULL
     ORDER BY provider, scope_id, attached_at, intent_id";
const LOAD_INTENT_BY_CREATE_KEY_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE provider = ?1 AND create_key = ?2";
const LOAD_ACTIVE_INTENT_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE item_id = ?1 AND provider = ?2 AND state IN ('in_flight', 'created')
     ORDER BY updated_at DESC, intent_id DESC LIMIT 1";
const LOAD_ATTACHED_RECEIPT_SQL: &str =
    "SELECT intent_id, item_id, item_revision, provider, scope_id, create_key, state,
            create_snapshot_json, changed_fields_json, outcome_json, external_ref_json,
            created_at, outcome_recorded_at, attached_at, attached_item_revision, updated_at
     FROM task_board_external_create_intents
     WHERE item_id = ?1 AND provider = ?2 AND state = 'attached'
     ORDER BY updated_at DESC, intent_id DESC LIMIT 1";

impl AsyncDaemonDb {
    #[expect(
        clippy::cognitive_complexity,
        reason = "create admission keeps durable-history, tombstone, and provider-link checks atomic"
    )]
    pub(crate) async fn begin_task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
        scope_id: &str,
        provider_target: &str,
    ) -> Result<TaskBoardExternalCreateBegin, CliError> {
        io::validate_safe_segment(item_id)?;
        let mut transaction = self
            .begin_immediate_transaction("task board external create intent begin")
            .await?;
        if let Some(intent) = load_latest_intent(&mut transaction, item_id, provider).await? {
            commit(transaction, "existing task-board external create intent").await?;
            return Ok(existing_begin(intent));
        }
        let (item, item_revision) = load_item_in_tx(&mut transaction, item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        if item.is_deleted() {
            return Err(create_conflict_for(
                item_id,
                provider,
                "cannot begin creation for a tombstoned item",
            ));
        }
        if item
            .external_refs
            .iter()
            .any(|reference| ExternalProvider::from(reference.provider) == provider)
        {
            return Err(create_conflict_for(
                item_id,
                provider,
                "item is already linked to this provider",
            ));
        }
        let now = utc_now();
        let snapshot = create_snapshot(&item, provider, provider_target)?;
        let intent = TaskBoardExternalCreateIntent {
            intent_id: Uuid::new_v4().to_string(),
            item_id: item_id.to_owned(),
            item_revision,
            provider,
            scope_id: scope_id.to_owned(),
            create_key: Uuid::new_v4().to_string(),
            changed_fields: create_changed_fields(&snapshot, provider),
            snapshot,
            state: TaskBoardExternalCreateIntentState::InFlight,
            created_at: now.clone(),
            updated_at: now,
        };
        insert_intent(&mut transaction, &intent).await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        commit(transaction, "task-board external create intent begin").await?;
        Ok(TaskBoardExternalCreateBegin::Started(intent))
    }

    pub(crate) async fn record_task_board_external_create_outcome(
        &self,
        intent: &TaskBoardExternalCreateIntent,
        outcome: &ExternalCreateOutcome,
        provider_baseline: &ExternalRef,
    ) -> Result<TaskBoardExternalCreateIntent, CliError> {
        validate_create_evidence(intent, outcome, provider_baseline)?;
        let mut transaction = self
            .begin_immediate_transaction("task board external create outcome")
            .await?;
        let stored = load_intent_by_id(&mut transaction, &intent.intent_id)
            .await?
            .ok_or_else(|| create_conflict(intent, "create intent is missing"))?;
        require_same_intent(&stored, intent)?;
        if let Some(evidence) = stored.created_evidence() {
            if evidence.outcome == *outcome && evidence.provider_baseline == *provider_baseline {
                commit(transaction, "existing task-board external create outcome").await?;
                return Ok(stored);
            }
            return Err(create_conflict(&stored, "stored create evidence differs"));
        }
        let recorded_at = next_timestamp(&stored.updated_at)?;
        update_created_evidence(
            &mut transaction,
            &stored,
            outcome,
            provider_baseline,
            &recorded_at,
        )
        .await?;
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
        commit(transaction, "task-board external create outcome").await?;
        let mut created = stored;
        created.state = TaskBoardExternalCreateIntentState::Created(Box::new(
            TaskBoardExternalCreateEvidence {
                outcome: outcome.clone(),
                provider_baseline: provider_baseline.clone(),
                recorded_at: recorded_at.clone(),
            },
        ));
        created.updated_at = recorded_at;
        Ok(created)
    }

    pub(crate) async fn list_pending_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
        scope_id: &str,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        load_intents(
            query_as::<_, ExternalCreateIntentRow>(LIST_PENDING_INTENTS_SQL)
                .bind(provider_label(provider))
                .bind(scope_id)
                .fetch_all(self.pool())
                .await,
            "list scoped task-board external create intents",
        )
    }

    pub(crate) async fn list_created_task_board_external_create_intents(
        &self,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        load_intents(
            query_as::<_, ExternalCreateIntentRow>(LIST_CREATED_INTENTS_SQL)
                .fetch_all(self.pool())
                .await,
            "list created task-board external create intents",
        )
    }

    pub(crate) async fn list_in_flight_task_board_external_create_intents(
        &self,
        provider: ExternalProvider,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        load_intents(
            query_as::<_, ExternalCreateIntentRow>(LIST_IN_FLIGHT_PROVIDER_INTENTS_SQL)
                .bind(provider_label(provider))
                .fetch_all(self.pool())
                .await,
            "list provider task-board external create intents",
        )
    }

    pub(crate) async fn list_pending_task_board_external_create_follow_ups(
        &self,
        provider: Option<ExternalProvider>,
    ) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
        let rows = match provider {
            Some(provider) => {
                query_as::<_, ExternalCreateIntentRow>(LIST_PENDING_PROVIDER_FOLLOW_UPS_SQL)
                    .bind(provider_label(provider))
                    .fetch_all(self.pool())
                    .await
            }
            None => {
                query_as::<_, ExternalCreateIntentRow>(LIST_PENDING_FOLLOW_UPS_SQL)
                    .fetch_all(self.pool())
                    .await
            }
        };
        load_intents(rows, "list pending task-board external create follow-ups")
    }

    pub(crate) async fn task_board_external_create_intent_by_create_key(
        &self,
        provider: ExternalProvider,
        create_key: &str,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        io::validate_safe_segment(create_key)?;
        decode_optional_intent(
            query_as::<_, ExternalCreateIntentRow>(LOAD_INTENT_BY_CREATE_KEY_SQL)
                .bind(provider_label(provider))
                .bind(create_key)
                .fetch_optional(self.pool())
                .await,
            "read task-board external create intent by key",
        )
    }

    pub(crate) async fn task_board_external_create_intent(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        io::validate_safe_segment(item_id)?;
        load_one(self, LOAD_ACTIVE_INTENT_SQL, item_id, provider).await
    }

    pub(crate) async fn task_board_external_create_receipt(
        &self,
        item_id: &str,
        provider: ExternalProvider,
    ) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
        io::validate_safe_segment(item_id)?;
        load_one(self, LOAD_ATTACHED_RECEIPT_SQL, item_id, provider).await
    }
}

fn existing_begin(intent: TaskBoardExternalCreateIntent) -> TaskBoardExternalCreateBegin {
    let existing = match &intent.state {
        TaskBoardExternalCreateIntentState::InFlight => {
            TaskBoardExternalCreateExisting::Recover(intent)
        }
        TaskBoardExternalCreateIntentState::Created(_) => {
            TaskBoardExternalCreateExisting::Finalize(intent)
        }
        TaskBoardExternalCreateIntentState::Attached(_) => {
            TaskBoardExternalCreateExisting::Attached(intent)
        }
    };
    TaskBoardExternalCreateBegin::Existing(existing)
}

fn load_intents(
    rows: Result<Vec<ExternalCreateIntentRow>, sqlx::Error>,
    context: &str,
) -> Result<Vec<TaskBoardExternalCreateIntent>, CliError> {
    rows.map_err(|error| db_error(format!("{context}: {error}")))?
        .into_iter()
        .map(ExternalCreateIntentRow::into_intent)
        .collect()
}

async fn load_one(
    db: &AsyncDaemonDb,
    sql: &'static str,
    item_id: &str,
    provider: ExternalProvider,
) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
    decode_optional_intent(
        query_as::<_, ExternalCreateIntentRow>(sql)
            .bind(item_id)
            .bind(provider_label(provider))
            .fetch_optional(db.pool())
            .await,
        "read task-board external create intent",
    )
}

fn decode_optional_intent(
    row: Result<Option<ExternalCreateIntentRow>, sqlx::Error>,
    context: &str,
) -> Result<Option<TaskBoardExternalCreateIntent>, CliError> {
    row.map_err(|error| db_error(format!("{context}: {error}")))?
        .map(ExternalCreateIntentRow::into_intent)
        .transpose()
}

async fn commit(transaction: Transaction<'_, Sqlite>, context: &str) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {context}: {error}")))
}
