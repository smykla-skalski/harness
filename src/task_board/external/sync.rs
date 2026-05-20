use std::collections::HashMap;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{ExternalRefProvider, TaskBoardItem, TaskBoardStatus};
use crate::workspace::utc_now;
use tokio::task::spawn_blocking;

use super::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalSyncConflictPolicy,
    ExternalSyncField, ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome,
    GitHubInboxSyncClient, GitHubSyncClient, TodoistSyncClient,
};

mod delete;
mod import;
mod merge;
mod reconcile;
mod stale_reviews;

use delete::delete_remote_tombstones;
use import::{external_item_id, imported_external_planning};
use merge::{
    has_reported_conflict, local_update_fields, matching_ref, pull_create_fields,
    push_create_fields, replace_synced_ref, split_supported_fields, sync_state_from_task,
    synced_ref_from_item,
};
use reconcile::reconcile_existing_item;
use stale_reviews::reconcile_stale_github_review_requests;

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
    Delete,
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
    let providers = requested_providers(provider);
    let mut clients: Vec<Box<dyn ExternalSyncClient>> = Vec::new();
    for provider in providers {
        match provider {
            ExternalProvider::GitHub if config.token_for(provider).is_some() => {
                add_github_clients(config, &mut clients)?;
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

fn requested_providers(provider: Option<ExternalProvider>) -> Vec<ExternalProvider> {
    match provider {
        Some(provider) => vec![provider],
        None => vec![ExternalProvider::GitHub, ExternalProvider::Todoist],
    }
}

fn add_github_clients(
    config: &ExternalSyncConfig,
    clients: &mut Vec<Box<dyn ExternalSyncClient>>,
) -> Result<(), CliError> {
    let pull_enabled = config.github_repository().is_some_and(|repository| {
        !config
            .github_inbox_repositories()
            .iter()
            .any(|candidate| candidate.eq_ignore_ascii_case(repository))
    });
    clients.push(Box::new(GitHubSyncClient::from_config_with_pull(
        config,
        pull_enabled,
    )?));
    if !config.github_inbox_repositories().is_empty() {
        clients.push(Box::new(GitHubInboxSyncClient::from_config(config)?));
    }
    Ok(())
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
    if direction_allows_pull(options.direction) && client.allows_pull() {
        pull_provider_tasks(board, options, client, operations).await?;
    }
    if direction_allows_push(options.direction) && client.allows_push() {
        push_board_tasks(board, options, client, operations).await?;
        delete_remote_tombstones(board, options, client, operations).await?;
    }
    Ok(())
}

fn direction_allows_pull(direction: ExternalSyncDirection) -> bool {
    matches!(
        direction,
        ExternalSyncDirection::Pull | ExternalSyncDirection::Both
    )
}

fn direction_allows_push(direction: ExternalSyncDirection) -> bool {
    matches!(
        direction,
        ExternalSyncDirection::Push | ExternalSyncDirection::Both
    )
}

async fn pull_provider_tasks(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let tasks = client
        .pull_tasks()
        .await?
        .into_iter()
        .filter(|task| options.status.is_none_or(|status| task.status == status))
        .collect::<Vec<_>>();
    let board_items =
        run_board_blocking(board, "list pull items", |board| board.list(None)).await?;
    let item_index = build_external_ref_index(&board_items);
    for task in tasks.iter().cloned() {
        if let Some(item) = item_for_ref(
            &board_items,
            &item_index,
            &task.reference,
            task.project_id.as_deref(),
        ) {
            reconcile_existing_item(board, options, client.provider(), item, task, operations)
                .await?;
            continue;
        }
        if options.dry_run {
            operations.push(operation(OperationDraft {
                provider: client.provider(),
                action: ExternalSyncAction::Pull,
                board_item_id: Some(external_item_id(&task.reference)),
                reference: task.reference.clone(),
                dry_run: true,
                applied: false,
                changed_fields: pull_create_fields(&task),
                unsupported_fields: Vec::new(),
            }));
            continue;
        }
        let item = create_item_from_external(&task);
        let title = item.title.clone();
        let body = item.body.clone();
        let item = run_board_blocking(board, "create pulled item", move |board| {
            board.create(&title, &body, item)
        })
        .await?;
        operations.push(operation(OperationDraft {
            provider: client.provider(),
            action: ExternalSyncAction::Pull,
            board_item_id: Some(item.id),
            reference: task.reference.clone(),
            dry_run: false,
            applied: true,
            changed_fields: pull_create_fields(&task),
            unsupported_fields: Vec::new(),
        }));
    }
    reconcile_stale_github_review_requests(
        board,
        options,
        client.provider(),
        &board_items,
        &tasks,
        operations,
    )
    .await?;
    Ok(())
}

async fn push_board_tasks(
    board: &TaskBoardStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let items = run_board_blocking(board, "list push items", move |board| {
        board.list(options.status)
    })
    .await?;
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
        operations.push(operation(OperationDraft {
            provider: client.provider(),
            action: ExternalSyncAction::Push,
            board_item_id: Some(item.id.clone()),
            reference: ExternalTaskRef::new(client.provider(), ""),
            dry_run: true,
            applied: false,
            changed_fields: push_create_fields(item),
            unsupported_fields: Vec::new(),
        }));
        return Ok(());
    }
    let reference = client.push_task(item).await?;
    let mut refs = item.external_refs.clone();
    refs.push(synced_ref_from_item(reference.clone(), item));
    let item_id = item.id.clone();
    run_board_blocking(board, "record pushed item ref", move |board| {
        board.update(
            &item_id,
            TaskBoardItemPatch {
                external_refs: Some(refs),
                ..TaskBoardItemPatch::default()
            },
        )
    })
    .await?;
    operations.push(operation(OperationDraft {
        provider: client.provider(),
        action: ExternalSyncAction::Push,
        board_item_id: Some(item.id.clone()),
        reference,
        dry_run: false,
        applied: true,
        changed_fields: push_create_fields(item),
        unsupported_fields: Vec::new(),
    }));
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
    if options.dry_run || supported.is_empty() {
        let can_apply = !supported.is_empty() && !options.dry_run;
        operations.push(operation(OperationDraft {
            provider: client.provider(),
            action: ExternalSyncAction::Push,
            board_item_id: Some(item.id.clone()),
            reference: reference.clone(),
            dry_run: options.dry_run,
            applied: can_apply,
            changed_fields: supported,
            unsupported_fields: unsupported,
        }));
        return Ok(());
    }
    let precondition = remote_precondition(item, &reference);
    let update =
        ExternalTaskUpdate::new(supported.clone()).with_precondition_updated_at(precondition);
    let outcome = client.update_task(item, &reference, update).await?;
    let updated_ref = match outcome {
        ExternalUpdateOutcome::Applied(updated_ref) => updated_ref,
        ExternalUpdateOutcome::PreconditionFailed => {
            operations.push(operation(OperationDraft {
                provider: client.provider(),
                action: ExternalSyncAction::Conflict,
                board_item_id: Some(item.id.clone()),
                reference,
                dry_run: options.dry_run,
                applied: false,
                changed_fields: supported,
                unsupported_fields: Vec::new(),
            }));
            return Ok(());
        }
    };
    operations.push(operation(OperationDraft {
        provider: client.provider(),
        action: ExternalSyncAction::Push,
        board_item_id: Some(item.id.clone()),
        reference: reference.clone(),
        dry_run: false,
        applied: true,
        changed_fields: supported,
        unsupported_fields: unsupported,
    }));
    let refs = replace_synced_ref(item, &reference, &updated_ref);
    let item_id = item.id.clone();
    run_board_blocking(board, "record updated remote ref", move |board| {
        board.update(
            &item_id,
            TaskBoardItemPatch {
                external_refs: Some(refs),
                ..TaskBoardItemPatch::default()
            },
        )
    })
    .await?;
    Ok(())
}

pub(super) async fn run_board_blocking<T, F>(
    board: &TaskBoardStore,
    operation: &'static str,
    work: F,
) -> Result<T, CliError>
where
    T: Send + 'static,
    F: FnOnce(TaskBoardStore) -> Result<T, CliError> + Send + 'static,
{
    let board = board.clone();
    spawn_blocking(move || work(board))
        .await
        .unwrap_or_else(|error| {
            Err(CliErrorKind::workflow_io(format!(
                "task-board external sync {operation} worker failed: {error}"
            ))
            .into())
        })
}

fn remote_precondition(item: &TaskBoardItem, reference: &ExternalTaskRef) -> Option<String> {
    matching_ref(item, reference, item.project_id.as_deref())
        .and_then(|reference| reference.sync_state.as_ref())
        .and_then(|state| state.updated_at.clone())
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
    item.imported_from_provider = Some(task.reference.provider.into());
    if let Some(planning) = imported_external_planning(task) {
        item.planning = planning;
    }
    item
}

fn item_for_ref<'a>(
    board_items: &'a [TaskBoardItem],
    item_index: &HashMap<(ExternalRefProvider, String), usize>,
    reference: &ExternalTaskRef,
    project_id: Option<&str>,
) -> Option<&'a TaskBoardItem> {
    let key = (reference.provider.into(), reference.external_id.clone());
    if let Some(index) = item_index.get(&key)
        && let Some(item) = board_items.get(*index)
        && matching_ref(item, reference, project_id).is_some()
    {
        return Some(item);
    }
    board_items
        .iter()
        .find(|item| matching_ref(item, reference, project_id).is_some())
}

