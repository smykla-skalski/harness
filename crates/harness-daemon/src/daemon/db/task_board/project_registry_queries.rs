//! The project registry's own interface onto [`AsyncDaemonDb`], scoped to
//! registering, renaming, re-coloring, and re-attributing the projects
//! task-board items attribute to.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block for project-registry queries can
//! never move into a crate `task_board` doesn't share with `db`. A trait
//! `task_board` itself declares has no such problem: Rust's orphan rule only
//! requires one of the trait or the implementing type to be local, and the
//! trait is. That is what lets this one area's queries move into their own
//! crate later without dragging every other area's inherent impls along for
//! the ride.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use super::projects::ProjectEdit;
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::project::{TaskBoardProject, TaskBoardProjectSource};

pub(crate) trait ProjectRegistryQueries: Send + Sync {
    /// Register `raw_slug` if needed and return its project identifier.
    ///
    /// Returns `None` when the value cannot name a project for this source,
    /// which is how an item with no usable origin stays unattributed instead
    /// of being given an invented one.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be read or written.
    async fn ensure_task_board_project(
        &self,
        source: TaskBoardProjectSource,
        raw_slug: &str,
    ) -> Result<Option<String>, CliError>;

    /// Every registered project, ordered so callers render a stable list.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be read.
    async fn list_task_board_projects(&self) -> Result<Vec<TaskBoardProject>, CliError>;

    /// Read one project by identifier.
    ///
    /// # Errors
    /// Returns [`CliError`] when the registry cannot be read.
    async fn get_task_board_project(
        &self,
        project_id: &str,
    ) -> Result<Option<TaskBoardProject>, CliError>;

    /// Rename a project and/or set its display name. The identifier never
    /// changes, so every attached item survives the edit untouched.
    ///
    /// # Errors
    /// Returns [`CliError`] when the project is unknown, the slug is unusable,
    /// or the new slug already belongs to another project of the same source.
    async fn update_task_board_project(
        &self,
        project_id: &str,
        edit: ProjectEdit<'_>,
    ) -> Result<TaskBoardProject, CliError>;

    /// Run the attribution rules over every live item that holds no project,
    /// and return how many gained one.
    ///
    /// # Errors
    /// Returns [`CliError`] when the board cannot be read or written.
    async fn reattribute_unattributed_task_board_items(&self) -> Result<usize, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the free function that actually owns the
/// area's query logic, kept in the file the query has always lived in
/// (`projects.rs`, `projects_backfill.rs`) so this file stays a pure
/// interface plus wiring, not a dumping ground.
impl ProjectRegistryQueries for AsyncDaemonDb {
    async fn ensure_task_board_project(
        &self,
        source: TaskBoardProjectSource,
        raw_slug: &str,
    ) -> Result<Option<String>, CliError> {
        super::projects::ensure_task_board_project(self, source, raw_slug).await
    }

    async fn list_task_board_projects(&self) -> Result<Vec<TaskBoardProject>, CliError> {
        super::projects::list_task_board_projects(self).await
    }

    async fn get_task_board_project(
        &self,
        project_id: &str,
    ) -> Result<Option<TaskBoardProject>, CliError> {
        super::projects::get_task_board_project(self, project_id).await
    }

    async fn update_task_board_project(
        &self,
        project_id: &str,
        edit: ProjectEdit<'_>,
    ) -> Result<TaskBoardProject, CliError> {
        super::projects::update_task_board_project(self, project_id, edit).await
    }

    async fn reattribute_unattributed_task_board_items(&self) -> Result<usize, CliError> {
        super::projects_backfill::reattribute_unattributed_task_board_items(self).await
    }
}
