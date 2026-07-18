use sqlx::{Sqlite, SqliteConnection, Transaction, query_as};

use super::items::{
    bump_change_in_tx, ensure_read_only_item_mutation_allowed_in_tx, load_item_in_tx,
    replace_item_in_tx,
};
use super::provider_external_create_evidence::{
    normalized_evidence_target, validate_create_evidence,
};
use super::provider_external_create_rows::{
    create_conflict, load_intent_by_id, next_timestamp, provider_label, require_same_intent,
    update_attached_receipt,
};
use super::provider_sync_conflicts::supersede_open_sync_conflicts_in_connection;
use super::{ITEMS_CHANGE_SCOPE, ORCHESTRATOR_CHANGE_SCOPE};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    ExternalProvider, ExternalRef, ExternalSyncField, TaskBoardExternalCreateEvidence,
    TaskBoardExternalCreateFinalizeDisposition, TaskBoardExternalCreateFinalizeResult,
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState,
    TaskBoardExternalCreateReceipt, TaskBoardItem, TaskBoardStatus, normalize_repository_slug,
};
use crate::workspace::utc_now;

impl AsyncDaemonDb {
    #[expect(
        clippy::cognitive_complexity,
        reason = "finalization keeps evidence, identity, item CAS, and receipt persistence atomic"
    )]
    pub(crate) async fn finalize_task_board_external_create_intent(
        &self,
        intent: &TaskBoardExternalCreateIntent,
    ) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
        let expected = intent
            .created_evidence()
            .ok_or_else(|| create_conflict(intent, "outcome is absent"))?;
        validate_create_evidence(intent, &expected.outcome, &expected.provider_baseline)?;
        let provider_target = normalized_evidence_target(intent, &expected.outcome)?;
        let mut transaction = self
            .begin_immediate_transaction("task board external create finalize")
            .await?;
        let stored = load_intent_by_id(&mut transaction, &intent.intent_id)
            .await?
            .ok_or_else(|| create_conflict(intent, "create intent is missing"))?;
        require_same_intent(&stored, intent)?;
        let stored_evidence = stored
            .created_evidence()
            .ok_or_else(|| create_conflict(&stored, "outcome is absent"))?;
        require_same_evidence(&stored, stored_evidence, expected)?;
        if matches!(
            &stored.state,
            TaskBoardExternalCreateIntentState::Attached(_)
        ) {
            commit(transaction, "already attached task-board external create").await?;
            return Ok(finalize_result(
                stored,
                None,
                None,
                TaskBoardExternalCreateFinalizeDisposition::AlreadyAttached,
            ));
        }
        if !matches!(
            &stored.state,
            TaskBoardExternalCreateIntentState::Created(_)
        ) {
            return Err(create_conflict(&stored, "intent is not ready to finalize"));
        }
        let Some((item, item_revision)) =
            load_item_in_tx(&mut transaction, &stored.item_id).await?
        else {
            commit(transaction, "missing-item task-board external create").await?;
            return Ok(finalize_result(
                stored,
                None,
                None,
                TaskBoardExternalCreateFinalizeDisposition::RetainedMissingItem,
            ));
        };
        require_identity_not_linked_elsewhere(
            &mut transaction,
            &stored,
            &expected.provider_baseline,
        )
        .await?;
        let already_linked =
            require_compatible_provider_refs(&item, &stored, &expected.provider_baseline)?;
        let attached_at = next_timestamp(&stored.updated_at)?;
        if already_linked {
            return finalize_existing_link(
                transaction,
                stored,
                item,
                item_revision,
                &attached_at,
                provider_target.as_deref(),
                &expected.provider_baseline,
            )
            .await;
        }
        finalize_new_link(
            transaction,
            stored,
            item,
            item_revision,
            &attached_at,
            provider_target.as_deref(),
            &expected.provider_baseline,
        )
        .await
    }
}

async fn finalize_new_link(
    mut transaction: Transaction<'_, Sqlite>,
    stored: TaskBoardExternalCreateIntent,
    mut item: TaskBoardItem,
    item_revision: i64,
    attached_at: &str,
    provider_target: Option<&str>,
    provider_baseline: &ExternalRef,
) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
    ensure_read_only_item_mutation_allowed_in_tx(&mut transaction, &stored.item_id).await?;
    apply_provider_identity(&mut item, &stored, provider_target)?;
    item.external_refs.push(provider_baseline.clone());
    if item.updated_at.as_str() < attached_at {
        attached_at.clone_into(&mut item.updated_at);
    }
    let attached_item_revision = item_revision + 1;
    replace_item_in_tx(&mut transaction, &item, attached_item_revision).await?;
    update_attached_receipt(
        &mut transaction,
        &stored,
        attached_at,
        attached_item_revision,
    )
    .await?;
    let conflicts_changed = supersede_create_conflicts(
        transaction.as_mut(),
        &stored,
        &item,
        attached_item_revision,
        provider_baseline,
    )
    .await?;
    bump_change_in_tx(&mut transaction, ITEMS_CHANGE_SCOPE).await?;
    if conflicts_changed {
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    }
    commit(transaction, "task-board external create finalize").await?;
    let attached = attached_intent(stored, attached_at, attached_item_revision)?;
    Ok(finalize_result(
        attached,
        Some(item),
        Some(attached_item_revision),
        TaskBoardExternalCreateFinalizeDisposition::Attached,
    ))
}