fn build_external_ref_index(
    items: &[TaskBoardItem],
) -> HashMap<(ExternalRefProvider, String), usize> {
    let mut index = HashMap::with_capacity(items.len() * 2);
    for (offset, item) in items.iter().enumerate() {
        for reference in &item.external_refs {
            let key = (reference.provider, reference.external_id.clone());
            index.entry(key).or_insert(offset);
        }
    }
    index
}

pub(super) fn provider_ref(
    item: &TaskBoardItem,
    provider: ExternalProvider,
) -> Option<ExternalTaskRef> {
    let core_provider = provider.into();
    item.external_refs
        .iter()
        .filter(|candidate| candidate.provider == core_provider)
        .find_map(|candidate| {
            let probe = ExternalTaskRef::new(provider, candidate.external_id.clone());
            matching_ref(item, &probe, item.project_id.as_deref())
                .map(|matched| ExternalTaskRef::from(matched.clone()))
        })
}

pub(super) struct OperationDraft {
    pub(super) provider: ExternalProvider,
    pub(super) action: ExternalSyncAction,
    pub(super) board_item_id: Option<String>,
    pub(super) reference: ExternalTaskRef,
    pub(super) dry_run: bool,
    pub(super) applied: bool,
    pub(super) changed_fields: Vec<ExternalSyncField>,
    pub(super) unsupported_fields: Vec<ExternalSyncField>,
}

pub(super) fn operation(draft: OperationDraft) -> ExternalSyncOperation {
    ExternalSyncOperation {
        provider: draft.provider,
        action: draft.action,
        board_item_id: draft.board_item_id,
        external_id: (!draft.reference.external_id.is_empty())
            .then_some(draft.reference.external_id),
        url: draft.reference.url,
        dry_run: draft.dry_run,
        applied: draft.applied,
        changed_fields: draft.changed_fields,
        unsupported_fields: draft.unsupported_fields,
    }
}

fn provider_is_allowed(provider: ExternalProvider, filter: Option<ExternalProvider>) -> bool {
    filter.is_none_or(|target| target == provider)
}
