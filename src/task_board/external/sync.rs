use std::slice;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::task_board::TaskBoardExternalCreateIntent;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::types::{TaskBoardItem, TaskBoardItemKind, TaskBoardStatus};
use crate::workspace::utc_now;

use super::targeting::{board_project_id_for_task, execution_repository_for_task};
use super::{
    ExternalProvider, ExternalRevisionUpdate, ExternalSyncClient, ExternalSyncConfig,
    ExternalSyncConflictPolicy, ExternalSyncField, ExternalTask, ExternalTaskRef,
    ExternalTaskUpdate, ExternalUpdateOutcome, GitHubInboxSyncClient, GitHubSyncClient,
    TodoistSyncClient, canonical_external_status,
};

mod batch;
mod conflicts;
mod create_recovery;
mod delete;
#[cfg(test)]
mod evidence_tests;
mod import;
#[cfg(test)]
mod lease_tests;
#[cfg(test)]
mod legacy_store;
mod lookup;
mod merge;
mod push;
mod reconcile;
mod scope;
mod stale_reviews;
mod store;

#[cfg(test)]
pub(crate) use batch::sync_external_tasks_scoped;
pub(crate) use batch::{sync_external_tasks, sync_external_tasks_scoped_with_recovery};
pub(crate) use create_recovery::{
    assign_external_create_recovery, blocked_external_create_follow_ups,
    blocked_external_create_recovery, load_external_create_recovery_work,
    prepare_external_create_recovery,
};
use import::{external_item_id, imported_external_planning};
use lookup::{
    OperationDraft, build_external_ref_index, item_for_ref, operation, provider_ref,
    resolve_parent_item_id,
};
use merge::{matching_ref, pull_create_fields, sync_state_from_task, task_signals_umbrella};
use push::push_board_tasks;
use reconcile::reconcile_existing_item;
use scope::SyncClientError;
use stale_reviews::reconcile_stale_github_review_requests;
pub(crate) use store::{
    TaskBoardExternalCreateStore, TaskBoardSyncCoordinatorFence,
    TaskBoardSyncCoordinatorFenceDecision, TaskBoardSyncItemSnapshot, TaskBoardSyncStore,
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
                add_todoist_clients(config, &mut clients)?;
            }
            _ if provider_was_requested => {
                config.require_token(provider)?;
            }
            _ => {}
        }
    }
    Ok(clients)
}

fn add_todoist_clients(
    config: &ExternalSyncConfig,
    clients: &mut Vec<Box<dyn ExternalSyncClient>>,
) -> Result<(), CliError> {
    if config.todoist_import_project_ids().is_empty() {
        clients.push(Box::new(TodoistSyncClient::from_config(config)?));
        return Ok(());
    }
    for project_id in config.todoist_import_project_ids() {
        let scoped_config = config
            .clone()
            .with_todoist_import_project_ids_override(slice::from_ref(project_id));
        clients.push(Box::new(TodoistSyncClient::from_config(&scoped_config)?));
    }
    Ok(())
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
    for repository in config.github_inbox_repositories() {
        let scoped_config = config
            .clone()
            .with_github_inbox_repositories_override(slice::from_ref(repository));
        let inbox = if include_review_requests {
            GitHubInboxSyncClient::from_config(&scoped_config)?
        } else {
            GitHubInboxSyncClient::from_config_assigned_only(&scoped_config)?
        };
        clients.push(Box::new(inbox));
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "pull reconciliation keeps existing, dry-run, and create branches explicit"
)]
async fn pull_provider_tasks(
    board: &dyn TaskBoardSyncStore,
    options: ExternalSyncOptions,
    client: &dyn ExternalSyncClient,
    tasks: Vec<ExternalTask>,
    operations: &mut Vec<ExternalSyncOperation>,
    follow_ups: &mut Vec<TaskBoardExternalCreateIntent>,
) -> Result<bool, CliError> {
    let (tasks, recovered_create) = create_recovery::suppress_known_create_markers(
        board,
        client,
        tasks,
        operations,
        follow_ups,
        options.dry_run,
    )
    .await?;
    let board_items = board.list_items(None).await?;
    let item_index = build_external_ref_index(&board_items);
    for task in tasks.iter().cloned() {
        let resolved_parent_item_id = resolve_parent_item_id(&board_items, &item_index, &task);
        if let Some(item) = item_for_ref(
            &board_items,
            &item_index,
            &task.reference,
            task.project_id.as_deref(),
        ) {
            if !existing_pull_matches_status_filter(options.status, item, &task) {
                continue;
            }
            reconcile_existing_item(
                board,
                options,
                client.provider(),
                item,
                task,
                resolved_parent_item_id.as_deref(),
                operations,
            )
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
                reconcile_existing_item(
                    board,
                    options,
                    client.provider(),
                    &item,
                    task,
                    resolved_parent_item_id.as_deref(),
                    operations,
                )
                .await?;
                continue;
            }
        };
        let item = link_resolved_parent(board, item, resolved_parent_item_id.as_deref()).await?;
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
        client,
        &board_items,
        &tasks,
        operations,
    )
    .await?;
    Ok(recovered_create)
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

fn client_owns_item(client: &dyn ExternalSyncClient, item: &TaskBoardItem, scope_id: &str) -> bool {
    client.scope_for_item(item).eq_ignore_ascii_case(scope_id)
}

async fn find_item_for_task(
    board: &dyn TaskBoardSyncStore,
    task: &ExternalTask,
) -> Result<Option<TaskBoardItem>, CliError> {
    let items = board.list_items(None).await?;
    let index = build_external_ref_index(&items);
    Ok(item_for_ref(&items, &index, &task.reference, task.project_id.as_deref()).cloned())
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
    item.project_id = board_project_id_for_task(task);
    item.execution_repository = execution_repository_for_task(task);
    item.tags.clone_from(&task.labels);
    if task_signals_umbrella(task) {
        item.kind = TaskBoardItemKind::Umbrella;
    }
    let mut reference = task.reference.clone().into_core_ref();
    reference.sync_state = Some(sync_state_from_task(task));
    item.external_refs = vec![reference];
    item.imported_from_provider = Some(task.reference.provider.into());
    if let Some(planning) = imported_external_planning(task) {
        item.planning = planning;
    }
    item
}

/// Sets the item's parent through a follow-up update rather than at create
/// time, so the same code path that computes sibling `child_order` and
/// rejects cycles for a manual re-parent also governs an imported one.
async fn link_resolved_parent(
    board: &dyn TaskBoardSyncStore,
    item: TaskBoardItem,
    parent_item_id: Option<&str>,
) -> Result<TaskBoardItem, CliError> {
    let Some(parent_item_id) = parent_item_id else {
        return Ok(item);
    };
    if parent_item_id == item.id || item.parent_item_id.as_deref() == Some(parent_item_id) {
        return Ok(item);
    }
    board
        .update_item(
            &item,
            TaskBoardItemPatch {
                parent_item_id: OptionalFieldPatch::Set(parent_item_id.to_owned()),
                ..TaskBoardItemPatch::default()
            },
        )
        .await
}
