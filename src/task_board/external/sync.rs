use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{ExternalRef, TaskBoardItem, TaskBoardStatus};
use crate::workspace::utc_now;

use super::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalSyncConflictPolicy,
    ExternalSyncField, ExternalTask, ExternalTaskRef, ExternalTaskUpdate, GitHubSyncClient,
    TodoistSyncClient,
};

mod import;
mod merge;

use import::{external_item_id, imported_external_planning};
use merge::{
    changed_fields, has_reported_conflict, local_update_fields, pull_conflict_fields,
    pull_create_fields, push_create_fields, replace_synced_ref, split_supported_fields,
    sync_state_from_task, synced_ref_from_item,
};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExternalSyncDirection {
    Pull,
    Push,
    #[default]
    Both,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExternalSyncAction {
    Pull,
    Push,
    Conflict,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalSyncOperation {
    pub provider: ExternalProvider,
    pub action: ExternalSyncAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub board_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub dry_run: bool,
    pub applied: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub changed_fields: Vec<ExternalSyncField>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unsupported_fields: Vec<ExternalSyncField>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExternalSyncOptions {
    pub status: Option<TaskBoardStatus>,
    pub provider: Option<ExternalProvider>,
    pub direction: ExternalSyncDirection,
    pub conflict_policy: ExternalSyncConflictPolicy,
    pub dry_run: bool,
}

impl Default for ExternalSyncOptions {
    fn default() -> Self {
        Self {
            status: None,
            provider: None,
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::default(),
            dry_run: true,
        }
    }
}

/// Build provider clients for configured sync integrations.
///
/// # Errors
/// Returns `CliError` when an explicitly requested provider is not configured
/// or when a provider SDK client cannot be constructed.
pub fn configured_sync_clients(
    config: &ExternalSyncConfig,
    provider: Option<ExternalProvider>,
) -> Result<Vec<Box<dyn ExternalSyncClient>>, CliError> {
    let provider_was_requested = provider.is_some();
    let providers: Vec<ExternalProvider> = match provider {
        Some(provider) => vec![provider],
        None => vec![ExternalProvider::GitHub, ExternalProvider::Todoist],
    };
    let mut clients: Vec<Box<dyn ExternalSyncClient>> = Vec::new();
    for provider in providers {
        match provider {
            ExternalProvider::GitHub if config.token_for(provider).is_some() => {
                clients.push(Box::new(GitHubSyncClient::from_config(config)?));
            }
            ExternalProvider::Todoist if config.token_for(provider).is_some() => {
                clients.push(Box::new(TodoistSyncClient::from_config(config)?));
            }
            _ if provider_was_requested => {
                config.require_token(provider)?;
            }
            _ => {}
        }
    }
    Ok(clients)
}

/// Pull and/or push task-board items through configured provider clients.
///
/// # Errors
/// Returns `CliError` when provider calls fail or local board writes fail.
pub async fn sync_external_tasks(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    clients: &[Box<dyn ExternalSyncClient>],
) -> Result<Vec<ExternalSyncOperation>, CliError> {
    let mut operations = Vec::new();
    for client in clients {
        if provider_is_allowed(client.provider(), options.provider) {
            sync_client(board, options, client.as_ref(), &mut operations).await?;
        }
    }
    Ok(operations)
}

async fn sync_client(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    if matches!(
        options.direction,
        ExternalSyncDirection::Pull | ExternalSyncDirection::Both
    ) {
        pull_provider_tasks(board, options, client, operations).await?;
    }
    if matches!(
        options.direction,
        ExternalSyncDirection::Push | ExternalSyncDirection::Both
    ) {
        push_board_tasks(board, options, client, operations).await?;
    }
    Ok(())
}

async fn pull_provider_tasks(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let tasks = client.pull_tasks().await?;
    for task in tasks {
        if options.status.is_some_and(|status| task.status != status) {
            continue;
        }
        if let Some(item) = item_for_ref(board, &task.reference)? {
            reconcile_existing_item(board, options, client.provider(), &item, task, operations)?;
            continue;
        }
        if options.dry_run {
            operations.push(operation(
                client.provider(),
                ExternalSyncAction::Pull,
                Some(external_item_id(&task.reference)),
                task.reference.clone(),
                true,
                false,
                pull_create_fields(&task),
                Vec::new(),
            ));
            continue;
        }
        let item = create_item_from_external(&task);
        let title = item.title.clone();
        let body = item.body.clone();
        let item = board.create(&title, &body, item)?;
        operations.push(operation(
            client.provider(),
            ExternalSyncAction::Pull,
            Some(item.id),
            task.reference.clone(),
            false,
            true,
            pull_create_fields(&task),
            Vec::new(),
        ));
    }
    Ok(())
}

async fn push_board_tasks(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let items = board.list(options.status)?;
    for item in &items {
        if has_reported_conflict(operations, client.provider(), &item.id) {
            continue;
        }
        if let Some(reference) = provider_ref(item, client.provider()) {
            update_linked_remote(board, options, client, item, reference, operations).await?;
        } else {
            create_remote_item(board, options, client, item, operations).await?;
        }
    }
    Ok(())
}

async fn create_remote_item(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    item: &TaskBoardItem,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    if options.dry_run {
        operations.push(operation(
            client.provider(),
            ExternalSyncAction::Push,
            Some(item.id.clone()),
            ExternalTaskRef::new(client.provider(), ""),
            true,
            false,
            push_create_fields(item),
            Vec::new(),
        ));
        return Ok(());
    }
    let reference = client.push_task(item).await?;
    let mut refs = item.external_refs.clone();
    refs.push(synced_ref_from_item(reference.clone(), item));
    board.update(
        &item.id,
        TaskBoardItemPatch {
            external_refs: Some(refs),
            ..TaskBoardItemPatch::default()
        },
    )?;
    operations.push(operation(
        client.provider(),
        ExternalSyncAction::Push,
        Some(item.id.clone()),
        reference,
        false,
        true,
        push_create_fields(item),
        Vec::new(),
    ));
    Ok(())
}

async fn update_linked_remote(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    item: &TaskBoardItem,
    reference: ExternalTaskRef,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let capabilities = client.capabilities();
    let changed = local_update_fields(item, &reference, &capabilities);
    if changed.is_empty() {
        return Ok(());
    }
    let (supported, unsupported) = split_supported_fields(&changed, &capabilities);
    let can_apply = !supported.is_empty() && !options.dry_run;
    operations.push(operation(
        client.provider(),
        ExternalSyncAction::Push,
        Some(item.id.clone()),
        reference.clone(),
        options.dry_run,
        can_apply,
        supported.clone(),
        unsupported,
    ));
    if options.dry_run || supported.is_empty() {
        return Ok(());
    }
    let updated_ref = client
        .update_task(item, &reference, ExternalTaskUpdate::new(supported))
        .await?;
    let refs = replace_synced_ref(item, &reference, updated_ref);
    board.update(
        &item.id,
        TaskBoardItemPatch {
            external_refs: Some(refs),
            ..TaskBoardItemPatch::default()
        },
    )?;
    Ok(())
}

fn create_item_from_external(task: &ExternalTask) -> TaskBoardItem {
    let now = utc_now();
    let mut item = TaskBoardItem::new(
        external_item_id(&task.reference),
        task.title.clone(),
        task.body.clone(),
        now,
    );
    item.status = task.status;
    item.project_id.clone_from(&task.project_id);
    let mut reference = task.reference.clone().into_core_ref();
    reference.sync_state = Some(sync_state_from_task(task));
    item.external_refs = vec![reference];
    if let Some(planning) = imported_external_planning(task) {
        item.planning = planning;
    }
    item
}

fn item_for_ref(
    board: &TaskBoardStore,
    reference: &ExternalTaskRef,
) -> Result<Option<TaskBoardItem>, CliError> {
    let provider = reference.provider.into();
    Ok(board.list(None)?.into_iter().find(|item| {
        item.external_refs.iter().any(|candidate| {
            candidate.provider == provider && candidate.external_id == reference.external_id
        })
    }))
}

fn reconcile_existing_item(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    provider: ExternalProvider,
    item: &TaskBoardItem,
    task: ExternalTask,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let conflict_fields = pull_conflict_fields(item, &task);
    if matches!(options.direction, ExternalSyncDirection::Both)
        && !conflict_fields.is_empty()
        && matches!(options.conflict_policy, ExternalSyncConflictPolicy::Report)
    {
        operations.push(operation(
            provider,
            ExternalSyncAction::Conflict,
            Some(item.id.clone()),
            task.reference,
            options.dry_run,
            false,
            conflict_fields,
            Vec::new(),
        ));
        return Ok(());
    }
    if matches!(
        options.conflict_policy,
        ExternalSyncConflictPolicy::PreferLocal
    ) && !conflict_fields.is_empty()
    {
        return Ok(());
    }
    let patch = reconciliation_patch(item, &task);
    if !has_reconciliation_change(&patch) {
        return Ok(());
    }
    operations.push(operation(
        provider,
        ExternalSyncAction::Pull,
        Some(item.id.clone()),
        task.reference,
        options.dry_run,
        !options.dry_run,
        changed_fields(&patch),
        Vec::new(),
    ));
    if options.dry_run {
        return Ok(());
    }
    board.update(&item.id, patch)?;
    Ok(())
}

fn reconciliation_patch(item: &TaskBoardItem, task: &ExternalTask) -> TaskBoardItemPatch {
    let mut patch = TaskBoardItemPatch::default();
    if item.title != task.title {
        patch.title = Some(task.title.clone());
    }
    if item.body != task.body {
        patch.body = Some(task.body.clone());
    }
    if item.status != task.status {
        patch.status = Some(task.status);
    }
    if item.project_id != task.project_id {
        patch.project_id = task
            .project_id
            .clone()
            .map_or(OptionalFieldPatch::Clear, OptionalFieldPatch::Set);
    }
    if let Some(refs) = reconciled_external_refs(item, &task) {
        patch.external_refs = Some(refs);
    }
    patch
}

fn has_reconciliation_change(patch: &TaskBoardItemPatch) -> bool {
    patch.title.is_some()
        || patch.body.is_some()
        || patch.status.is_some()
        || !matches!(patch.project_id, OptionalFieldPatch::Unchanged)
        || patch.external_refs.is_some()
}

fn reconciled_external_refs(item: &TaskBoardItem, task: &ExternalTask) -> Option<Vec<ExternalRef>> {
    let reference = &task.reference;
    let provider = reference.provider.into();
    let mut changed = false;
    let next_sync_state = Some(sync_state_from_task(task));
    let refs = item
        .external_refs
        .iter()
        .map(|candidate| {
            if candidate.provider == provider
                && candidate.external_id == reference.external_id
                && (candidate.url != reference.url || candidate.sync_state != next_sync_state)
            {
                changed = true;
                let mut next = reference.clone().into_core_ref();
                next.sync_state.clone_from(&next_sync_state);
                return next;
            }
            candidate.clone()
        })
        .collect();
    changed.then_some(refs)
}

fn provider_ref(item: &TaskBoardItem, provider: ExternalProvider) -> Option<ExternalTaskRef> {
    let provider = provider.into();
    item.external_refs
        .iter()
        .find(|reference| reference.provider == provider)
        .cloned()
        .map(ExternalTaskRef::from)
}

fn operation(
    provider: ExternalProvider,
    action: ExternalSyncAction,
    board_item_id: Option<String>,
    reference: ExternalTaskRef,
    dry_run: bool,
    applied: bool,
    changed_fields: Vec<ExternalSyncField>,
    unsupported_fields: Vec<ExternalSyncField>,
) -> ExternalSyncOperation {
    ExternalSyncOperation {
        provider,
        action,
        board_item_id,
        external_id: (!reference.external_id.is_empty()).then_some(reference.external_id),
        url: reference.url,
        dry_run,
        applied,
        changed_fields,
        unsupported_fields,
    }
}

fn provider_is_allowed(provider: ExternalProvider, filter: Option<ExternalProvider>) -> bool {
    filter.is_none_or(|target| target == provider)
}
