use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::errors::CliErrorKind;
use crate::task_board::project::{
    ItemProjectAttribution, TaskBoardProject, TaskBoardProjectSource, item_attribution,
};
use crate::task_board::project_color::{self, TaskBoardProjectColor};
use crate::task_board::project_shape::{self, TaskBoardProjectShape};
use crate::task_board::{TaskBoardItem, TaskBoardOrchestratorSettings};
use crate::workspace::utc_now;

/// What an edit does to a project's display name. Naming the three states
/// beats a nested option, where the caller has to remember which nesting
/// level means "leave it alone" and which means "erase it".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum DisplayNameEdit<'a> {
    #[default]
    Keep,
    Set(&'a str),
    Clear,
}

/// What an edit does to a project's color. There is no clear: a project always
/// has one, so the counterpart to setting it is handing it back to the same
/// allocation registration uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum ColorEdit {
    #[default]
    Keep,
    Set(TaskBoardProjectColor),
    Reset,
}

/// One edit across every field a project owns. Passed as a struct because the
/// three fields are all optional-ish and all take similar shapes, which is
/// exactly the signature where positional arguments start getting swapped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct ProjectEdit<'a> {
    pub(crate) slug: Option<&'a str>,
    pub(crate) display_name: DisplayNameEdit<'a>,
    pub(crate) color: ColorEdit,
}

#[derive(FromRow)]
struct ProjectRow {
    project_id: String,
    source: String,
    slug: String,
    display_name: Option<String>,
    color: Option<String>,
    shape: Option<String>,
    created_at: String,
    updated_at: String,
}

impl TryFrom<ProjectRow> for TaskBoardProject {
    type Error = CliError;

    fn try_from(row: ProjectRow) -> Result<Self, Self::Error> {
        let source = TaskBoardProjectSource::parse(&row.source).ok_or_else(|| {
            db_error(format!("parse task board project source '{}'", row.source))
        })?;
        // An unreadable source is a corrupt row and fails the read; an
        // unreadable color is not. The palette is a product decision that can
        // drop an entry, and a project that stopped loading because its color
        // was retired would take the whole board with it.
        let color = row
            .color
            .as_deref()
            .and_then(TaskBoardProjectColor::parse)
            .unwrap_or_else(|| TaskBoardProjectColor::derived(&row.project_id));
        // Null means the palette still covers the board, where every project
        // wears the default and the colour alone tells them apart. A stored
        // value that cannot be read is the other case entirely: the board is
        // past the palette, so collapsing it onto that same default would drop
        // the channel keeping two same-coloured projects apart.
        let shape = match row.shape.as_deref() {
            None => TaskBoardProjectShape::DEFAULT,
            Some(stored) => TaskBoardProjectShape::parse(stored).unwrap_or_else(|| {
                TaskBoardProjectShape::derived(project_shape::organization_of(&row.slug))
            }),
        };
        Ok(Self {
            project_id: row.project_id,
            source,
            slug: row.slug,
            display_name: row.display_name,
            color,
            shape,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
    }
}

/// The colors projects already hold, so a new one can avoid them.
///
/// `exclude` drops one project from the tally, which is what a reset needs: it
/// should land where registration would put the project if the others were
/// already there, not merely somewhere other than where it is now.
async fn allocate_color_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    exclude: Option<&str>,
) -> Result<TaskBoardProjectColor, CliError> {
    let held = sqlx::query_scalar::<_, Option<String>>(
        "SELECT color FROM task_board_projects WHERE project_id IS NOT ?1",
    )
    .bind(exclude)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read task board project colors: {error}")))?;
    let taken: Vec<TaskBoardProjectColor> = held
        .iter()
        .filter_map(|color| color.as_deref().and_then(TaskBoardProjectColor::parse))
        .collect();
    Ok(project_color::allocate(&taken))
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
    // Looked up before anything else because this runs on every item write and
    // the project is almost always already registered. Allocating a color first
    // would scan the whole registry to produce a value the insert then throws
    // away.
    if let Some(registered) = read_project_id_in_tx(transaction, source, &slug).await? {
        return Ok(Some(registered));
    }

    let color = allocate_color_in_tx(transaction, None).await?;
    let now = utc_now();
    // The insert is the claim and the select is the read-back, so two writers
    // racing on the same slug converge on whichever row landed first. The loser
    // discards the color it picked, which is why a color is only advisory: two
    // projects registered in the same instant can land on the same one, and a
    // reset from Settings is what separates them again.
    query(
        "INSERT INTO task_board_projects (
             project_id, source, slug, display_name, color, created_at, updated_at
         ) VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?5)
         ON CONFLICT(source, slug) DO NOTHING",
    )
    .bind(TaskBoardProject::generate_id())
    .bind(source.as_str())
    .bind(&slug)
    .bind(color.as_str())
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("register task board project '{slug}': {error}")))?;

    // The board may have just crossed the palette, which is the moment the
    // outline starts carrying the organization for every project at once.
    super::project_shapes::assign_shapes_in_tx(transaction).await?;

    read_project_id_in_tx(transaction, source, &slug)
        .await?
        .ok_or_else(|| db_error(format!("task board project '{slug}' vanished after registering")))
        .map(Some)
}

