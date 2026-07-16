use async_trait::async_trait;
use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::github_api::republish_current_data_change;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::{TaskBoardItem, TaskBoardStatus};
use crate::workspace::utc_now;

use super::targeting::execution_repository_for_task;
use super::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalSyncConflictPolicy,
    ExternalSyncField, ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome,
    GitHubInboxSyncClient, GitHubSyncClient, TodoistSyncClient, canonical_external_status,
};

mod delete;
mod import;
#[cfg(test)]
mod legacy_store;
mod lookup;
mod merge;
mod reconcile;
mod stale_reviews;

use delete::delete_remote_tombstones;
use import::{external_item_id, imported_external_planning};
use lookup::{
    OperationDraft, build_external_ref_index, item_for_ref, operation, provider_is_allowed,
    provider_ref,
};
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

#[async_trait]
pub(crate) trait TaskBoardSyncStore: Send + Sync {
    async fn list_items(
        &self,
        status: Option<TaskBoardStatus>,
    ) -> Result<Vec<TaskBoardItem>, CliError>;
    async fn list_items_including_deleted(&self) -> Result<Vec<TaskBoardItem>, CliError>;
    async fn create_item(&self, item: TaskBoardItem) -> Result<TaskBoardItem, CliError>;
    async fn update_item(
        &self,
        expected_item: &TaskBoardItem,
        patch: TaskBoardItemPatch,
    ) -> Result<TaskBoardItem, CliError>;
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
    configured_sync_clients_with_review_source(config, provider, true)
}

pub(crate) fn configured_sync_clients_without_review_requests(
    config: &ExternalSyncConfig,
    provider: Option<ExternalProvider>,
) -> Result<Vec<Box<dyn ExternalSyncClient>>, CliError> {
    configured_sync_clients_with_review_source(config, provider, false)
}

fn configured_sync_clients_with_review_source(
    config: &ExternalSyncConfig,
    provider: Option<ExternalProvider>,
    include_review_requests: bool,
) -> Result<Vec<Box<dyn ExternalSyncClient>>, CliError> {
    let provider_was_requested = provider.is_some();
    let providers = requested_providers(provider);
    let mut clients: Vec<Box<dyn ExternalSyncClient>> = Vec::new();
    for provider in providers {
        match provider {
            ExternalProvider::GitHub if config.token_for(provider).is_some() => {
                add_github_clients(config, &mut clients, include_review_requests)?;
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
    include_review_requests: bool,
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
        let inbox = if include_review_requests {
            GitHubInboxSyncClient::from_config(config)?
        } else {
            GitHubInboxSyncClient::from_config_assigned_only(config)?
        };
        clients.push(Box::new(inbox));
    }
    Ok(())
}

/// Pull and/or push task-board items through configured provider clients.
///
/// # Errors
/// Returns `CliError` when provider calls fail or local board writes fail.
pub(crate) async fn sync_external_tasks(
    board: &dyn TaskBoardSyncStore,
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
    board: &dyn TaskBoardSyncStore,
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

#[expect(
    clippy::cognitive_complexity,
    reason = "pull reconciliation keeps existing, dry-run, and create branches explicit"
)]
async fn pull_provider_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let tasks = client.pull_tasks().await?;
    let board_items = board.list_items(None).await?;
    let item_index = build_external_ref_index(&board_items);
    for task in tasks.iter().cloned() {
        if let Some(item) = item_for_ref(
            &board_items,
            &item_index,
            &task.reference,
            task.project_id.as_deref(),
        ) {
            if !existing_pull_matches_status_filter(options.status, item, &task) {
                continue;
            }
            reconcile_existing_item(board, options, client.provider(), item, task, operations)
                .await?;
            continue;
        }
        if !new_pull_matches_status_filter(options.status, &task) {
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
        let item = match board.create_item(item).await {
            Ok(item) => item,
            Err(error) => {
                let Some(item) = find_item_for_task(board, &task).await? else {
                    return Err(error);
                };
                reconcile_existing_item(board, options, client.provider(), &item, task, operations)
                    .await?;
                continue;
            }
        };
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
        client.authoritative_review_inbox(),
        operations,
    )
    .await?;
    Ok(())
}

fn existing_pull_matches_status_filter(
    filter: Option<TaskBoardStatus>,
    item: &TaskBoardItem,
    task: &ExternalTask,
) -> bool {
    filter.is_none_or(|filter| {
        let filter = filter.canonical_persisted_status();
        filter == TaskBoardStatus::Todo
            || item.status.canonical_persisted_status() == filter
            || task.status.canonical_persisted_status() == filter
    })
}

fn new_pull_matches_status_filter(filter: Option<TaskBoardStatus>, task: &ExternalTask) -> bool {
    filter.is_none_or(|filter| {
        task.status.canonical_persisted_status() == filter.canonical_persisted_status()
    })
}

async fn find_item_for_task(
    board: &dyn TaskBoardSyncStore,
    task: &ExternalTask,
) -> Result<Option<TaskBoardItem>, CliError> {
    let items = board.list_items(None).await?;
    let index = build_external_ref_index(&items);
    Ok(item_for_ref(&items, &index, &task.reference, task.project_id.as_deref()).cloned())
}

async fn push_board_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    operations: &mut Vec<ExternalSyncOperation>,
) -> Result<(), CliError> {
    let items = board.list_items(options.status).await?;
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
    board: &dyn TaskBoardSyncStore,
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
    let linked = board
        .update_item(
            item,
            TaskBoardItemPatch {
                external_refs: Some(refs),
                ..TaskBoardItemPatch::default()
            },
        )
        .await?;
    republish_github_board_ready(client.provider());
    operations.push(operation(OperationDraft {
        provider: client.provider(),
        action: ExternalSyncAction::Push,
        board_item_id: Some(item.id.clone()),
        reference: reference.clone(),
        dry_run: false,
        applied: true,
        changed_fields: push_create_fields(item),
        unsupported_fields: Vec::new(),
    }));
    if canonical_external_status(item.status) == TaskBoardStatus::Done {
        update_linked_remote(board, options, client, &linked, reference, operations).await?;
    }
    Ok(())
}

async fn update_linked_remote(
    board: &dyn TaskBoardSyncStore,
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
    let refs = replace_synced_ref(item, &reference, &updated_ref, &supported);
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
    board
        .update_item(
            item,
            TaskBoardItemPatch {
                external_refs: Some(refs),
                ..TaskBoardItemPatch::default()
            },
        )
        .await?;
    republish_github_board_ready(client.provider());
    Ok(())
}

fn republish_github_board_ready(provider: ExternalProvider) {
    if provider == ExternalProvider::GitHub {
        republish_current_data_change("task_board.github.local_sync_ready");
    }
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
    item.status = canonical_external_status(task.status);
    item.project_id.clone_from(&task.project_id);
    item.execution_repository = execution_repository_for_task(task);
    let mut reference = task.reference.clone().into_core_ref();
    reference.sync_state = Some(sync_state_from_task(task));
    item.external_refs = vec![reference];
    item.imported_from_provider = Some(task.reference.provider.into());
    if let Some(planning) = imported_external_planning(task) {
        item.planning = planning;
    }
    item
}