async fn finalize_existing_link(
    mut transaction: Transaction<'_, Sqlite>,
    stored: TaskBoardExternalCreateIntent,
    mut item: TaskBoardItem,
    item_revision: i64,
    attached_at: &str,
    provider_target: Option<&str>,
    provider_baseline: &ExternalRef,
) -> Result<TaskBoardExternalCreateFinalizeResult, CliError> {
    let identity_changed = apply_provider_identity(&mut item, &stored, provider_target)?;
    let attached_item_revision = if identity_changed {
        ensure_read_only_item_mutation_allowed_in_tx(&mut transaction, &stored.item_id).await?;
        if item.updated_at.as_str() < attached_at {
            attached_at.clone_into(&mut item.updated_at);
        }
        let revision = item_revision + 1;
        replace_item_in_tx(&mut transaction, &item, revision).await?;
        revision
    } else {
        item_revision
    };
    update_attached_receipt(
        &mut transaction,
        &stored,
        attached_at,
        attached_item_revision,
    )
    .await?;
    let conflicts_changed = supersede_create_conflicts(
        transaction.as_mut(),
        &stored,
        &item,
        attached_item_revision,
        provider_baseline,
    )
    .await?;
    bump_change_in_tx(
        &mut transaction,
        if identity_changed {
            ITEMS_CHANGE_SCOPE
        } else {
            ORCHESTRATOR_CHANGE_SCOPE
        },
    )
    .await?;
    if identity_changed && conflicts_changed {
        bump_change_in_tx(&mut transaction, ORCHESTRATOR_CHANGE_SCOPE).await?;
    }
    commit(transaction, "task-board external create linked receipt").await?;
    let attached = attached_intent(stored, attached_at, attached_item_revision)?;
    Ok(finalize_result(
        attached,
        Some(item),
        Some(attached_item_revision),
        TaskBoardExternalCreateFinalizeDisposition::AlreadyLinked,
    ))
}

async fn supersede_create_conflicts(
    connection: &mut SqliteConnection,
    intent: &TaskBoardExternalCreateIntent,
    item: &TaskBoardItem,
    item_revision: i64,
    baseline: &ExternalRef,
) -> Result<bool, CliError> {
    let fields = proven_create_fields(intent, item, baseline);
    supersede_open_sync_conflicts_in_connection(
        connection,
        &intent.item_id,
        intent.provider,
        &baseline.external_id,
        item_revision,
        &fields,
        &utc_now(),
    )
    .await
}

fn proven_create_fields(
    intent: &TaskBoardExternalCreateIntent,
    item: &TaskBoardItem,
    baseline: &ExternalRef,
) -> Vec<ExternalSyncField> {
    let Some(state) = baseline.sync_state.as_ref() else {
        return Vec::new();
    };
    intent
        .changed_fields
        .iter()
        .copied()
        .filter(|field| match field {
            ExternalSyncField::Title => state.title.as_deref() == Some(&item.title),
            ExternalSyncField::Body => state.body.as_deref() == Some(&item.body),
            ExternalSyncField::Status => {
                state.status.map(canonical_provider_status)
                    == Some(canonical_provider_status(item.status))
            }
            ExternalSyncField::Project => state.project_id == item.project_id,
            ExternalSyncField::Url => false,
        })
        .collect()
}

fn canonical_provider_status(status: TaskBoardStatus) -> TaskBoardStatus {
    if status.canonical_persisted_status() == TaskBoardStatus::Done {
        TaskBoardStatus::Done
    } else {
        TaskBoardStatus::Backlog
    }
}