async fn read_project_id_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    source: TaskBoardProjectSource,
    slug: &str,
) -> Result<Option<String>, CliError> {
    sqlx::query_scalar::<_, String>(
        "SELECT project_id FROM task_board_projects WHERE source = ?1 AND slug = ?2",
    )
    .bind(source.as_str())
    .bind(slug)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read task board project '{slug}': {error}")))
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
            "SELECT project_id, source, slug, display_name, color, shape, created_at, updated_at
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
            "SELECT project_id, source, slug, display_name, color, shape, created_at, updated_at
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
        edit: ProjectEdit<'_>,
    ) -> Result<TaskBoardProject, CliError> {
        // Both of these are the caller naming something wrong, not the store
        // failing. Reporting them as IO would tell an API consumer to retry.
        let existing = self.get_task_board_project(project_id).await?.ok_or_else(|| {
            CliError::from(CliErrorKind::usage_error(format!(
                "task board project '{project_id}' is not registered"
            )))
        })?;
        let slug = match edit.slug {
            Some(raw) => existing.source.normalize_slug(raw).ok_or_else(|| {
                CliError::from(CliErrorKind::usage_error(format!(
                    "'{raw}' cannot name a {} project",
                    existing.source.as_str()
                )))
            })?,
            None => existing.slug.clone(),
        };
        let display_name = match edit.display_name {
            DisplayNameEdit::Keep => existing.display_name.clone(),
            // A name that trims to nothing is a clear, not a stored blank.
            DisplayNameEdit::Set(value) => Some(value.trim())
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned),
            DisplayNameEdit::Clear => None,
        };
        // The reset reads every held colour to pick the least-used one, so it
        // has to write in the same transaction it read in. Allocating first and
        // committing separately lets a registration in between take the colour
        // this one just chose.
        let mut transaction = self
            .pool()
            .begin()
            .await
            .map_err(|error| db_error(format!("begin task board project update: {error}")))?;
        let color =
            resolve_color_edit_in_tx(&mut transaction, project_id, edit.color, existing.color)
                .await?;
        query(
            "UPDATE task_board_projects
             SET slug = ?2, display_name = ?3, color = ?4, updated_at = ?5
             WHERE project_id = ?1",
        )
        .bind(project_id)
        .bind(&slug)
        .bind(display_name.as_deref())
        .bind(color.as_str())
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| {
            // The UNIQUE(source, slug) violation is the caller asking for a
            // name another project of the same source already holds. Retrying
            // it, which is what an IO code invites, can never succeed.
            if error
                .as_database_error()
                .is_some_and(sqlx::error::DatabaseError::is_unique_violation)
            {
                return CliError::from(CliErrorKind::usage_error(format!(
                    "another {} project already uses the slug '{slug}'",
                    existing.source.as_str()
                )));
            }
            db_error(format!("update task board project '{project_id}': {error}"))
        })?;
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board project update: {error}")))?;
        self.get_task_board_project(project_id)
            .await?
            .ok_or_else(|| db_error(format!("task board project '{project_id}' vanished")))
    }
}

async fn resolve_color_edit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    project_id: &str,
    edit: ColorEdit,
    current: TaskBoardProjectColor,
) -> Result<TaskBoardProjectColor, CliError> {
    match edit {
        ColorEdit::Keep => Ok(current),
        ColorEdit::Set(color) => Ok(color),
        ColorEdit::Reset => allocate_color_in_tx(transaction, Some(project_id)).await,
    }
}

#[cfg(test)]
#[path = "projects_tests.rs"]
mod tests;
