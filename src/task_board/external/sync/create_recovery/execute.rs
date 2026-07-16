use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalCreateLease, ExternalCreateProbe, ExternalCreateRecoveryClient, ExternalCreateRequest,
    ExternalProviderScopeAttempt, ExternalProviderScopeIdentity, ExternalSyncClient,
};
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalSyncAction, ExternalSyncOperation,
    ExternalTask, TaskBoardExternalCreateBegin, TaskBoardExternalCreateExisting,
    TaskBoardExternalCreateFinalizeDisposition, TaskBoardExternalCreateIntent,
    TaskBoardExternalCreateIntentState, TaskBoardItem,
};

use super::super::lookup::{OperationDraft, operation};
use super::super::merge::sync_state_from_task;
use super::super::{SyncClientError, TaskBoardSyncStore};
use super::lease::ScopeCreateLease;
use super::reload_intent;

pub(crate) struct DurableCreateResult {
    pub(crate) linked_item: Option<TaskBoardItem>,
    pub(crate) durable_create: bool,
}

pub(crate) async fn recover_scope_intents(
    board: &dyn TaskBoardSyncStore,
    client: &dyn ExternalSyncClient,
    attempt: &ExternalProviderScopeAttempt,
    intents: &[TaskBoardExternalCreateIntent],
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<(), SyncClientError> {
    let lease = ScopeCreateLease::new(board, attempt);
    for listed in intents {
        recover_scope_intent(board, client, &lease, listed, operations, follow_ups).await?;
    }
    Ok(())
}

async fn recover_scope_intent(
    board: &dyn TaskBoardSyncStore,
    client: &dyn ExternalSyncClient,
    lease: &ScopeCreateLease<'_>,
    listed: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<(), SyncClientError> {
    lease.renew().await.map_err(SyncClientError::Local)?;
    let current = reload_intent(board, listed)
        .await
        .map_err(SyncClientError::Local)?;
    match current.state {
        TaskBoardExternalCreateIntentState::InFlight => {
            recover_remote_intent(board, client, lease, &current, operations, follow_ups).await
        }
        TaskBoardExternalCreateIntentState::Created(_) => {
            finalize_intent(board, &current, operations, follow_ups)
                .await
                .map(|_| ())
                .map_err(SyncClientError::Local)
        }
        TaskBoardExternalCreateIntentState::Attached(_) => {
            queue_attached_follow_up(&current, follow_ups).map_err(SyncClientError::Local)
        }
    }
}

pub(crate) async fn create_item_durably(
    board: &dyn TaskBoardSyncStore,
    client: &dyn ExternalSyncClient,
    attempt: &ExternalProviderScopeAttempt,
    item: &TaskBoardItem,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<DurableCreateResult, SyncClientError> {
    let capability = require_recovery_capability(client, item).map_err(SyncClientError::Local)?;
    let provider_target = create_target(client, item);
    let scope = ExternalProviderScopeIdentity::for_client(client);
    let decision = board
        .begin_external_create_intent(
            &item.id,
            client.provider(),
            scope.scope_id(),
            &provider_target,
        )
        .await
        .map_err(SyncClientError::Local)?;
    let lease = ScopeCreateLease::new(board, attempt);
    let (linked_item, durable_create) = match decision {
        TaskBoardExternalCreateBegin::Started(intent) => (
            create_started(board, capability, &lease, &intent, operations, follow_ups).await?,
            true,
        ),
        TaskBoardExternalCreateBegin::Existing(TaskBoardExternalCreateExisting::Recover(
            intent,
        )) => (
            recover_existing(board, capability, &lease, &intent, operations, follow_ups).await?,
            true,
        ),
        TaskBoardExternalCreateBegin::Existing(TaskBoardExternalCreateExisting::Finalize(
            intent,
        )) => (
            finalize_intent(board, &intent, operations, follow_ups)
                .await
                .map_err(SyncClientError::Local)?,
            true,
        ),
        TaskBoardExternalCreateBegin::Existing(TaskBoardExternalCreateExisting::Attached(
            intent,
        )) => {
            queue_attached_follow_up(&intent, follow_ups).map_err(SyncClientError::Local)?;
            (None, false)
        }
    };
    Ok(DurableCreateResult {
        linked_item,
        durable_create,
    })
}

pub(crate) async fn suppress_known_create_markers(
    board: &dyn TaskBoardSyncStore,
    client: &dyn ExternalSyncClient,
    tasks: Vec<ExternalTask>,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
    dry_run: bool,
) -> Result<(Vec<ExternalTask>, bool), CliError> {
    let Some(capability) = client.external_create_recovery() else {
        return Ok((tasks, false));
    };
    let scope = ExternalProviderScopeIdentity::for_client(client);
    let mut clean = Vec::with_capacity(tasks.len());
    let mut recovered = false;
    for task in tasks {
        let result = handle_create_marker(
            board, client, capability, &scope, task, operations, follow_ups, dry_run,
        )
        .await?;
        recovered |= result.recovered;
        if let Some(task) = result.task {
            clean.push(task);
        }
    }
    Ok((clean, recovered))
}

struct MarkerTaskResult {
    task: Option<ExternalTask>,
    recovered: bool,
}

#[expect(
    clippy::too_many_arguments,
    reason = "marker recovery needs the exact capability, scope, task, and durable effect sinks"
)]
async fn handle_create_marker(
    board: &dyn TaskBoardSyncStore,
    client: &dyn ExternalSyncClient,
    capability: &dyn ExternalCreateRecoveryClient,
    scope: &ExternalProviderScopeIdentity,
    mut task: ExternalTask,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
    dry_run: bool,
) -> Result<MarkerTaskResult, CliError> {
    let Some(create_key) = capability.extract_create_key(&mut task)? else {
        return Ok(MarkerTaskResult {
            task: Some(task),
            recovered: false,
        });
    };
    let Some(intent) = board
        .external_create_intent_by_create_key(client.provider(), &create_key)
        .await?
    else {
        return Ok(MarkerTaskResult {
            task: Some(task),
            recovered: false,
        });
    };
    require_marker_owner(client, capability, scope, &intent)?;
    if matches!(
        intent.state,
        TaskBoardExternalCreateIntentState::Attached(_)
    ) {
        let linked = attached_marker_is_linked(board, &intent, &task).await?;
        if !dry_run {
            queue_attached_follow_up(&intent, follow_ups)?;
        }
        return Ok(MarkerTaskResult {
            task: linked.then_some(task),
            recovered: false,
        });
    }
    if !dry_run {
        persist_exact_task(board, &intent, task, operations, follow_ups).await?;
    }
    Ok(MarkerTaskResult {
        task: None,
        recovered: true,
    })
}

async fn attached_marker_is_linked(
    board: &dyn TaskBoardSyncStore,
    intent: &TaskBoardExternalCreateIntent,
    task: &ExternalTask,
) -> Result<bool, CliError> {
    let TaskBoardExternalCreateIntentState::Attached(receipt) = &intent.state else {
        return Err(CliErrorKind::concurrent_modification(
            "provider create marker receipt is not attached",
        )
        .into());
    };
    let recorded = &receipt.evidence.outcome.reference;
    let baseline = &receipt.evidence.provider_baseline;
    if task.reference.provider != intent.provider
        || task.reference.provider != recorded.provider
        || task.reference.external_id != recorded.external_id
        || ExternalProvider::from(baseline.provider) != recorded.provider
        || baseline.external_id != recorded.external_id
    {
        return Err(CliErrorKind::concurrent_modification(format!(
            "attached provider create marker '{}' does not match its receipt identity",
            intent.create_key
        ))
        .into());
    }
    let snapshot = board.item_snapshot(&intent.item_id).await?;
    Ok(!snapshot.item.is_deleted()
        && snapshot.item.external_refs.iter().any(|reference| {
            ExternalProvider::from(reference.provider) == intent.provider
                && reference.external_id == recorded.external_id
        }))
}

async fn create_started(
    board: &dyn TaskBoardSyncStore,
    capability: &dyn ExternalCreateRecoveryClient,
    lease: &ScopeCreateLease<'_>,
    intent: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<Option<TaskBoardItem>, SyncClientError> {
    lease.renew().await.map_err(SyncClientError::Local)?;
    let current = reload_intent(board, intent)
        .await
        .map_err(SyncClientError::Local)?;
    if !matches!(current.state, TaskBoardExternalCreateIntentState::InFlight) {
        return finish_reloaded_intent(board, &current, operations, follow_ups)
            .await
            .map_err(SyncClientError::Local);
    }
    lease.begin_provider_call();
    let task = capability
        .create_started(&request_from_intent(&current), lease)
        .await
        .map_err(|error| lease.classify_provider_call(error).into_sync_client_error())?;
    persist_exact_task(board, &current, task, operations, follow_ups)
        .await
        .map_err(SyncClientError::Local)
}

async fn recover_existing(
    board: &dyn TaskBoardSyncStore,
    capability: &dyn ExternalCreateRecoveryClient,
    lease: &ScopeCreateLease<'_>,
    intent: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<Option<TaskBoardItem>, SyncClientError> {
    lease.renew().await.map_err(SyncClientError::Local)?;
    let current = reload_intent(board, intent)
        .await
        .map_err(SyncClientError::Local)?;
    if !matches!(current.state, TaskBoardExternalCreateIntentState::InFlight) {
        return finish_reloaded_intent(board, &current, operations, follow_ups)
            .await
            .map_err(SyncClientError::Local);
    }
    lease.begin_provider_call();
    let probe = capability
        .recover_existing(&request_from_intent(&current), lease)
        .await
        .map_err(|error| lease.classify_provider_call(error).into_sync_client_error())?;
    let ExternalCreateProbe::Found(task) = probe else {
        return Err(SyncClientError::Provider(
            CliErrorKind::workflow_io(format!(
                "provider create recovery found no task for '{}'",
                current.item_id
            ))
            .into(),
        ));
    };
    persist_exact_task(board, &current, task, operations, follow_ups)
        .await
        .map_err(SyncClientError::Local)
}

async fn recover_remote_intent(
    board: &dyn TaskBoardSyncStore,
    client: &dyn ExternalSyncClient,
    lease: &ScopeCreateLease<'_>,
    intent: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<(), SyncClientError> {
    let capability = require_intent_capability(client, intent).map_err(SyncClientError::Local)?;
    recover_existing(board, capability, lease, intent, operations, follow_ups)
        .await
        .map(|_| ())
}

async fn finish_reloaded_intent(
    board: &dyn TaskBoardSyncStore,
    intent: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<Option<TaskBoardItem>, CliError> {
    match intent.state {
        TaskBoardExternalCreateIntentState::InFlight => Err(CliErrorKind::concurrent_modification(
            "provider create intent remained in-flight after reload",
        )
        .into()),
        TaskBoardExternalCreateIntentState::Created(_) => {
            finalize_intent(board, intent, operations, follow_ups).await
        }
        TaskBoardExternalCreateIntentState::Attached(_) => {
            queue_attached_follow_up(intent, follow_ups)?;
            Ok(None)
        }
    }
}

async fn persist_exact_task(
    board: &dyn TaskBoardSyncStore,
    intent: &TaskBoardExternalCreateIntent,
    task: ExternalTask,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<Option<TaskBoardItem>, CliError> {
    let outcome = ExternalCreateOutcome {
        reference: task.reference.clone(),
        provider_revision: task.updated_at.clone(),
        provider_project_id: task.project_id.clone(),
    };
    let sync_state = sync_state_from_task(&task);
    let mut baseline = task.reference.into_core_ref();
    baseline.sync_state = Some(sync_state);
    let recorded = board
        .record_external_create_outcome(intent, &outcome, &baseline)
        .await?;
    finish_reloaded_intent(board, &recorded, operations, follow_ups).await
}

pub(super) async fn finalize_intent(
    board: &dyn TaskBoardSyncStore,
    intent: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<Option<TaskBoardItem>, CliError> {
    let finalized = board.finalize_external_create_intent(intent).await?;
    match finalized.disposition {
        TaskBoardExternalCreateFinalizeDisposition::RetainedMissingItem => {
            Err(CliErrorKind::workflow_io(format!(
                "provider create for missing item '{}' remains unresolved",
                intent.item_id
            ))
            .into())
        }
        TaskBoardExternalCreateFinalizeDisposition::AlreadyAttached => {
            queue_attached_follow_up(&finalized.intent, follow_ups)?;
            Ok(finalized.item)
        }
        TaskBoardExternalCreateFinalizeDisposition::Attached
        | TaskBoardExternalCreateFinalizeDisposition::AlreadyLinked => {
            report_newly_attached_intent(&finalized.intent, operations, follow_ups);
            Ok(finalized.item)
        }
    }
}

fn report_newly_attached_intent(
    intent: &TaskBoardExternalCreateIntent,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) {
    let evidence = intent
        .created_evidence()
        .expect("attached create intent always retains evidence");
    let already_reported = operations.iter().any(|operation| {
        operation.provider == intent.provider
            && operation.action == ExternalSyncAction::Push
            && operation.board_item_id.as_deref() == Some(&intent.item_id)
            && operation.external_id.as_deref() == Some(&evidence.outcome.reference.external_id)
            && operation.applied
    });
    if !already_reported {
        operations.push(create_operation(intent));
    }
    queue_attached_follow_up(intent, follow_ups).expect("finalized intent is attached");
}

pub(super) fn queue_attached_follow_up(
    intent: &TaskBoardExternalCreateIntent,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<(), CliError> {
    if !matches!(
        intent.state,
        TaskBoardExternalCreateIntentState::Attached(_)
    ) {
        return Err(CliErrorKind::concurrent_modification(
            "provider create follow-up is not attached",
        )
        .into());
    }
    if !follow_ups
        .iter()
        .any(|candidate| candidate.intent_id == intent.intent_id)
    {
        follow_ups.push(intent.clone());
    }
    Ok(())
}

fn create_operation(intent: &TaskBoardExternalCreateIntent) -> ExternalSyncOperation {
    let evidence = intent
        .created_evidence()
        .expect("attached create intent always retains evidence");
    operation(OperationDraft {
        provider: intent.provider,
        action: ExternalSyncAction::Push,
        board_item_id: Some(intent.item_id.clone()),
        reference: evidence.outcome.reference.clone(),
        dry_run: false,
        applied: true,
        changed_fields: intent.changed_fields.clone(),
        unsupported_fields: Vec::new(),
    })
}

fn request_from_intent(intent: &TaskBoardExternalCreateIntent) -> ExternalCreateRequest {
    ExternalCreateRequest::new(
        &intent.item_id,
        &intent.create_key,
        &intent.snapshot.title,
        &intent.snapshot.body,
        &intent.snapshot.provider_target,
    )
}

fn require_recovery_capability<'a>(
    client: &'a dyn ExternalSyncClient,
    item: &TaskBoardItem,
) -> Result<&'a dyn ExternalCreateRecoveryClient, CliError> {
    let target = create_target(client, item);
    let capability = client.external_create_recovery().ok_or_else(|| {
        CliErrorKind::workflow_io("provider does not support durable create recovery")
    })?;
    if capability.provider() != client.provider() || !capability.supports_target(&target) {
        return Err(CliErrorKind::workflow_io(
            "provider create recovery does not support the immutable target",
        )
        .into());
    }
    Ok(capability)
}

fn create_target(client: &dyn ExternalSyncClient, item: &TaskBoardItem) -> String {
    if client.provider() == ExternalProvider::Todoist
        && let Some(project_id) = &item.project_id
    {
        return project_id.clone();
    }
    client.scope_for_item(item)
}

fn require_intent_capability<'a>(
    client: &'a dyn ExternalSyncClient,
    intent: &TaskBoardExternalCreateIntent,
) -> Result<&'a dyn ExternalCreateRecoveryClient, CliError> {
    let capability = client.external_create_recovery().ok_or_else(|| {
        CliErrorKind::workflow_io("provider does not support durable create recovery")
    })?;
    if capability.provider() != intent.provider
        || !capability.supports_target(&intent.snapshot.provider_target)
    {
        return Err(CliErrorKind::workflow_io(
            "provider create recovery does not support the persisted target",
        )
        .into());
    }
    Ok(capability)
}

fn require_marker_owner(
    client: &dyn ExternalSyncClient,
    capability: &dyn ExternalCreateRecoveryClient,
    scope: &ExternalProviderScopeIdentity,
    intent: &TaskBoardExternalCreateIntent,
) -> Result<(), CliError> {
    if client.allows_push()
        && intent.scope_id == scope.scope_id()
        && capability.provider() == intent.provider
        && capability.supports_target(&intent.snapshot.provider_target)
    {
        return Ok(());
    }
    Err(CliErrorKind::concurrent_modification(
        "provider create marker does not match the configured write owner",
    )
    .into())
}
