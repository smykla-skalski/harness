use std::collections::{BTreeMap, BTreeSet};

use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, TaskBoardItemSnapshot};
use crate::task_board::project::{TaskBoardProject, TaskBoardProjectSource};
use crate::task_board::{
    TaskBoardItem, TaskBoardOrchestratorSettings, TaskBoardStatus, normalize_repository_slug,
    task_board_read_only_execution_repository,
};
use harness_kernel::errors::{CliError, CliErrorKind};

pub(crate) struct TaskBoardRepositoryScope {
    repositories: BTreeSet<String>,
    project_repositories: BTreeMap<String, String>,
}

impl TaskBoardRepositoryScope {
    pub(crate) async fn load(db: &AsyncDaemonDb) -> Result<Self, CliError> {
        let settings = db.task_board_orchestrator_settings().await?;
        Self::load_with_settings(db, &settings).await
    }

    pub(crate) async fn load_with_settings(
        db: &AsyncDaemonDb,
        settings: &TaskBoardOrchestratorSettings,
    ) -> Result<Self, CliError> {
        let repositories = settings
            .github_inbox
            .repositories
            .iter()
            .filter_map(|repository| normalize_repository_slug(Some(repository)))
            .collect();
        let project_repositories = db
            .list_task_board_projects()
            .await?
            .into_iter()
            .filter(|project| project.source == TaskBoardProjectSource::GitHub)
            .map(|project| (project.project_id, project.slug))
            .collect();
        Ok(Self {
            repositories,
            project_repositories,
        })
    }

    pub(crate) fn allows_item(&self, item: &TaskBoardItem) -> bool {
        match task_board_read_only_execution_repository(item) {
            Ok(Some(repository)) => self.repositories.contains(&repository),
            Err(_) => false,
            Ok(None) => item
                .source_project_id
                .as_ref()
                .and_then(|project_id| self.project_repositories.get(project_id))
                .is_none_or(|repository| self.repositories.contains(repository)),
        }
    }

    pub(crate) fn allows_project(&self, project: &TaskBoardProject) -> bool {
        project.source != TaskBoardProjectSource::GitHub
            || self.repositories.contains(&project.slug)
    }

    pub(crate) fn ensure_item(&self, item: &TaskBoardItem) -> Result<(), CliError> {
        if self.allows_item(item) {
            return Ok(());
        }
        Err(item_outside_scope_error(&item.id))
    }

    pub(crate) fn filter_items(&self, items: Vec<TaskBoardItem>) -> Vec<TaskBoardItem> {
        items
            .into_iter()
            .filter(|item| self.allows_item(item))
            .collect()
    }

    pub(crate) fn filter_snapshots(
        &self,
        snapshots: Vec<TaskBoardItemSnapshot>,
    ) -> Vec<TaskBoardItemSnapshot> {
        snapshots
            .into_iter()
            .filter(|snapshot| self.allows_item(&snapshot.item))
            .collect()
    }

    pub(crate) fn filter_projects(&self, projects: Vec<TaskBoardProject>) -> Vec<TaskBoardProject> {
        projects
            .into_iter()
            .filter(|project| self.allows_project(project))
            .collect()
    }
}

pub(crate) async fn scoped_task_board_items_db(
    db: &AsyncDaemonDb,
    status: Option<TaskBoardStatus>,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let scope = TaskBoardRepositoryScope::load(db).await?;
    Ok(scope.filter_items(db.list_task_board_items(status).await?))
}

pub(crate) async fn scoped_task_board_item_db(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<TaskBoardItem, CliError> {
    let item = db.task_board_item(item_id).await?;
    let scope = TaskBoardRepositoryScope::load(db).await?;
    scope.ensure_item(&item)?;
    Ok(item)
}

fn item_outside_scope_error(item_id: &str) -> CliError {
    CliErrorKind::usage_error(format!(
        "task-board item '{item_id}' is outside configured repository scope"
    ))
    .into()
}