async fn require_identity_not_linked_elsewhere(
    transaction: &mut Transaction<'_, Sqlite>,
    intent: &TaskBoardExternalCreateIntent,
    expected: &ExternalRef,
) -> Result<(), CliError> {
    let owners = query_as::<_, (String,)>(
        "SELECT item_id FROM task_board_external_refs
         WHERE provider = ?1 AND external_id = ?2
         UNION ALL
         SELECT item_id FROM task_board_external_create_intents
         WHERE provider = ?1 AND state IN ('created', 'attached')
           AND json_extract(external_ref_json, '$.external_id') = ?2
         ORDER BY item_id",
    )
    .bind(provider_label(intent.provider))
    .bind(&expected.external_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read external create reference owners: {error}")))?;
    if owners.iter().all(|owner| owner.0 == intent.item_id) {
        Ok(())
    } else {
        Err(create_conflict(
            intent,
            "provider identity is already linked to another item",
        ))
    }
}

fn require_compatible_provider_refs(
    item: &TaskBoardItem,
    intent: &TaskBoardExternalCreateIntent,
    expected: &ExternalRef,
) -> Result<bool, CliError> {
    let refs = item
        .external_refs
        .iter()
        .filter(|reference| ExternalProvider::from(reference.provider) == intent.provider)
        .collect::<Vec<_>>();
    if refs.is_empty() {
        return Ok(false);
    }
    if refs.len() == 1 && refs[0].external_id == expected.external_id {
        return Ok(true);
    }
    Err(create_conflict(
        intent,
        "item has a different or ambiguous same-provider reference",
    ))
}

fn apply_provider_identity(
    item: &mut TaskBoardItem,
    intent: &TaskBoardExternalCreateIntent,
    provider_target: Option<&str>,
) -> Result<bool, CliError> {
    match intent.provider {
        ExternalProvider::GitHub => {
            let provider_target = provider_target.ok_or_else(|| {
                create_conflict(intent, "GitHub create evidence has no repository identity")
            })?;
            apply_github_identity(item, intent, provider_target)
        }
        ExternalProvider::Todoist => {
            let recovered_project = provider_target.map(ToOwned::to_owned);
            if item.project_id == intent.snapshot.project_id && item.project_id != recovered_project
            {
                item.project_id = recovered_project;
                return Ok(true);
            }
            Ok(false)
        }
    }
}

fn apply_github_identity(
    item: &mut TaskBoardItem,
    intent: &TaskBoardExternalCreateIntent,
    provider_target: &str,
) -> Result<bool, CliError> {
    let current = item
        .execution_repository
        .as_deref()
        .map(|repository| {
            normalize_repository_slug(Some(repository)).ok_or_else(|| {
                create_conflict(intent, "current GitHub execution target is invalid")
            })
        })
        .transpose()?;
    if current != intent.snapshot.execution_repository
        && current.as_deref() != Some(&intent.snapshot.provider_target)
        && current.as_deref() != Some(provider_target)
    {
        return Err(create_conflict(
            intent,
            "GitHub execution target changed after provider creation",
        ));
    }
    if current.as_deref() != Some(provider_target) {
        item.execution_repository = Some(provider_target.to_owned());
        return Ok(true);
    }
    Ok(false)
}

fn require_same_evidence(
    intent: &TaskBoardExternalCreateIntent,
    stored: &TaskBoardExternalCreateEvidence,
    expected: &TaskBoardExternalCreateEvidence,
) -> Result<(), CliError> {
    if stored.outcome == expected.outcome && stored.provider_baseline == expected.provider_baseline
    {
        Ok(())
    } else {
        Err(create_conflict(intent, "stored create evidence differs"))
    }
}

fn attached_intent(
    mut intent: TaskBoardExternalCreateIntent,
    attached_at: &str,
    attached_item_revision: i64,
) -> Result<TaskBoardExternalCreateIntent, CliError> {
    let evidence = intent
        .created_evidence()
        .cloned()
        .ok_or_else(|| create_conflict(&intent, "outcome is absent"))?;
    intent.state =
        TaskBoardExternalCreateIntentState::Attached(Box::new(TaskBoardExternalCreateReceipt {
            evidence,
            attached_at: attached_at.to_owned(),
            attached_item_revision,
        }));
    attached_at.clone_into(&mut intent.updated_at);
    Ok(intent)
}

fn finalize_result(
    intent: TaskBoardExternalCreateIntent,
    item: Option<TaskBoardItem>,
    item_revision: Option<i64>,
    disposition: TaskBoardExternalCreateFinalizeDisposition,
) -> TaskBoardExternalCreateFinalizeResult {
    TaskBoardExternalCreateFinalizeResult {
        intent,
        item,
        item_revision,
        disposition,
    }
}

async fn commit(transaction: Transaction<'_, Sqlite>, context: &str) -> Result<(), CliError> {
    transaction
        .commit()
        .await
        .map_err(|error| db_error(format!("commit {context}: {error}")))
}
