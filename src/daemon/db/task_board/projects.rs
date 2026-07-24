use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::project::{
    ItemProjectAttribution, TaskBoardProject, TaskBoardProjectSource, item_attribution,
};
use crate::task_board::{TaskBoardItem, TaskBoardOrchestratorSettings};
use crate::workspace::utc_now;

/// What an edit does to a project's display name. Naming the three states
/// beats a nested option, where the caller has to remember which nesting
/// level means "leave it alone" and which means "erase it".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DisplayNameEdit<'a> {
    Keep,
    Set(&'a str),
    Clear,
}

#[derive(FromRow)]
struct ProjectRow {
    project_id: String,
    source: String,
    slug: String,
    display_name: Option<String>,
    created_at: String,
    updated_at: String,
}

impl TryFrom<ProjectRow> for TaskBoardProject {
    type Error = CliError;

    fn try_from(row: ProjectRow) -> Result<Self, Self::Error> {
        let source = TaskBoardProjectSource::parse(&row.source).ok_or_else(|| {
            db_error(format!("parse task board project source '{}'", row.source))
        })?;
        Ok(Self {
            project_id: row.project_id,
            source,
            slug: row.slug,
            display_name: row.display_name,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

/// Resolve `raw_slug` to a project, registering it the first time it is seen.
///
/// Returns `None` when the value cannot name a project for this source, which
/// is how an item with no usable origin stays unattributed instead of being
/// given an invented one.
///
/// # Errors
/// Returns [`CliError`] when the registry cannot be read or written.
pub(crate) async fn ensure_project_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    source: TaskBoardProjectSource,
    raw_slug: &str,
) -> Result<Option<String>, CliError> {
    let Some(slug) = source.normalize_slug(raw_slug) else {
        return Ok(None);
    };
    let now = utc_now();
    // The insert is the claim and the select is the read-back, so two writers
    // racing on the same slug converge on whichever row landed first.
    query(
        "INSERT INTO task_board_projects (
             project_id, source, slug, display_name, created_at, updated_at
         ) VALUES (?1, ?2, ?3, NULL, ?4, ?4)
         ON CONFLICT(source, slug) DO NOTHING",
    )
    .bind(TaskBoardProject::generate_id())
    .bind(source.as_str())
    .bind(&slug)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("register task board project '{slug}': {error}")))?;

    let project_id = sqlx::query_scalar::<_, String>(
        "SELECT project_id FROM task_board_projects WHERE source = ?1 AND slug = ?2",
    )
    .bind(source.as_str())
    .bind(&slug)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read task board project '{slug}': {error}")))?;
    Ok(Some(project_id))
}

/// Point `item.source_project_id` at a registered project, registering one the
/// first time an origin is seen. An item whose origin nothing names keeps no
/// attribution rather than borrowing a value from another field.
///
/// # Errors
/// Returns [`CliError`] when the registry cannot be read or written.
pub(crate) async fn resolve_item_project_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &mut TaskBoardItem,
) -> Result<(), CliError> {
    match item_attribution(item) {
        ItemProjectAttribution::Assigned => Ok(()),
        ItemProjectAttribution::Unattributed => {
            item.source_project_id = None;
            Ok(())
        }
        ItemProjectAttribution::Register(source, slug) => {
            item.source_project_id = ensure_project_in_tx(transaction, source, &slug).await?;
            Ok(())
        }
    }
}

/// Give every repository configured in Settings a project, so a repository
/// becomes referable the moment it is added rather than when its first item
/// arrives. Registration is additive: removing a repository from Settings
/// leaves its project alone, because items already attached still name it.
///
/// # Errors
/// Returns [`CliError`] when the registry cannot be read or written.
pub(crate) async fn register_configured_repositories_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    settings: &TaskBoardOrchestratorSettings,
) -> Result<(), CliError> {
    for repository in &settings.repositories {
        ensure_project_in_tx(
            transaction,
            TaskBoardProjectSource::GitHub,
            &repository.repository,
        )
        .await?;
    }
    Ok(())
}

impl AsyncDaemonDb {
    /// Register `raw_slug` if needed and return its project identifier.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be read or written.
    pub(crate) async fn ensure_task_board_project(
        &self,
        source: TaskBoardProjectSource,
        raw_slug: &str,
    ) -> Result<Option<String>, CliError> {
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board project write: {error}")))?;
        let project_id = ensure_project_in_tx(&mut transaction, source, raw_slug).await?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board project write: {error}")))?;
        Ok(project_id)
    }

    /// Every registered project, ordered so callers render a stable list.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be read.
    pub(crate) async fn list_task_board_projects(&self) -> Result<Vec<TaskBoardProject>, CliError> {
        query_as::<_, ProjectRow>(
            "SELECT project_id, source, slug, display_name, created_at, updated_at
             FROM task_board_projects
             ORDER BY source ASC, slug ASC",
        )
        .fetch_all(self.pool())
        .await
        .map_err(|error| db_error(format!("list task board projects: {error}")))?
        .into_iter()
        .map(TaskBoardProject::try_from)
        .collect()
    }

    /// Read one project by identifier.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be read.
    pub(crate) async fn get_task_board_project(
        &self,
        project_id: &str,
    ) -> Result<Option<TaskBoardProject>, CliError> {
        query_as::<_, ProjectRow>(
            "SELECT project_id, source, slug, display_name, created_at, updated_at
             FROM task_board_projects WHERE project_id = ?1",
        )
        .bind(project_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| db_error(format!("read task board project: {error}")))?
        .map(TaskBoardProject::try_from)
        .transpose()
    }

    /// Rename a project and/or set its display name. The identifier never
    /// changes, so every attached item survives the edit untouched.
    ///
    /// # Errors
    /// Returns [`CliError`] when the project is unknown, the slug is unusable,
    /// or the new slug already belongs to another project of the same source.
    pub(crate) async fn update_task_board_project(
        &self,
        project_id: &str,
        slug: Option<&str>,
        display_name: DisplayNameEdit<'_>,
    ) -> Result<TaskBoardProject, CliError> {
        let existing = self.get_task_board_project(project_id).await?.ok_or_else(|| {
            db_error(format!("task board project '{project_id}' is not registered"))
        })?;
        let slug = match slug {
            Some(raw) => existing.source.normalize_slug(raw).ok_or_else(|| {
                db_error(format!(
                    "'{raw}' cannot name a {} project",
                    existing.source.as_str()
                ))
            })?,
            None => existing.slug.clone(),
        };
        let display_name = match display_name {
            DisplayNameEdit::Keep => existing.display_name.clone(),
            // A name that trims to nothing is a clear, not a stored blank.
            DisplayNameEdit::Set(value) => Some(value.trim())
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned),
            DisplayNameEdit::Clear => None,
        };
        query(
            "UPDATE task_board_projects
             SET slug = ?2, display_name = ?3, updated_at = ?4
             WHERE project_id = ?1",
        )
        .bind(project_id)
        .bind(&slug)
        .bind(display_name.as_deref())
        .bind(utc_now())
        .execute(self.pool())
        .await
        .map_err(|error| db_error(format!("update task board project '{project_id}': {error}")))?;
        self.get_task_board_project(project_id)
            .await?
            .ok_or_else(|| db_error(format!("task board project '{project_id}' vanished")))
    }
}

#[cfg(test)]
#[path = "projects_tests.rs"]
mod tests;
