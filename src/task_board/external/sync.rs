use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::errors::CliError;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{ExternalRef, PlanningState, TaskBoardItem, TaskBoardStatus};
use crate::workspace::utc_now;

use super::{
    ExternalProvider, ExternalSyncClient, ExternalSyncConfig, ExternalTask, ExternalTaskRef,
    GitHubSyncClient, TodoistSyncClient,
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExternalSyncOptions {
    pub status: Option<TaskBoardStatus>,
    pub provider: Option<ExternalProvider>,
    pub direction: ExternalSyncDirection,
    pub dry_run: bool,
}

impl Default for ExternalSyncOptions {
    fn default() -> Self {
        Self {
            status: None,
            provider: None,
            direction: ExternalSyncDirection::Both,
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
        if item_exists_for_ref(board, &task.reference)? {
            continue;
        }
        if options.dry_run {
            operations.push(operation(
                client.provider(),
                ExternalSyncAction::Pull,
                Some(external_item_id(&task.reference)),
                task.reference,
                true,
                false,
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
            task.reference,
            false,
            true,
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
    for item in items
        .iter()
        .filter(|item| !has_provider_ref(item, client.provider()))
    {
        if options.dry_run {
            operations.push(operation(
                client.provider(),
                ExternalSyncAction::Push,
                Some(item.id.clone()),
                ExternalTaskRef::new(client.provider(), ""),
                true,
                false,
            ));
            continue;
        }
        let reference = client.push_task(item).await?;
        let mut refs = item.external_refs.clone();
        refs.push(reference.clone().into_core_ref());
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
        ));
    }
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
    item.external_refs = vec![task.reference.clone().into_core_ref()];
    if let Some(planning) = imported_external_planning(task) {
        item.planning = planning;
    }
    item
}

fn item_exists_for_ref(
    board: &TaskBoardStore,
    reference: &ExternalTaskRef,
) -> Result<bool, CliError> {
    let provider = reference.provider.into();
    Ok(board
        .list(None)?
        .iter()
        .flat_map(|item| &item.external_refs)
        .any(|candidate| {
            candidate.provider == provider && candidate.external_id == reference.external_id
        }))
}

fn has_provider_ref(item: &TaskBoardItem, provider: ExternalProvider) -> bool {
    let provider = provider.into();
    item.external_refs
        .iter()
        .any(|reference: &ExternalRef| reference.provider == provider)
}

fn operation(
    provider: ExternalProvider,
    action: ExternalSyncAction,
    board_item_id: Option<String>,
    reference: ExternalTaskRef,
    dry_run: bool,
    applied: bool,
) -> ExternalSyncOperation {
    ExternalSyncOperation {
        provider,
        action,
        board_item_id,
        external_id: (!reference.external_id.is_empty()).then_some(reference.external_id),
        url: reference.url,
        dry_run,
        applied,
    }
}

fn external_item_id(reference: &ExternalTaskRef) -> String {
    format!(
        "{}-{}",
        reference.provider,
        safe_id_part(&reference.external_id)
    )
}

fn imported_external_planning(task: &ExternalTask) -> Option<PlanningState> {
    match task.reference.provider {
        ExternalProvider::GitHub => Some(PlanningState {
            summary: Some(github_import_summary(task)),
            approved_by: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
            approved_at: Some(timestamp_or_now(task.updated_at.as_deref())),
        }),
        ExternalProvider::Todoist => None,
    }
}

fn github_import_summary(task: &ExternalTask) -> String {
    let title = task.title.trim();
    match (title.is_empty(), task.reference.url.as_deref()) {
        (false, Some(url)) => {
            format!("Handle the linked GitHub issue \"{title}\" and preserve scope from {url}.")
        }
        (false, None) => {
            format!(
                "Handle the linked GitHub issue \"{title}\" and preserve scope from the issue body."
            )
        }
        (true, Some(url)) => {
            format!("Handle the linked GitHub issue and preserve scope from {url}.")
        }
        (true, None) => {
            "Handle the linked GitHub issue and preserve scope from the issue body.".to_string()
        }
    }
}

fn timestamp_or_now(value: Option<&str>) -> String {
    value
        .map(str::trim)
        .filter(|timestamp| !timestamp.is_empty())
        .map_or_else(utc_now, ToOwned::to_owned)
}

fn safe_id_part(value: &str) -> String {
    let mut sanitized = String::with_capacity(value.len());
    for character in value.chars() {
        if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
            sanitized.push(character);
        } else {
            sanitized.push('-');
        }
    }
    sanitized.trim_matches('-').to_string()
}

fn provider_is_allowed(provider: ExternalProvider, filter: Option<ExternalProvider>) -> bool {
    filter.is_none_or(|target| target == provider)
}
